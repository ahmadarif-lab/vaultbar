import AppKit
import SwiftUI

enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = dynamic(light: 0xF3F6F9, dark: 0x0F1624)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x172033)
    static let hover = dynamic(light: 0xE8EDF3, dark: 0x1F2A40)
    static let stroke = dynamic(light: 0xD6DDE7, dark: 0x2A3650)
    static let textPrimary = dynamic(light: 0x1B2330, dark: 0xF3F6F9)
    static let textSecondary = dynamic(light: 0x66738A, dark: 0x97A3B8)
    static let accent = dynamic(light: 0x175DDC, dark: 0x6F9EFF)
    static let accentSoft = dynamic(light: 0xE3ECFD, dark: 0x1B2B4D)
    /// Text on a filled accent button (dark text on the light-blue dark-mode button, like the extension).
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B1220)
    static let warning = dynamic(light: 0xD9480F, dark: 0xFF8A4C)
    static let danger = dynamic(light: 0xD1242F, dark: 0xFF7B84)
    static let digit = dynamic(light: 0x175DDC, dark: 0x7FB0FF)
    static let symbol = dynamic(light: 0xC2301F, dark: 0xFF8D82)

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
        .buttonStyle(.plain).handCursor()
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
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

/// Themed text input used on the lock screen and in the setup/settings screens.
/// Secure fields get a show/hide eye.
struct ThemedField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Group {
                if secure && !revealed {
                    SecureField(placeholder, text: $text).onSubmit(onSubmit)
                } else {
                    TextField(placeholder, text: $text).onSubmit(onSubmit)
                }
            }
            .focused($focused)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            if secure {
                Button {
                    revealed.toggle()
                    // Swapping SecureField/TextField drops the focus; take it back.
                    Task { @MainActor in focused = true }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
                .help(revealed ? t("detail.hide") : t("detail.reveal"))
            }
        }
        .padding(.leading, 10).padding(.trailing, secure ? 4 : 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 1.5 : 1))
    }
}


/// Pointing-hand cursor while the mouse is over a clickable control.
private struct HandCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && !inside { NSCursor.pointingHand.push(); inside = true }
                else if !hovering && inside { NSCursor.pop(); inside = false }
            }
            .onDisappear { if inside { NSCursor.pop(); inside = false } }
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursor()) }
}
