import AppKit
import AiBarCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupHiddenMainMenuForKeyboardShortcuts()

        let store = UsageStore.shared
        statusBarController = StatusBarController(
            store: store,
            onOpenSettings: {
                SettingsWindowController.shared.present()
            }
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        Task { @MainActor in
            await store.refreshAll()
        }
    }

    @objc private func systemDidWake() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await UsageStore.shared.refreshAll()
        }
    }

    /// Accessory (LSUIElement) apps need an Edit/Window menu in NSApp.mainMenu so ⌘C, ⌘V, ⌘X, ⌘A, ⌘W, ⌘Q work in WKWebView and NSTextField.
    private func setupHiddenMainMenuForKeyboardShortcuts() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "aiBar")
        appMenu.addItem(withTitle: "About aiBar", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsShortcut), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Refresh All", action: #selector(refreshAllShortcut), keyEquivalent: "r")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit aiBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Standard macOS About panel with the bundle version and a clickable link to the Git repository.
    @objc private func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: "AI subscription usage limits in your menu bar.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        credits.append(NSAttributedString(
            string: AppInfo.repositoryURL.absoluteString,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: AppInfo.repositoryURL,
                .paragraphStyle: paragraph,
            ]
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "aiBar",
            .applicationVersion: AppInfo.versionString,
            .version: "",
            .credits: credits,
        ])
    }

    @objc private func openSettingsShortcut() {
        SettingsWindowController.shared.present()
    }

    @objc private func refreshAllShortcut() {
        Task { @MainActor in
            await UsageStore.shared.refreshAll()
        }
    }
}
