import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift scripts/generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetPath = args[1]
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderAppIcon(pixelSize: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixelSize)

    // macOS squircle inset
    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = rect.width * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let colors = [
        CGColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 1.0),
        CGColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: s * 0.5, y: s), end: CGPoint(x: s * 0.5, y: 0), options: [])
    ctx.restoreGState()

    // Subtle border
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.strokePath()

    // Four sleek vertical quota bars (Google blue, Anthropic coral, OpenAI emerald, Grok silver)
    let barColors: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.32, 0.56, 0.98, 0.88),
        (0.88, 0.48, 0.34, 0.68),
        (0.16, 0.78, 0.60, 0.94),
        (0.92, 0.94, 0.98, 0.76)
    ]
    let totalW = rect.width * 0.58
    let gap = rect.width * 0.055
    let barW = (totalW - 3 * gap) / 4.0
    let maxH = rect.height * 0.54
    let startX = rect.midX - totalW / 2.0
    let baseY = rect.midY - maxH / 2.0

    for (idx, item) in barColors.enumerated() {
        let x = startX + CGFloat(idx) * (barW + gap)
        // Track
        let trackRect = CGRect(x: x, y: baseY, width: barW, height: maxH)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.addPath(trackPath)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
        ctx.fillPath()

        // Fill
        let fillH = maxH * item.3
        let fillRect = CGRect(x: x, y: baseY, width: barW, height: fillH)
        let fillPath = CGPath(roundedRect: fillRect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.addPath(fillPath)
        ctx.setFillColor(CGColor(srgbRed: item.0, green: item.1, blue: item.2, alpha: 1.0))
        ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    if let data = renderAppIcon(pixelSize: px) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        try data.write(to: outURL)
    }
}
