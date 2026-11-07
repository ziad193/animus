// Makes Resources/AppIconDev.icns: the app icon with a red "DEV" ribbon,
// so Animus Dev is easy to tell apart in the Dock.
//   swift scripts/make-dev-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let icon = NSImage(contentsOf: root.appendingPathComponent("AppIcon.icns")) else { fatalError("no AppIcon.icns") }
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIconDev.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    icon.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    // A red ribbon across the bottom of the icon's rounded square.
    let ribbon = NSRect(x: s * 0.1, y: s * 0.12, width: s * 0.8, height: s * 0.24)
    NSColor(calibratedRed: 0.86, green: 0.12, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: ribbon, xRadius: s * 0.05, yRadius: s * 0.05).fill()
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.16, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: s * 0.01,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: ribbon.midX - size.width / 2, y: ribbon.midY - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIconDev.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", out.path]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
