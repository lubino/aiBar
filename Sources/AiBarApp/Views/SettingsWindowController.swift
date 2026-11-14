import AppKit
import SwiftUI
import AiBarCore

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()
    private var isCurrentlyOpen = false

    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "aiBar Settings"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(rootView: SettingsRootView(store: UsageStore.shared))
        super.init(window: win)
        win.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func present() {
        showWindow(nil)
        if !isCurrentlyOpen {
            isCurrentlyOpen = true
            WindowActivationCoordinator.windowDidOpen(window)
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if isCurrentlyOpen {
            isCurrentlyOpen = false
            WindowActivationCoordinator.windowDidClose()
        }
    }
}

@MainActor
private struct SettingsRootView: View {
    @ObservedObject var store: UsageStore

    private let intervals = [2, 5, 15, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Providers") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ProviderID.allCases) { provider in
                        HStack(spacing: 10) {
                            Toggle(
                                isOn: Binding(
                                    get: { store.config.isEnabled(provider) },
                                    set: { store.toggleProvider(provider, enabled: $0) }
                                )
                            ) {
                                HStack(spacing: 7) {
                                    Image(nsImage: ProviderIcons.menuBarIcon(for: provider, size: 15))
                                        .renderingMode(.template)
                                    Text(provider.displayName)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("(\(provider.productSubtitle))")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            let snap = store.snapshot(for: provider)
                            Text(snap.state == .signedOut ? "Hidden (not signed in)" : snap.authSource.rawValue)
                                .font(.system(size: 11))
                                .foregroundColor(snap.state == .signedOut ? .secondary : .green)

                            Button("Sign In…") {
                                store.openWebSignIn(for: provider)
                            }
                            .controlSize(.small)

                            Button("Token…") {
                                ManualSecretPrompt.present(for: provider, store: store)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Menu Bar & Refresh") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Menu bar numbers show:")
                            .font(.system(size: 12.5))
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.config.percentageMode },
                                set: { store.setPercentageMode($0) }
                            )
                        ) {
                            ForEach(PercentageDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    HStack {
                        Text("Refresh interval:")
                            .font(.system(size: 12.5))
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.config.refreshIntervalMinutes },
                                set: { store.setRefreshInterval(minutes: $0) }
                            )
                        ) {
                            ForEach(intervals, id: \.self) { mins in
                                Text("Every \(mins) minutes").tag(mins)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    Toggle(
                        "Launch aiBar at Login",
                        isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        )
                    )
                    .font(.system(size: 12.5))
                }
                .padding(8)
            }

            HStack {
                Text("Only providers with active numbers appear in the unified menu bar strip.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh All Now") {
                    Task { await store.refreshAll() }
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}
