import AppKit

/// Temporarily promotes the menu-bar accessory app to `.regular` while a login or settings window is open,
/// so the user can ⌘-Tab to Mail / 1Password / Authenticator during 2FA and return to the sign-in window effortlessly.
@MainActor
public enum WindowActivationCoordinator {
    private static var openWindowCount = 0

    public static func windowDidOpen(_ window: NSWindow?) {
        openWindowCount += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func windowDidClose() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            // Defer slightly so AppKit finishes window close animation cleanly before hiding Dock icon
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if openWindowCount == 0 {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
