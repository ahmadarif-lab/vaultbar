import AppKit

/// The menu bar glyph: a padlock with a keyhole. Drawn in code so it stays a
/// crisp template image at any scale, and so the project carries no icon asset.
enum MenuBarIcon {
    static func image(locked: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Shackle
            let shackle = NSBezierPath()
            shackle.lineWidth = 1.8
            shackle.lineCapStyle = .round
            if locked {
                shackle.move(to: NSPoint(x: 5.6, y: 8.2))
                shackle.line(to: NSPoint(x: 5.6, y: 10.6))
                shackle.appendArc(withCenter: NSPoint(x: 9, y: 10.6), radius: 3.4, startAngle: 180, endAngle: 0, clockwise: true)
                shackle.line(to: NSPoint(x: 12.4, y: 8.2))
            } else {
                shackle.move(to: NSPoint(x: 5.6, y: 8.2))
                shackle.line(to: NSPoint(x: 5.6, y: 10.6))
                shackle.appendArc(withCenter: NSPoint(x: 9, y: 10.6), radius: 3.4, startAngle: 180, endAngle: 20, clockwise: true)
            }
            shackle.stroke()

            // Body with a keyhole cut out (even-odd).
            let body = NSBezierPath(roundedRect: NSRect(x: 3, y: 2, width: 12, height: 8), xRadius: 2.4, yRadius: 2.4)
            body.append(NSBezierPath(ovalIn: NSRect(x: 7.8, y: 5.2, width: 2.4, height: 2.4)))
            body.append(NSBezierPath(roundedRect: NSRect(x: 8.4, y: 3.5, width: 1.2, height: 2.4), xRadius: 0.5, yRadius: 0.5))
            body.windingRule = .evenOdd
            body.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
