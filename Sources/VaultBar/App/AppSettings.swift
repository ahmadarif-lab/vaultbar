import Foundation
import Observation
import VaultKit

/// Non-secret preferences, persisted in UserDefaults. Nothing sensitive lives
/// here: no passwords, session keys or vault data.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }
    var server: ServerChoice? { didSet { defaults.set(server.flatMap { try? JSONEncoder().encode($0) }, forKey: "server") } }
    var accountEmail: String? { didSet { defaults.set(accountEmail, forKey: "accountEmail") } }
    var touchIDEnabled: Bool { didSet { defaults.set(touchIDEnabled, forKey: "touchIDEnabled") } }
    /// Minutes; 0 means never.
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    /// Seconds; 0 means never clear.
    var clipboardSeconds: Int { didSet { defaults.set(clipboardSeconds, forKey: "clipboardSeconds") } }
    var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled"); onHotkeyChanged?() } }
    var hotkeyKeyCode: UInt32 { didSet { defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode"); onHotkeyChanged?() } }
    var hotkeyModifiers: UInt32 { didSet { defaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers"); onHotkeyChanged?() } }
    @ObservationIgnored var onHotkeyChanged: (() -> Void)?
    var showFavicons: Bool { didSet { defaults.set(showFavicons, forKey: "showFavicons") } }
    var hideOrgItems: Bool { didSet { defaults.set(hideOrgItems, forKey: "hideOrgItems") } }

    static let defaultHotkeyKeyCode: UInt32 = 9            // V
    static let defaultHotkeyModifiers: UInt32 = 256 | 2048 | 4096 // ⌘ ⌥ ⌃ (Carbon masks)

    private init() {
        let d = UserDefaults.standard
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .en
        server = d.data(forKey: "server").flatMap { try? JSONDecoder().decode(ServerChoice.self, from: $0) }
        accountEmail = d.string(forKey: "accountEmail")
        touchIDEnabled = d.bool(forKey: "touchIDEnabled")
        autoLockMinutes = d.object(forKey: "autoLockMinutes") as? Int ?? 15
        clipboardSeconds = d.object(forKey: "clipboardSeconds") as? Int ?? 30
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        hotkeyKeyCode = UInt32(d.object(forKey: "hotkeyKeyCode") as? Int ?? Int(Self.defaultHotkeyKeyCode))
        hotkeyModifiers = UInt32(d.object(forKey: "hotkeyModifiers") as? Int ?? Int(Self.defaultHotkeyModifiers))
        showFavicons = d.bool(forKey: "showFavicons")
        hideOrgItems = d.bool(forKey: "hideOrgItems")
    }

    func clearAccount() {
        server = nil
        accountEmail = nil
        touchIDEnabled = false
    }
}

/// Localised string lookup. Reads `AppSettings.language`, so SwiftUI views that
/// call it re-render when the language changes.
@MainActor
func t(_ key: String) -> String {
    Strings.text(key, AppSettings.shared.language)
}

@MainActor
func t(_ key: String, _ args: CVarArg...) -> String {
    String(format: Strings.text(key, AppSettings.shared.language), arguments: args)
}
