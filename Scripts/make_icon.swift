// Renders Resources/AppIcon.png (1024x1024): a shield with a keyhole on an
// indigo gradient, with a menu bar strip along the top edge. Run: swift Scripts/make_icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: 824pt rounded square centred in the 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.40, green: 0.46, blue: 1.0, alpha: 1),
                                       NSColor(srgbRed: 0.24, green: 0.20, blue: 0.80, alpha: 1)])!
    gradient.draw(in: path, angle: -60)

    // Menu bar strip along the top edge of the tile: the app lives in the menu bar.
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSColor.black.withAlphaComponent(0.30).setFill()
    NSRect(x: 100, y: 804, width: 824, height: 120).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    for x in [650.0, 712.0] { NSBezierPath(ovalIn: NSRect(x: x - 13, y: 851, width: 26, height: 26)).fill() }
    NSColor.white.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: 748, y: 835, width: 84, height: 58), xRadius: 18, yRadius: 18).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 776, y: 848, width: 28, height: 32), xRadius: 9, yRadius: 9).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Shield with a keyhole cut out.
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 322, y: 690))
    shield.curve(to: NSPoint(x: 702, y: 690), controlPoint1: NSPoint(x: 420, y: 742), controlPoint2: NSPoint(x: 604, y: 742))
    shield.line(to: NSPoint(x: 702, y: 500))
    shield.curve(to: NSPoint(x: 512, y: 218), controlPoint1: NSPoint(x: 702, y: 360), controlPoint2: NSPoint(x: 600, y: 270))
    shield.curve(to: NSPoint(x: 322, y: 500), controlPoint1: NSPoint(x: 424, y: 270), controlPoint2: NSPoint(x: 322, y: 360))
    shield.close()
    // Keyhole as one contour (a circle plus a neck), so the even-odd fill has no sliver where they meet.
    let keyhole = NSBezierPath()
    keyhole.move(to: NSPoint(x: 486, y: 400))
    keyhole.line(to: NSPoint(x: 486, y: 494.7))
    keyhole.appendArc(withCenter: NSPoint(x: 512, y: 542), radius: 54, startAngle: 241.2, endAngle: 298.8, clockwise: true)
    keyhole.line(to: NSPoint(x: 538, y: 400))
    keyhole.close()
    shield.append(keyhole)
    shield.windingRule = .evenOdd
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glow.shadowOffset = NSSize(width: 0, height: -10)
    glow.shadowBlurRadius = 18
    glow.set()
    NSColor.white.setFill()
    shield.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.png")
try png.write(to: out)
print("Wrote \(out.path)")
