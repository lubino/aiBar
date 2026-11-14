import AppKit
import Foundation
import AiBarCore

let args = CommandLine.arguments

if let previewIdx = args.firstIndex(of: "--render-preview"), args.count > previewIdx + 1 {
    let outPath = args[previewIdx + 1]
    MainActor.assumeIsolated {
        let sampleEntries: [(provider: ProviderID, numbers: [MenubarNumberToken])] = [
            (.google, [.init(value: 12, severity: .healthy), .init(value: 35, severity: .healthy)]),
            (.anthropic, [.init(value: 84, severity: .warning), .init(value: 36, severity: .healthy)]),
            (.openai, [.init(value: 15, severity: .healthy), .init(value: 41, severity: .healthy)]),
            (.grok, [.init(value: 24, severity: .healthy)])
        ]
        let singleGrok: [(provider: ProviderID, numbers: [MenubarNumberToken])] = [
            (.grok, [.init(value: 24, severity: .healthy)])
        ]

        let stripAll = StatusBarController.renderCompactStripImage(entries: sampleEntries, isDark: true)
        let stripGrok = StatusBarController.renderCompactStripImage(entries: singleGrok, isDark: true)

        let width = 460
        let height = 74
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * 2,
            pixelsHigh: height * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Row 1: Only Grok signed in (current live state)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        NSAttributedString(string: "1 signed-in provider:", attributes: labelAttrs).draw(at: NSPoint(x: 16, y: 46))
        let tintedGrok = NSImage(size: stripGrok.size, flipped: false) { r in
            stripGrok.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tintedGrok.draw(in: NSRect(x: 150, y: 44, width: stripGrok.size.width, height: stripGrok.size.height))

        // Row 2: All 4 providers signed in
        NSAttributedString(string: "All 4 signed-in:", attributes: labelAttrs).draw(at: NSPoint(x: 16, y: 16))
        stripAll.draw(in: NSRect(x: 150, y: 14, width: stripAll.size.width, height: stripAll.size.height))

        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
        }
        exit(0)
    }
} else if args.contains("--json") {
    MainActor.assumeIsolated {
        let store = UsageStore.shared
        Task { @MainActor in
            await store.refreshAll()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(store.snapshots),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            exit(0)
        }
        RunLoop.main.run()
    }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
