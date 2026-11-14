import AppKit
import SwiftUI
import AiBarCore

@MainActor
public struct PopoverRootView: View {
    @ObservedObject public var store: UsageStore
    public let onOpenSettings: () -> Void
    public let onClosePopover: () -> Void

    public init(
        store: UsageStore,
        onOpenSettings: @escaping () -> Void,
        onClosePopover: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onClosePopover = onClosePopover
    }

    public var body: some View {
        let maxBodyHeight = max(300, store.maxPopoverHeight - 86)

        VStack(spacing: 0) {
            tabHeaderBar
            Divider()

            MaxHeightProposingLayout(maxHeight: maxBodyHeight) {
                ViewThatFits(in: .vertical) {
                    popoverBodyContent
                    ScrollView(.vertical, showsIndicators: true) {
                        popoverBodyContent
                    }
                }
            }

            Divider()
            footerBar
        }
        .frame(width: 376)
    }

    private var popoverBodyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.selectedTab {
            case .all:
                let active = store.config.enabledProviders.filter { store.snapshot(for: $0).state != .signedOut }
                let inactive = store.config.enabledProviders.filter { store.snapshot(for: $0).state == .signedOut }

                ForEach(active) { provider in
                    ProviderSummaryCard(
                        snapshot: store.snapshot(for: provider),
                        mode: store.config.percentageMode,
                        isRefreshing: store.refreshingProviders.contains(provider),
                        onSelectDetail: {
                            store.selectedTab = .provider(provider)
                        },
                        onClosePopover: onClosePopover
                    )
                }

                if !inactive.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect Providers")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, active.isEmpty ? 0 : 4)

                        ForEach(inactive) { provider in
                            UnsignedCompactRow(
                                provider: provider,
                                onSignIn: {
                                    onClosePopover()
                                    store.openWebSignIn(for: provider)
                                },
                                onSelectDetail: {
                                    store.selectedTab = .provider(provider)
                                }
                            )
                        }
                    }
                }

            case .provider(let provider):
                ProviderDetailCard(
                    store: store,
                    provider: provider,
                    onClosePopover: onClosePopover
                )
            }
        }
        .padding(14)
        .frame(width: 376, alignment: .leading)
    }

    // MARK: - Top Tab Switcher

    private var tabHeaderBar: some View {
        HStack(spacing: 4) {
            let allSelected = (store.selectedTab == .all)
            Button {
                store.selectedTab = .all
            } label: {
                Text("All")
                    .font(.system(size: 11.5, weight: allSelected ? .semibold : .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(allSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundColor(allSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            ForEach(store.config.enabledProviders) { provider in
                let isSelected = (store.selectedTab == .provider(provider))
                Button {
                    store.selectedTab = .provider(provider)
                } label: {
                    HStack(spacing: 4) {
                        Image(nsImage: ProviderIcons.menuBarIcon(for: provider, size: 12))
                            .renderingMode(.template)
                        Text(provider.displayName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundColor(isSelected ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Bottom App Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.refreshingProviders.isEmpty ? Color.green.opacity(0.85) : Color.accentColor)
                .frame(width: 7, height: 7)

            Text(
                store.refreshingProviders.isEmpty
                    ? ResetFormatter.relativeUpdatedString(since: store.lastGlobalRefreshAt)
                    : "Refreshing…"
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)

            Spacer()

            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Refresh All Providers")

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("aiBar Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Quit aiBar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Single Provider Full Detail View

@MainActor
private struct ProviderDetailCard: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderID
    let onClosePopover: () -> Void

    private var snap: ProviderSnapshot {
        store.snapshot(for: provider)
    }

    private var isRefreshing: Bool {
        store.refreshingProviders.contains(provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection

            if let err = snap.errorMessage, !err.isEmpty {
                errorBanner(err)
            }

            switch snap.state {
            case .signedOut:
                signedOutSection
            case .loading where snap.allWindows.isEmpty:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(provider.displayName) quota…")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            case .freeDynamic:
                freeDynamicSection
            default:
                windowsSection
            }

            if snap.availableCredit != nil || !snap.details.isEmpty {
                ProviderCreditsSection(snapshot: snap)
            }

            webLinksSection
            accountActionsSection
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 34, height: 34)
                Image(nsImage: ProviderIcons.menuBarIcon(for: provider, size: 18))
                    .renderingMode(.template)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 14.5, weight: .semibold))
                    if let plan = snap.planName, !plan.isEmpty {
                        Text(plan)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundColor(.accentColor)
                    }
                }
                Text(subtitleText)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh(provider: provider) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh \(provider.displayName)")
            }
        }
    }

    private var subtitleText: String {
        if let email = snap.accountEmail, !email.isEmpty {
            return "\(email) · \(snap.authSource.rawValue)"
        }
        if snap.authSource != .none {
            return "\(provider.productSubtitle) · \(snap.authSource.rawValue)"
        }
        return provider.productSubtitle
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var signedOutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not signed in — hidden from the menu bar until connected.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onClosePopover()
                store.openWebSignIn(for: provider)
            } label: {
                Label("Sign In (\(provider.displayName))…", systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if provider == .grok && LocalCredentialReader.findGrokExecutable() != nil {
                Button {
                    onClosePopover()
                    store.openGrokTerminalLogin()
                } label: {
                    Label("Sign In via Grok CLI (grok login)", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                ManualSecretPrompt.present(for: provider, store: store)
            } label: {
                Label("Paste Token or Cookie…", systemImage: "key")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var freeDynamicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text("Dynamic Free Quota")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("This account is on a tier without fixed percentage windows.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var windowsSection: some View {
        VStack(spacing: 10) {
            ForEach(snap.allWindows) { window in
                QuotaWindowRow(window: window, mode: store.config.percentageMode)
            }
        }
    }

    private var webLinksSection: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(provider.usageWebURL)
                onClosePopover()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar.xaxis")
                    Text("Usage in Web")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                NSWorkspace.shared.open(provider.settingsWebURL)
                onClosePopover()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Settings in Web")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var accountActionsSection: some View {
        HStack(spacing: 10) {
            if snap.state != .signedOut {
                Button("Web Sign-In…") {
                    onClosePopover()
                    store.openWebSignIn(for: provider)
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))

                Button("Token…") {
                    ManualSecretPrompt.present(for: provider, store: store)
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))

                Spacer()

                Button("Sign Out") {
                    Task { await store.signOut(provider: provider) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .foregroundColor(.red)
            }
        }
    }
}

// MARK: - Shared Available Credit & Extra Details Section

private struct ProviderCreditsSection: View {
    let snapshot: ProviderSnapshot

    private func isPositiveCredit(_ text: String) -> Bool {
        if text.lowercased() == "unlimited" { return true }
        let digitsAndDot = text.filter { $0.isNumber || $0 == "." }
        if let val = Double(digitsAndDot) {
            return val > 0.0
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let credit = snapshot.availableCredit, !credit.isEmpty {
                let positive = isPositiveCredit(credit)
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(positive ? .green : .secondary)
                    Text("Available Credit")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(credit)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundColor(positive ? .green : .secondary)
                }
            }

            ForEach(snapshot.details) { item in
                HStack {
                    Text(item.label)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(item.value)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

// MARK: - Quota Window Card

private struct QuotaWindowRow: View {
    let window: QuotaWindow
    let mode: PercentageDisplayMode

    private var barColor: Color {
        switch window.severity {
        case .healthy: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if mode == .used {
                    Text("\(window.usedPercentInt)% used")
                        .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                        .foregroundColor(window.severity == .healthy ? .primary : barColor)
                    Text("(\(window.remainingPercentInt)% free)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Text("\(window.remainingPercentInt)% free")
                        .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                        .foregroundColor(window.severity == .healthy ? .primary : barColor)
                    Text("(\(window.usedPercentInt)% used)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geo in
                let fraction = mode == .used ? window.usedFraction : window.remainingFraction
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 7)
                    Capsule()
                        .fill(barColor)
                        .frame(width: fraction > 0 ? max(4, geo.size.width * fraction) : 0, height: 7)
                }
            }
            .frame(height: 7)

            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                if let reset = window.resetsAt {
                    Text(ResetFormatter.countdownString(until: reset))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(ResetFormatter.exactClockString(for: reset))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Text("Reset schedule managed by provider")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

// MARK: - Rich Summary Card ("All" tab for active providers)

private struct ProviderSummaryCard: View {
    let snapshot: ProviderSnapshot
    let mode: PercentageDisplayMode
    let isRefreshing: Bool
    let onSelectDetail: () -> Void
    let onClosePopover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Button(action: onSelectDetail) {
                    HStack(spacing: 7) {
                        Image(nsImage: ProviderIcons.menuBarIcon(for: snapshot.provider, size: 15))
                            .renderingMode(.template)
                        Text(snapshot.provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        if let plan = snapshot.planName {
                            Text(plan)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if isRefreshing {
                    ProgressView().controlSize(.mini)
                }

                Button {
                    NSWorkspace.shared.open(snapshot.provider.usageWebURL)
                    onClosePopover()
                } label: {
                    Text("Usage ↗")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    NSWorkspace.shared.open(snapshot.provider.settingsWebURL)
                    onClosePopover()
                } label: {
                    Text("Settings ↗")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ForEach(snapshot.allWindows) { win in
                QuotaWindowRow(window: win, mode: mode)
            }

            if snapshot.availableCredit != nil || !snapshot.details.isEmpty {
                ProviderCreditsSection(snapshot: snapshot)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct UnsignedCompactRow: View {
    let provider: ProviderID
    let onSignIn: () -> Void
    let onSelectDetail: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onSelectDetail) {
                HStack(spacing: 7) {
                    Image(nsImage: ProviderIcons.menuBarIcon(for: provider, size: 14))
                        .renderingMode(.template)
                        .foregroundColor(.secondary)
                    Text(provider.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                    Text("(\(provider.productSubtitle))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Sign In…", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.035))
        )
    }
}

// MARK: - AppKit Modal Prompt for Manual Token / Cookie (stored in macOS Keychain)

@MainActor
public enum ManualSecretPrompt {
    public static func present(for provider: ProviderID, store: UsageStore) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(provider.displayName) Token or Cookie"
        alert.informativeText = "Stored securely in your macOS Login Keychain. Leave empty to remove any saved manual credential."
        alert.addButton(withTitle: "Save to Keychain")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.placeholderString = provider.manualTokenPlaceholder
        if let existing = KeychainStore.readSecret(account: KeychainStore.manualAccountKey(for: provider)) {
            input.stringValue = existing
        }
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            store.saveManualSecret(input.stringValue, for: provider)
        }
    }
}

/// Proposes an explicit upper-bound height (`maxHeight`) to `ViewThatFits(in: .vertical)` even when
/// `NSHostingController` queries unconstrained ideal size (`height: nil`), while shrinking to the exact
/// intrinsic height whenever the content fits on screen without scrolling.
private struct MaxHeightProposingLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let limit = min(proposal.height ?? maxHeight, maxHeight)
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: limit))
        return CGSize(width: size.width, height: min(size.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
