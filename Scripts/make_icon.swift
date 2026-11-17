// Renders Resources/AppIcon.png (1024x1024): a padlock with a keyhole on an
// indigo gradient. Run: swift Scripts/make_icon.swift
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

    // Padlock
    NSColor.white.setFill()
    NSColor.white.setStroke()
    let shackle = NSBezierPath()
    shackle.lineWidth = 64
    shackle.lineCapStyle = .round
    shackle.move(to: NSPoint(x: 372, y: 520))
    shackle.line(to: NSPoint(x: 372, y: 600))
    shackle.appendArc(withCenter: NSPoint(x: 512, y: 600), radius: 140, startAngle: 180, endAngle: 0, clockwise: true)
    shackle.line(to: NSPoint(x: 652, y: 520))
    shackle.stroke()

    let body = NSBezierPath(roundedRect: NSRect(x: 292, y: 300, width: 440, height: 300), xRadius: 70, yRadius: 70)
    body.append(NSBezierPath(ovalIn: NSRect(x: 462, y: 440, width: 100, height: 100)))
    body.append(NSBezierPath(roundedRect: NSRect(x: 486, y: 372, width: 52, height: 100), xRadius: 20, yRadius: 20))
    body.windingRule = .evenOdd
    body.fill()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.png")
try png.write(to: out)
print("Wrote \(out.path)")
