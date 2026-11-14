import AppKit
import WebKit
import AiBarCore

@MainActor
public final class WebLoginWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var activeControllers: [ProviderID: WebLoginWindowController] = [:]

    private let provider: ProviderID
    private let onAuthenticated: (ProviderSnapshot) -> Void
    private var webView: WKWebView!
    private var urlLabel: NSTextField!
    private var statusSpinner: NSProgressIndicator!
    private var verifyButton: NSButton!
    private var popupWindows: [NSWindow] = []
    private var autoCheckTask: Task<Void, Never>?

    public static func present(
        for provider: ProviderID,
        onAuthenticated: @escaping (ProviderSnapshot) -> Void
    ) {
        if let existing = activeControllers[provider] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = WebLoginWindowController(provider: provider, onAuthenticated: onAuthenticated)
        activeControllers[provider] = controller
        controller.showWindow(nil)
        WindowActivationCoordinator.windowDidOpen(controller.window)
    }

    private init(provider: ProviderID, onAuthenticated: @escaping (ProviderSnapshot) -> Void) {
        self.provider = provider
        self.onAuthenticated = onAuthenticated

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign In to \(provider.displayName) — aiBar"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        setupContentView()
        webView.load(URLRequest(url: provider.loginURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContentView() {
        guard let window else { return }
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]

        // Top toolbar strip
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let lockIcon = NSImageView()
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")
        lockIcon.contentTintColor = .secondaryLabelColor

        urlLabel = NSTextField(labelWithString: provider.loginURL.absoluteString)
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle

        statusSpinner = NSProgressIndicator()
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false

        let reloadBtn = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")!,
            target: self,
            action: #selector(reloadTapped)
        )
        reloadBtn.translatesAutoresizingMaskIntoConstraints = false
        reloadBtn.bezelStyle = .texturedRounded

        verifyButton = NSButton(title: "Done — Read Quota", target: self, action: #selector(verifyTapped))
        verifyButton.translatesAutoresizingMaskIntoConstraints = false
        verifyButton.bezelStyle = .rounded
        verifyButton.keyEquivalent = "\r"
        verifyButton.contentTintColor = .controlAccentColor

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let cfg = WebSessionManager.shared.makeWebViewConfiguration(for: provider)
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.customUserAgent = WebSessionManager.safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self

        topBar.addSubview(lockIcon)
        topBar.addSubview(urlLabel)
        topBar.addSubview(statusSpinner)
        topBar.addSubview(reloadBtn)
        topBar.addSubview(verifyButton)

        container.addSubview(topBar)
        container.addSubview(divider)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 42),

            lockIcon.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            lockIcon.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 14),

            urlLabel.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 6),
            urlLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSpinner.leadingAnchor, constant: -10),

            statusSpinner.trailingAnchor.constraint(equalTo: reloadBtn.leadingAnchor, constant: -8),
            statusSpinner.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            reloadBtn.trailingAnchor.constraint(equalTo: verifyButton.leadingAnchor, constant: -8),
            reloadBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            verifyButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            verifyButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        window.contentView = container
    }

    @objc private func reloadTapped() {
        webView.reload()
    }

    @objc private func verifyTapped() {
        Task { @MainActor in
            await verifyAndComplete(showAlertOnFailure: true)
        }
    }

    private func verifyAndComplete(showAlertOnFailure: Bool) async {
        statusSpinner.startAnimation(nil)
        verifyButton.isEnabled = false
        defer {
            statusSpinner.stopAnimation(nil)
            verifyButton.isEnabled = true
        }

        // First try probing directly in the live login webView if we're already on the target host
        if let host = webView.url?.host, isProviderAppHost(host) {
            if let jsonStr = try? await WebSessionManager.shared.runProviderScript(for: provider, in: webView),
               let data = jsonStr.data(using: .utf8),
               let snapshot = try? decodeProviderBundle(data) {
                onAuthenticated(snapshot)
                window?.close()
                return
            }
        }

        // Otherwise run full WebSessionManager fetch on the canonical origin URL
        do {
            let snapshot = try await WebSessionManager.shared.fetchWebQuota(for: provider)
            onAuthenticated(snapshot)
            window?.close()
        } catch {
            if showAlertOnFailure, let window {
                let alert = NSAlert()
                alert.messageText = "Sign-In Not Complete Yet"
                alert.informativeText = "\(error.localizedDescription)\n\nFinish signing in inside the window, then click 'Done — Read Quota'."
                alert.alertStyle = .informational
                _ = await alert.beginSheetModal(for: window)
            }
        }
    }

    private func decodeProviderBundle(_ data: Data) throws -> ProviderSnapshot {
        switch provider {
        case .anthropic: return try AnthropicProvider.parseWebBundleJSON(data)
        case .openai: return try OpenAIProvider.parseWebBundleJSON(data)
        case .google: return try GoogleProvider.parseWebBundleJSON(data)
        case .grok: return try GrokProvider.parseWebBundleJSON(data)
        }
    }

    private func isProviderAppHost(_ host: String) -> Bool {
        let h = host.lowercased()
        switch provider {
        case .google: return h == "gemini.google.com"
        case .anthropic: return h == "claude.ai"
        case .openai: return h == "chatgpt.com"
        case .grok: return h == "grok.com"
        }
    }

    private func isLikelyAuthenticatedLandingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), isProviderAppHost(host) else { return false }
        let path = url.path.lowercased()
        if path.contains("login") || path.contains("auth") || path.contains("signin") {
            return false
        }
        return true
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        statusSpinner.startAnimation(nil)
        if let u = webView.url {
            urlLabel.stringValue = u.absoluteString
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusSpinner.stopAnimation(nil)
        guard let u = webView.url else { return }
        urlLabel.stringValue = u.absoluteString

        if isLikelyAuthenticatedLandingURL(u) {
            autoCheckTask?.cancel()
            autoCheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                await self?.verifyAndComplete(showAlertOnFailure: false)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusSpinner.stopAnimation(nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusSpinner.stopAnimation(nil)
    }

    // MARK: - WKUIDelegate (OAuth Popup Support for "Continue with Google / Apple")

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popupView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 640), configuration: configuration)
        popupView.customUserAgent = WebSessionManager.safariUserAgent
        popupView.uiDelegate = self

        let popupWin = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWin.title = "Sign In"
        popupWin.contentView = popupView
        popupWin.center()
        popupWin.isReleasedWhenClosed = false
        popupWin.makeKeyAndOrderFront(nil)
        popupWindows.append(popupWin)
        return popupView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        if let win = popupWindows.first(where: { $0.contentView === webView }) {
            win.close()
            popupWindows.removeAll { $0 === win }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        autoCheckTask?.cancel()
        for p in popupWindows {
            p.close()
        }
        popupWindows.removeAll()
        webView?.stopLoading()
        Self.activeControllers[provider] = nil
        WindowActivationCoordinator.windowDidClose()
    }
}
