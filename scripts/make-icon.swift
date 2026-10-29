import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let p = CGFloat(pixels), inset = p * 0.06
        NSColor(red: 0.035, green: 0.085, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: p - inset * 2, height: p - inset * 2), xRadius: p * 0.21, yRadius: p * 0.21).fill()
        NSColor(red: 0.22, green: 0.88, blue: 0.77, alpha: 1).setFill()
        let heights: [CGFloat] = [0.16, 0.32, 0.5, 0.28, 0.58, 0.4, 0.18]
        for (i, height) in heights.enumerated() {
            NSBezierPath(roundedRect: NSRect(x: p * (0.205 + CGFloat(i) * 0.087), y: p * (1 - height) / 2,
                                           width: p * 0.052, height: p * height), xRadius: p * 0.026, yRadius: p * 0.026).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
