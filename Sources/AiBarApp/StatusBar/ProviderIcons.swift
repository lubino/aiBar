import AppKit
import AiBarCore

public enum ProviderIcons {
    /// Returns a crisp 16x16 template vector icon for the macOS menu bar and UI headers.
    public static func menuBarIcon(for provider: ProviderID, size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let scale = size / 24.0
            ctx.scaleBy(x: scale, y: scale)

            NSColor.black.setFill()
            NSColor.black.setStroke()

            switch provider {
            case .google:
                drawGoogleG(in: ctx)
            case .anthropic:
                drawAnthropicMark(in: ctx)
            case .openai:
                drawOpenAIKnot(in: ctx)
            case .grok:
                drawGrokMark(in: ctx)
            }

            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Minimal fallback icon shown when zero providers have active numbers yet.
    public static func appFallbackIcon(size: CGFloat = 13) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let scale = size / 24.0
            ctx.scaleBy(x: scale, y: scale)
            NSColor.black.setFill()
            let heights: [CGFloat] = [14, 19, 11, 16]
            for (i, h) in heights.enumerated() {
                let x = 3.0 + CGFloat(i) * 5.0
                let r = CGRect(x: x, y: 3.0, width: 3.2, height: h)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
                ctx.fillPath()
            }
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    // Classic Google "G" silhouette in a 24x24 coordinate space (y-up)
    private static func drawGoogleG(in ctx: CGContext) {
        let center = CGPoint(x: 12, y: 12)
        ctx.setLineWidth(3.6)
        ctx.setLineCap(.butt)

        // Outer C-arc from 42° counter-clockwise to 356°
        let startAngle = 42.0 * .pi / 180.0
        let endAngle = -4.0 * .pi / 180.0
        ctx.addArc(center: center, radius: 8.2, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        ctx.strokePath()

        // Horizontal crossbar of the G
        let bar = CGRect(x: 12.0, y: 10.2, width: 9.8, height: 3.4)
        ctx.fill(bar)
    }

    // Anthropic "A\" geometric mark in a 24x24 coordinate space (y-up)
    private static func drawAnthropicMark(in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.6)

        // Left "A" chevron + crossbar
        ctx.move(to: CGPoint(x: 2.8, y: 4.5))
        ctx.addLine(to: CGPoint(x: 8.6, y: 19.5))
        ctx.addLine(to: CGPoint(x: 14.4, y: 4.5))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: 5.0, y: 9.3))
        ctx.addLine(to: CGPoint(x: 12.2, y: 9.3))
        ctx.strokePath()

        // Right "\" parallel slash
        ctx.move(to: CGPoint(x: 15.6, y: 19.5))
        ctx.addLine(to: CGPoint(x: 21.3, y: 4.5))
        ctx.strokePath()
    }

    // OpenAI 6-fold interlocking knot in a 24x24 coordinate space
    private static func drawOpenAIKnot(in ctx: CGContext) {
        ctx.setLineWidth(1.9)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for i in 0..<6 {
            ctx.saveGState()
            ctx.translateBy(x: 12, y: 12)
            ctx.rotate(by: CGFloat(i) * (.pi / 3.0))

            let path = CGMutablePath()
            // Each petal loops from near center outward and arcs into the adjacent petal
            path.move(to: CGPoint(x: 0.0, y: 2.8))
            path.addLine(to: CGPoint(x: 4.2, y: 5.2))
            path.addArc(
                center: CGPoint(x: 2.5, y: 6.9),
                radius: 3.1,
                startAngle: -.pi / 6.0,
                endAngle: 5.0 * .pi / 6.0,
                clockwise: false
            )
            path.addLine(to: CGPoint(x: -2.4, y: 4.2))
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // Grok / xAI orbital ring + diagonal slash mark in a 24x24 coordinate space (y-up)
    private static func drawGrokMark(in ctx: CGContext) {
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)

        // Broken orbital ring
        ctx.addArc(
            center: CGPoint(x: 11.6, y: 12.0),
            radius: 7.6,
            startAngle: 58.0 * .pi / 180.0,
            endAngle: 332.0 * .pi / 180.0,
            clockwise: false
        )
        ctx.strokePath()

        // Signature bold upward-right slash piercing the ring
        ctx.setLineWidth(2.7)
        ctx.move(to: CGPoint(x: 6.5, y: 5.2))
        ctx.addLine(to: CGPoint(x: 19.6, y: 19.2))
        ctx.strokePath()
    }
}
