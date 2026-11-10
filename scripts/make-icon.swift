import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 190, yRadius: 190).fill()
        let colors = [NSColor(calibratedRed: 0.15, green: 0.43, blue: 0.86, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.39, blue: 0.12, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.57, alpha: 1)]
        for (index, y) in [730.0, 512.0, 294.0].enumerated() {
            colors[index].setStroke()
            let path = NSBezierPath()
            path.lineWidth = 44
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 265, y: 512))
            path.curve(to: NSPoint(x: 600, y: y), controlPoint1: NSPoint(x: 450, y: 512), controlPoint2: NSPoint(x: 425, y: y))
            path.line(to: NSPoint(x: 750, y: y))
            path.stroke()
            colors[index].setFill()
            NSBezierPath(ovalIn: NSRect(x: 718, y: y - 38, width: 76, height: 76)).fill()
        }
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 222, y: 470, width: 84, height: 84)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
