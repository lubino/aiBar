import AppKit
import SwiftUI
import Combine
import AiBarCore

@MainActor
public final class StatusBarController: NSObject {
    private let store: UsageStore
    private let onOpenSettings: () -> Void

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    public init(store: UsageStore, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "sk.lubino.aiBar.unified"
        super.init()

        if let btn = statusItem.button {
            btn.imagePosition = .imageOnly
            btn.title = ""
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])

            appearanceObservation = btn.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.updateMenubarStrip()
                }
            }
        }

        configurePopover()
        bindStore()
        updateMenubarStrip()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let rootView = PopoverRootView(
            store: store,
            onOpenSettings: { [weak self] in
                self?.closePopover()
                self?.onOpenSettings()
            },
            onClosePopover: { [weak self] in
                self?.closePopover()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    private func bindStore() {
        store.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenubarStrip()
            }
            .store(in: &cancellables)

        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenubarStrip()
            }
            .store(in: &cancellables)

        store.$refreshingProviders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenubarStrip()
            }
            .store(in: &cancellables)
    }

    private func updateMenubarStrip() {
        guard let btn = statusItem.button else { return }

        let mode = store.config.percentageMode
        var activeEntries: [(provider: ProviderID, numbers: [MenubarNumberToken])] = []
        var tooltipLines: [String] = []

        for provider in store.config.enabledProviders {
            let snap = store.snapshot(for: provider)
            let nums = snap.menubarNumbers(mode: mode)
            guard !nums.isEmpty else { continue }
            activeEntries.append((provider, nums))
            let joined = nums.map { "\($0.value)%" }.joined(separator: " / ")
            tooltipLines.append("\(provider.displayName): \(joined)")
        }

        if activeEntries.isEmpty {
            let icon = ProviderIcons.appFallbackIcon(size: 13)
            btn.image = icon
            statusItem.length = 22
            btn.toolTip = "aiBar — Click to sign in"
            return
        }

        let isDarkAppearance = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua]) != .aqua
        let strip = Self.renderCompactStripImage(entries: activeEntries, isDark: isDarkAppearance)
        btn.image = strip
        // Tight fixed length eliminates macOS's wide default NSStatusBarButton horizontal padding
        statusItem.length = ceil(strip.size.width) + 6
        btn.toolTip = tooltipLines.joined(separator: "\n")
    }

    /// Renders a razor-sharp, ultra-compact single-item strip: `[icon]24 [icon]18 42`
    public static func renderCompactStripImage(
        entries: [(provider: ProviderID, numbers: [MenubarNumberToken])],
        isDark: Bool
    ) -> NSImage {
        let stripHeight: CGFloat = 16
        let iconSize: CGFloat = 12
        let iconToNumberGap: CGFloat = 1.0
        let interNumberGap: CGFloat = 2.5
        let interProviderGap: CGFloat = 5.5

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .semibold)
        let hasColoredAlert = entries.contains { entry in
            entry.numbers.contains { $0.severity != .healthy }
        }

        let baseColor: NSColor = hasColoredAlert
            ? (isDark ? NSColor.white : NSColor.black)
            : NSColor.black

        func attributes(for severity: QuotaSeverity) -> [NSAttributedString.Key: Any] {
            let color: NSColor
            switch severity {
            case .healthy:
                color = baseColor
            case .warning:
                color = NSColor.systemOrange
            case .critical:
                color = NSColor.systemRed
            }
            return [
                .font: font,
                .foregroundColor: color,
                .kern: -0.45
            ]
        }

        // 1. Measure exact width
        var totalWidth: CGFloat = 0
        var measuredEntries: [(provider: ProviderID, strings: [NSAttributedString])] = []

        for (idx, entry) in entries.enumerated() {
            if idx > 0 {
                totalWidth += interProviderGap
            }
            totalWidth += iconSize + iconToNumberGap
            var attrStrings: [NSAttributedString] = []
            for (nIdx, tok) in entry.numbers.enumerated() {
                if nIdx > 0 {
                    totalWidth += interNumberGap
                }
                let s = NSAttributedString(string: "\(tok.value)", attributes: attributes(for: tok.severity))
                totalWidth += ceil(s.size().width)
                attrStrings.append(s)
            }
            measuredEntries.append((entry.provider, attrStrings))
        }

        let finalWidth = max(12, ceil(totalWidth))
        let img = NSImage(size: NSSize(width: finalWidth, height: stripHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (idx, item) in measuredEntries.enumerated() {
                if idx > 0 {
                    x += interProviderGap
                }

                // Draw company icon tinted to baseColor
                let rawIcon = ProviderIcons.menuBarIcon(for: item.provider, size: iconSize)
                let iconRect = NSRect(x: x, y: (stripHeight - iconSize) / 2.0, width: iconSize, height: iconSize)
                if hasColoredAlert {
                    let tinted = NSImage(size: rawIcon.size, flipped: false) { r in
                        rawIcon.draw(in: r)
                        baseColor.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: iconRect)
                } else {
                    rawIcon.draw(in: iconRect)
                }
                x += iconSize + iconToNumberGap

                // Draw tight numbers
                for (nIdx, attrStr) in item.strings.enumerated() {
                    if nIdx > 0 {
                        x += interNumberGap
                    }
                    let sz = attrStr.size()
                    let y = (stripHeight - sz.height) / 2.0 - 0.3
                    attrStr.draw(at: NSPoint(x: x, y: y))
                    x += ceil(sz.width)
                }
            }
            return true
        }

        // When all numbers are normal (<80% used), template mode gives native macOS menu bar vibrancy
        img.isTemplate = !hasColoredAlert
        return img
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
            return
        }

        let screenHeight = (sender.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        store.maxPopoverHeight = max(420, screenHeight - 48)

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    self?.closePopover()
                }
            }
        }
    }

    public func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
