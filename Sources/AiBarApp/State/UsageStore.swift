import AppKit
import Combine
import ServiceManagement
import AiBarCore

public enum PopoverTab: Equatable, Hashable {
    case all
    case provider(ProviderID)
}

@MainActor
public final class UsageStore: ObservableObject {
    public static let shared = UsageStore()

    @Published public var config: AppConfig
    @Published public var snapshots: [ProviderID: ProviderSnapshot]
    @Published public var selectedTab: PopoverTab = .all
    @Published public var refreshingProviders: Set<ProviderID> = []
    @Published public var lastGlobalRefreshAt: Date?
    @Published public var launchAtLoginEnabled: Bool = false
    @Published public var maxPopoverHeight: CGFloat = 820

    private var timer: Timer?
    private var grokCLIRetryAfter: Date?
    private static let grokCLIBackoff: TimeInterval = 60 * 60

    private init() {
        let loadedConfig = AppConfig.load()
        self.config = loadedConfig

        var initial: [ProviderID: ProviderSnapshot] = [:]
        if let cachedData = try? Data(contentsOf: AppConfig.snapshotCacheURL),
           let decoded = try? JSONDecoder().decode([ProviderID: ProviderSnapshot].self, from: cachedData) {
            initial = decoded
        }
        for p in ProviderID.allCases where initial[p] == nil {
            initial[p] = ProviderSnapshot(provider: p, state: .signedOut)
        }
        self.snapshots = initial
        self.selectedTab = .all
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)

        rescheduleTimer()
    }

    public func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        snapshots[provider] ?? ProviderSnapshot(provider: provider, state: .signedOut)
    }

    // MARK: - Preferences updates

    public func toggleProvider(_ provider: ProviderID, enabled: Bool) {
        config.setEnabled(provider, enabled: enabled)
        config.save()
        if enabled {
            Task { await refresh(provider: provider) }
        }
    }

    public func setRefreshInterval(minutes: Int) {
        config.refreshIntervalMinutes = minutes
        config.save()
        rescheduleTimer()
    }

    public func setPercentageMode(_ mode: PercentageDisplayMode) {
        config.percentageMode = mode
        config.save()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Ad-hoc unsigned dev builds outside /Applications may decline SMAppService registration
        }
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - Sign-In & Sign-Out Flows

    public func openWebSignIn(for provider: ProviderID) {
        WebLoginWindowController.present(for: provider) { [weak self] authenticatedSnapshot in
            guard let self else { return }
            self.config.webSignedInProviders.insert(provider)
            self.config.save()
            self.snapshots[provider] = authenticatedSnapshot
            self.lastGlobalRefreshAt = Date()
            self.persistSnapshots()
        }
    }

    public func openGrokTerminalLogin() {
        guard let grokBin = LocalCredentialReader.findGrokExecutable() else {
            openWebSignIn(for: .grok)
            return
        }
        let script = """
        tell application "Terminal"
            activate
            do script "'\(grokBin)' login"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }

    public func saveManualSecret(_ secret: String, for provider: ProviderID) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.deleteSecret(account: KeychainStore.manualAccountKey(for: provider))
        } else {
            _ = KeychainStore.saveSecret(trimmed, account: KeychainStore.manualAccountKey(for: provider))
        }
        Task { await refresh(provider: provider) }
    }

    public func hasManualSecret(for provider: ProviderID) -> Bool {
        KeychainStore.readSecret(account: KeychainStore.manualAccountKey(for: provider)) != nil
    }

    public func signOut(provider: ProviderID) async {
        KeychainStore.deleteSecret(account: KeychainStore.manualAccountKey(for: provider))
        KeychainStore.deleteSecret(account: KeychainStore.cachedOAuthKey(for: provider))
        config.webSignedInProviders.remove(provider)
        config.save()
        await WebSessionManager.shared.clearWebSession(for: provider)
        snapshots[provider] = ProviderSnapshot(provider: provider, state: .signedOut)
        persistSnapshots()
    }

    // MARK: - Refresh Orchestration (Hybrid Auth)

    public func refreshAll() async {
        let targets = config.enabledProviders
        let tasks = targets.map { p in
            Task { @MainActor in
                await self.refresh(provider: p)
            }
        }
        for task in tasks {
            await task.value
        }
        lastGlobalRefreshAt = Date()
    }

    public func refresh(provider: ProviderID) async {
        guard !refreshingProviders.contains(provider) else { return }
        refreshingProviders.insert(provider)
        if snapshots[provider]?.state == .signedOut {
            var loadingSnap = snapshot(for: provider)
            loadingSnap.state = .loading
            snapshots[provider] = loadingSnap
        }
        defer {
            refreshingProviders.remove(provider)
        }

        do {
            if let fetched = try await fetchHybrid(for: provider) {
                snapshots[provider] = fetched
                lastGlobalRefreshAt = Date()
                persistSnapshots()
            } else {
                snapshots[provider] = ProviderSnapshot(provider: provider, state: .signedOut)
                persistSnapshots()
            }
        } catch {
            var previous = snapshot(for: provider)
            if previous.shortWindow != nil || previous.longWindow != nil {
                // Keep last known numbers visible as stale and attach diagnostic message
                previous.state = .error
                previous.errorMessage = error.localizedDescription
                snapshots[provider] = previous
            } else {
                snapshots[provider] = ProviderSnapshot(
                    provider: provider,
                    state: .error,
                    errorMessage: error.localizedDescription
                )
            }
            persistSnapshots()
        }
    }

    private func fetchHybrid(for provider: ProviderID) async throws -> ProviderSnapshot? {
        let manual = KeychainStore.readSecret(account: KeychainStore.manualAccountKey(for: provider))
        let hasWeb = config.webSignedInProviders.contains(provider)

        switch provider {
        case .anthropic:
            // 1. Manual token or cookie
            if let manual {
                if manual.hasPrefix("sk-ant-oat") || (!manual.contains("=") && !manual.contains(";")) {
                    return try await AnthropicProvider.fetchViaOAuth(token: manual, source: .manualToken)
                } else {
                    do {
                        return try await AnthropicProvider.fetchViaCookieHeader(cookieHeader: manual)
                    } catch ProviderFetchError.cloudflareChallenge where hasWeb {
                        // Fall through to WebSession
                    }
                }
            }

            // 2. Local CLI / OpenCode OAuth
            if let local = LocalCredentialReader.readAnthropicOAuth(), !local.isExpired() {
                do {
                    return try await AnthropicProvider.fetchViaOAuth(
                        token: local.accessToken,
                        source: .localOAuth,
                        fallbackPlan: local.planHint
                    )
                } catch {
                    if !hasWeb { throw error }
                }
            }

            // 3. WebKit session
            if hasWeb {
                return try await WebSessionManager.shared.fetchWebQuota(for: .anthropic)
            }
            return nil

        case .openai:
            // 1. Manual Bearer token
            if let manual {
                return try await OpenAIProvider.fetchViaOAuth(accessToken: manual, source: .manualToken)
            }

            // 2. Local Codex / OpenCode OAuth (with non-destructive Keychain token refresh cache)
            if let local = resolveOpenAICredential() {
                do {
                    var activeToken = local.accessToken
                    if local.isExpired(), let refresh = local.refreshToken {
                        let renewed = try await OpenAIProvider.refreshOAuthToken(refresh)
                        activeToken = renewed.accessToken
                        var updated = local
                        updated.accessToken = renewed.accessToken
                        if let r = renewed.refreshToken { updated.refreshToken = r }
                        updated.expiresAt = renewed.expiresAt
                        saveCachedOAuth(updated, for: .openai)
                    }
                    return try await OpenAIProvider.fetchViaOAuth(
                        accessToken: activeToken,
                        accountID: local.accountID,
                        fallbackEmail: local.email,
                        source: .localOAuth
                    )
                } catch {
                    if !hasWeb { throw error }
                }
            }

            // 3. WebKit session
            if hasWeb {
                return try await WebSessionManager.shared.fetchWebQuota(for: .openai)
            }
            return nil

        case .google:
            // 1. Manual Cookie header
            if let manual {
                return try await GoogleProvider.fetchViaCookieHeader(cookieHeader: manual)
            }

            // 2. WebKit session
            if hasWeb {
                var snap = try await WebSessionManager.shared.fetchWebQuota(for: .google)
                // Best-effort Gemini API billing (AI Studio) using the same Google web session.
                if let billing = await WebSessionManager.shared.cachedAIStudioBilling() {
                    GoogleProvider.applyAIStudioBilling(billing, to: &snap)
                }
                return snap
            }
            return nil

        case .grok:
            // 1. Manual Bearer token
            if let manual {
                return try await GrokProvider.fetchViaCLIProxy(
                    bearerToken: manual,
                    source: .manualToken
                )
            }

            // 2. Local ~/.grok/auth.json via the CLI proxy (one cheap HTTPS request)
            let localAuth = LocalCredentialReader.readGrokOAuth()
            var proxyError: Error?
            if let localAuth, !localAuth.isExpired() {
                do {
                    return try await GrokProvider.fetchViaCLIProxy(
                        bearerToken: localAuth.accessToken,
                        fallbackEmail: localAuth.email,
                        fallbackPlan: localAuth.planHint,
                        source: .localOAuth
                    )
                } catch {
                    proxyError = error
                }
            }

            // 3. `grok agent stdio` (launches the ~190 MB CLI, which can also refresh its own token).
            // Backed off after a failure so a broken CLI is not relaunched on every refresh.
            if let grokBin = LocalCredentialReader.findGrokExecutable(),
               grokCLIRetryAfter.map({ Date() >= $0 }) ?? true {
                do {
                    let snap = try await GrokProvider.fetchViaGrokCLIStdio(
                        executablePath: grokBin,
                        fallbackEmail: localAuth?.email,
                        fallbackPlan: localAuth?.planHint
                    )
                    grokCLIRetryAfter = nil
                    return snap
                } catch {
                    grokCLIRetryAfter = Date().addingTimeInterval(Self.grokCLIBackoff)
                    if proxyError == nil { proxyError = error }
                }
            }
            if let proxyError, !hasWeb { throw proxyError }

            // 4. WebKit session
            if hasWeb {
                return try await WebSessionManager.shared.fetchWebQuota(for: .grok)
            }
            return nil
        }
    }

    private func resolveOpenAICredential() -> OAuthCredential? {
        let cachedKey = KeychainStore.cachedOAuthKey(for: .openai)
        if let raw = KeychainStore.readSecret(account: cachedKey),
           let data = raw.data(using: .utf8),
           let cached = try? JSONDecoder().decode(OAuthCredential.self, from: data),
           !cached.isExpired() {
            return cached
        }
        return LocalCredentialReader.readOpenAIOAuth()
    }

    private func saveCachedOAuth(_ cred: OAuthCredential, for provider: ProviderID) {
        guard let data = try? JSONEncoder().encode(cred),
              let str = String(data: data, encoding: .utf8) else { return }
        _ = KeychainStore.saveSecret(str, account: KeychainStore.cachedOAuthKey(for: provider))
    }

    private func persistSnapshots() {
        let url = AppConfig.snapshotCacheURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        let intervalSeconds = TimeInterval(max(1, config.refreshIntervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
        // Let macOS coalesce wakeups with other timers.
        timer?.tolerance = intervalSeconds * 0.1
    }
}
