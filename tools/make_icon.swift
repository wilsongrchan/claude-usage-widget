// Renders Resources/AppIcon.icns: a 5-slice ring in Claude orange on a white squircle.
// Run: swift tools/make_icon.swift
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle body on Apple's 1024 grid (824pt body, 100pt margin).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSColor.white.setFill()
squircle.fill()

// Five evenly spaced slices, all in Claude orange.
let c = NSPoint(x: 512, y: 512), r: CGFloat = 245, w: CGFloat = 86, gap: CGFloat = 3
for k in 0..<5 {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90 - CGFloat(k) * 72 - gap,
                  endAngle: 90 - CGFloat(k + 1) * 72 + gap, clockwise: true)
    arc.lineWidth = w
    arc.lineCapStyle = .butt
    color(0xD97757).setStroke()
    arc.stroke()
}

NSGraphicsContext.current = nil
let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let master = "build/icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: master))
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                   (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", master, "--out", "\(iconset)/icon_\(name).png"]
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
