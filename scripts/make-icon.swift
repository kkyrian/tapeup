// Draws the TapeUp app icon: a red record dot and two level lanes (Mac audio
// above, the mic below) on a dark tile. Writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.135, blue: 0.15, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(
        starting: NSColor(calibratedRed: 0.22, green: 0.225, blue: 0.245, alpha: 1),
        ending: NSColor(calibratedRed: 0.09, green: 0.095, blue: 0.105, alpha: 1))!.draw(in: shape, angle: -90)

    // Record dot.
    let dot = NSRect(x: 196 * s, y: 452 * s, width: 120 * s, height: 120 * s)
    NSGradient(
        starting: NSColor(calibratedRed: 1, green: 0.42, blue: 0.36, alpha: 1),
        ending: NSColor(calibratedRed: 0.92, green: 0.2, blue: 0.17, alpha: 1))!.draw(
            in: NSBezierPath(ovalIn: dot), angle: -90)

    // Two lanes of bars.
    let top: [CGFloat] = [0.35, 0.6, 0.9, 0.55, 0.75, 1.0, 0.65, 0.45, 0.8, 0.5]
    let bottom: [CGFloat] = [0.2, 0.2, 0.55, 0.85, 0.4, 0.2, 0.2, 0.6, 0.3, 0.2]
    for (lane, (heights, alpha, centerY)) in [(top, 0.95, 640.0), (bottom, 0.5, 384.0)].enumerated() {
        _ = lane
        for (index, h) in heights.enumerated() {
            let width: CGFloat = 26 * s
            let height = max(width, h * 170 * s)
            let x = (372 + CGFloat(index) * 46) * s
            let rect = NSRect(x: x, y: centerY * s - height / 2, width: width, height: height)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let data = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try! draw(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "tmp/icon-preview.png"))
print("Resources/AppIcon.icns")
