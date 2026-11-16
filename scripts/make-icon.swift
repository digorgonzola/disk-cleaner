// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
// Drawn with CoreGraphics only: SF Symbols may not be used in app icons.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func drawIcon(in context: CGContext) {
    // macOS icon grid: an 824 pt rounded square centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x1B1F4B))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x2B2F7A), color(0x151838)] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    let centre = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 270
    let ringWidth: CGFloat = 92

    func arc(from start: CGFloat, to end: CGFloat, _ strokeColor: CGColor) {
        // Angles in degrees, clockwise from 12 o'clock.
        let toRadians = { (degrees: CGFloat) in (90 - degrees) * .pi / 180 }
        context.saveGState()
        context.setLineWidth(ringWidth)
        context.setLineCap(.round)
        context.setStrokeColor(strokeColor)
        context.addArc(center: centre, radius: radius, startAngle: toRadians(start), endAngle: toRadians(end), clockwise: true)
        context.strokePath()
        context.restoreGState()
    }

    // Track, used space, and the green share that cleaning gives back.
    arc(from: 0, to: 359.9, color(0xFFFFFF, 0.10))
    arc(from: 18, to: 230, color(0xFF6B6B))
    arc(from: 262, to: 338, color(0x3DDC97))

    // Four-point sparkle in the centre.
    let sparkle = CGMutablePath()
    let outer: CGFloat = 150
    let inner: CGFloat = 34
    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4 + .pi / 2
        let length = index.isMultiple(of: 2) ? outer : inner
        let point = CGPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length)
        if index == 0 { sparkle.move(to: point) } else { sparkle.addLine(to: point) }
    }
    sparkle.closeSubpath()
    context.setShadow(offset: .zero, blur: 30, color: color(0xFFFFFF, 0.55))
    context.addPath(sparkle)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try png(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
print("Wrote \(output.path)")
