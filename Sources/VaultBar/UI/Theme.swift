import AppKit
import SwiftUI

enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = dynamic(light: 0xF5F6F8, dark: 0x1C1D21)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x26272C)
    static let hover = dynamic(light: 0xEBEDF2, dark: 0x2E2F36)
    static let stroke = dynamic(light: 0xDFE2E9, dark: 0x383A42)
    static let textPrimary = dynamic(light: 0x15171C, dark: 0xF2F3F5)
    static let textSecondary = dynamic(light: 0x6B7280, dark: 0x9BA0AB)
    static let accent = dynamic(light: 0x4453E8, dark: 0x8390FF)
    static let accentSoft = dynamic(light: 0xE6E8FD, dark: 0x2B2F59)
    static let warning = dynamic(light: 0xD9480F, dark: 0xFF8A4C)
    static let danger = dynamic(light: 0xD1242F, dark: 0xFF6B73)

    static let avatarHues: [UInt32] = [0x5B6CFF, 0x2F9E8F, 0xE0712C, 0xB65BD6, 0x2D8FD6, 0xD6527A, 0x6F9A2F, 0x8A6FE8]

    static func avatarColor(for name: String) -> Color {
        var hash: UInt32 = 5381
        for u in name.lowercased().unicodeScalars { hash = hash &* 33 &+ u.value }
        return Color(nsColor: NSColor(hex: avatarHues[Int(hash % UInt32(avatarHues.count))]))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Plain text button with a hover tint, used instead of the stock bordered style.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 13
    var tint: Color = Theme.textSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? Theme.hover : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
    }
}

/// Themed text input used on the lock screen and in the setup/settings windows.
struct ThemedField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text).onSubmit(onSubmit)
            } else {
                TextField(placeholder, text: $text).onSubmit(onSubmit)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
    }
}
