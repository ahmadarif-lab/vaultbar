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
    /// Logged-in accounts (non-secret facts only) and which one is active.
    var accounts: [Account] { didSet { defaults.set(try? JSONEncoder().encode(accounts), forKey: "accounts") } }
    var activeAccountID: String? { didSet { defaults.set(activeAccountID, forKey: "activeAccountID") } }

    var activeAccount: Account? { accounts.first { $0.id == activeAccountID } }
    var server: ServerChoice? { activeAccount?.server }
    var accountEmail: String? { activeAccount?.email }
    /// Touch ID is opt-in per account.
    var touchIDEnabled: Bool {
        get { activeAccount?.touchID ?? false }
        set {
            guard let i = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
            accounts[i].touchID = newValue
        }
    }
    /// Minutes; 0 means never.
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    /// Seconds; 0 means never clear.
    var clipboardSeconds: Int { didSet { defaults.set(clipboardSeconds, forKey: "clipboardSeconds") } }
    var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled"); onHotkeyChanged?() } }
    var hotkeyKeyCode: UInt32 { didSet { defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode"); onHotkeyChanged?() } }
    var hotkeyModifiers: UInt32 { didSet { defaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers"); onHotkeyChanged?() } }
    @ObservationIgnored var onHotkeyChanged: (() -> Void)?
    /// Lock the vault the moment the popover closes. Off by default.
    var lockOnClose: Bool { didSet { defaults.set(lockOnClose, forKey: "lockOnClose") } }
    /// Close the popover right after a copy (so ⌘V lands in the previous app). Off by default.
    var closeAfterCopy: Bool { didSet { defaults.set(closeAfterCopy, forKey: "closeAfterCopy") } }
    var showFavicons: Bool { didSet { defaults.set(showFavicons, forKey: "showFavicons") } }
    var hideOrgItems: Bool { didSet { defaults.set(hideOrgItems, forKey: "hideOrgItems") } }

    static let defaultHotkeyKeyCode: UInt32 = 9            // V
    static let defaultHotkeyModifiers: UInt32 = 256 | 2048 | 4096 // ⌘ ⌥ ⌃ (Carbon masks)

    private init() {
        let d = UserDefaults.standard
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .en
        var list = d.data(forKey: "accounts").flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        var active = d.string(forKey: "activeAccountID")
        // First builds had a single account (server + email keys): carry it over (it is dropped at launch: it has no native key record).
        if list.isEmpty, let email = d.string(forKey: "accountEmail"),
           let server = d.data(forKey: "server").flatMap({ try? JSONDecoder().decode(ServerChoice.self, from: $0) }) {
            list = [Account(id: Account.legacyID, email: email, server: server, touchID: false)]
            active = Account.legacyID
        }
        if active == nil || !list.contains(where: { $0.id == active }) { active = list.first?.id }
        accounts = list
        activeAccountID = active
        autoLockMinutes = d.object(forKey: "autoLockMinutes") as? Int ?? 15
        clipboardSeconds = d.object(forKey: "clipboardSeconds") as? Int ?? 30
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        hotkeyKeyCode = UInt32(d.object(forKey: "hotkeyKeyCode") as? Int ?? Int(Self.defaultHotkeyKeyCode))
        hotkeyModifiers = UInt32(d.object(forKey: "hotkeyModifiers") as? Int ?? Int(Self.defaultHotkeyModifiers))
        closeAfterCopy = d.bool(forKey: "closeAfterCopy")
        lockOnClose = d.bool(forKey: "lockOnClose")
        showFavicons = d.bool(forKey: "showFavicons")
        hideOrgItems = d.bool(forKey: "hideOrgItems")
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
