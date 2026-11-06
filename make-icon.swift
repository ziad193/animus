// Draws the placeholder app icon (a stack of cards with a "repeat" arrow)
// and writes AppIcon.icns. Run: swift make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let s = size / 1024
        // Background: macOS-style rounded square with an indigo → teal gradient.
        let inset = 100 * s
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: 185 * s, yRadius: 185 * s)
        NSGradient(colors: [NSColor(red: 0.25, green: 0.22, blue: 0.78, alpha: 1),
                            NSColor(red: 0.10, green: 0.62, blue: 0.75, alpha: 1)])!
            .draw(in: bg, angle: -60)

        func card(_ angle: CGFloat, _ dx: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: 512 * s + dx * s, yBy: 512 * s + dy * s)
            t.rotate(byDegrees: angle)
            t.concat()
            let r = NSRect(x: -230 * s, y: -160 * s, width: 460 * s, height: 320 * s)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 24 * s
            shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
            shadow.set()
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: r, xRadius: 36 * s, yRadius: 36 * s).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        card(-12, -30, -40, 0.55)
        card(-4, -10, -15, 0.8)
        card(4, 10, 10, 1)

        // Two arrows chasing each other in a loop: "again".
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 522 * s, yBy: 522 * s)
        t.rotate(byDegrees: 4)
        t.concat()
        let colour = NSColor(red: 0.22, green: 0.30, blue: 0.80, alpha: 1)
        colour.setStroke()
        colour.setFill()
        let radius = 88 * s
        for (start, end) in [(CGFloat(25), CGFloat(155)), (CGFloat(205), CGFloat(335))] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: .zero, radius: radius, startAngle: start, endAngle: end)
            arc.lineWidth = 26 * s
            arc.lineCapStyle = .round
            arc.stroke()
            // Arrowhead pointing along the circle at the arc's end.
            let a = end * .pi / 180
            let tip = CGPoint(x: radius * cos(a), y: radius * sin(a))
            let along = CGPoint(x: -sin(a), y: cos(a))      // direction of travel
            let out = CGPoint(x: cos(a), y: sin(a))          // away from the centre
            let size = 40 * s
            let head = NSBezierPath()
            head.move(to: CGPoint(x: tip.x + along.x * size, y: tip.y + along.y * size))
            head.line(to: CGPoint(x: tip.x + out.x * size * 0.9, y: tip.y + out.y * size * 0.9))
            head.line(to: CGPoint(x: tip.x - out.x * size * 0.9, y: tip.y - out.y * size * 0.9))
            head.close()
            head.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}

let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let image = draw(size: px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print("wrote AppIcon.iconset")
