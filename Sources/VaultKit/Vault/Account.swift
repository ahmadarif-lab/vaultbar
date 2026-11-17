import Foundation

/// One logged-in vault. Only non-secret facts live here (it is persisted in
/// UserDefaults); the master password stays in the Keychain, the encrypted vault cache on disk.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var server: ServerChoice
    public var touchID: Bool

    public init(id: String = UUID().uuidString, email: String, server: ServerChoice, touchID: Bool = false) {
        self.id = id
        self.email = email
        self.server = server
        self.touchID = touchID
    }

    /// Id the first (bw-based) builds used for their single account; such accounts have no
    /// native data and are dropped at launch.
    public static let legacyID = "default"

    /// Where this account's cached (encrypted) vault lives.
    public var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultBar", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Key of this account's refresh token in the secret store.
    public var refreshTokenKey: String { "refresh-token.\(id)" }

    /// Keychain / defaults slot for this account's Touch ID item.
    public var biometricSlot: String { "acct-\(id)" }

    /// `bitwarden.com`, `bitwarden.eu` or the self-hosted host.
    public var host: String {
        switch server {
        case .bitwardenUS: return "bitwarden.com"
        case .bitwardenEU: return "bitwarden.eu"
        case .selfHosted(let url): return URL(string: url)?.host ?? url
        }
    }

    public var initials: String { Account.initials(forEmail: email) }

    /// "alice.anderson@example.test" -> "AA"; "alice@x" -> "AL".
    public static func initials(forEmail email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let parts = local.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let letters: String
        if parts.count >= 2 { letters = String(parts[0].prefix(1) + parts[1].prefix(1)) }
        else { letters = String(local.filter(\.isLetter).prefix(2)) }
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
