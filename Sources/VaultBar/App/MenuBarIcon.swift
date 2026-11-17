import AppKit

/// The menu bar glyph: the app icon's shield with a keyhole. Locked is a solid shield with the keyhole
/// cut out; unlocked is an outlined shield with a solid keyhole. Template images, so macOS tints them.
enum MenuBarIcon {
    static func image(locked: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 3.2, y: 13.4))
            shield.curve(to: NSPoint(x: 14.8, y: 13.4), controlPoint1: NSPoint(x: 6.2, y: 15.4), controlPoint2: NSPoint(x: 11.8, y: 15.4))
            shield.line(to: NSPoint(x: 14.8, y: 8.6))
            shield.curve(to: NSPoint(x: 9, y: 1.4), controlPoint1: NSPoint(x: 14.8, y: 4.9), controlPoint2: NSPoint(x: 11.6, y: 2.6))
            shield.curve(to: NSPoint(x: 3.2, y: 8.6), controlPoint1: NSPoint(x: 6.4, y: 2.6), controlPoint2: NSPoint(x: 3.2, y: 4.9))
            shield.close()

            // Keyhole: a circle with a neck, as one contour.
            let keyhole = NSBezierPath()
            keyhole.move(to: NSPoint(x: 8.15, y: 5.2))
            keyhole.line(to: NSPoint(x: 8.15, y: 7.67))
            keyhole.appendArc(withCenter: NSPoint(x: 9, y: 9.2), radius: 1.75, startAngle: 240.9, endAngle: 299.1, clockwise: true)
            keyhole.line(to: NSPoint(x: 9.85, y: 5.2))
            keyhole.close()

            if locked {
                shield.append(keyhole)
                shield.windingRule = .evenOdd
                shield.fill()
            } else {
                shield.lineWidth = 1.4
                shield.lineJoinStyle = .round
                shield.stroke()
                keyhole.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
