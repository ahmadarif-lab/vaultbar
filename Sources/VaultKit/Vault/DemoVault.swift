import Foundation

/// Fake vault for `--demo`: screenshots and development without a real account.
/// Every value here is invented; the TOTP secrets are throwaway test strings.
public final class DemoSession: VaultSession, @unchecked Sendable {
    public init() {}

    public func unlock(password: String) async throws {
        // Any non-empty password unlocks the demo; the lock screen is still real UI.
        if password.isEmpty { throw VaultError.invalidPassword }
    }
    public func lock() async {}
    public func sync() async throws { try await Task.sleep(nanoseconds: 400_000_000) }
    public func snapshot() async throws -> VaultSnapshot { Self.snapshot }

    private static func login(_ id: String, _ name: String, user: String?, pass: String = "demo-password-1", totp: String? = nil,
                              uri: String? = nil, folder: String? = nil, fav: Bool = false, org: String? = nil,
                              notes: String? = nil, fields: [CustomField]? = nil) -> VaultItem {
        VaultItem(id: id, organizationId: org, folderId: folder, type: .login, name: name, notes: notes, favorite: fav,
                  login: LoginData(username: user, password: pass, totp: totp, uris: uri.map { [LoginURI(uri: $0)] }),
                  fields: fields)
    }

    public static let snapshot = VaultSnapshot(
        items: [
            login("d01", "GitHub", user: "demo@example.com", totp: "JBSWY3DPEHPK3PXP", uri: "https://github.com/login", folder: "fDev", fav: true),
            login("d02", "Google", user: "demo.user@example.com", totp: "otpauth://totp/Google:demo.user@example.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=Google", uri: "https://accounts.google.com", fav: true),
            login("d03", "Cloudflare", user: "ops@example.com", totp: "NB2W45DFOIZA====", uri: "https://dash.cloudflare.com", folder: "fDev"),
            login("d04", "AWS Console", user: "admin-demo", totp: "otpauth://totp/AWS?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Amazon&digits=6&period=30", uri: "https://signin.aws.amazon.com", folder: "fWork", org: "oAcme"),
            login("d05", "Steam", user: "demo_gamer", totp: "steam://JBSWY3DPEHPK3PXP", uri: "https://store.steampowered.com", folder: "fPersonal"),
            login("d06", "GitLab (self-hosted)", user: "demo", totp: "KRSXG5CTMVRXEZLU", uri: "https://git.example.test", folder: "fWork", org: "oAcme"),
            login("d07", "Netflix", user: "family@example.com", uri: "https://www.netflix.com/login", folder: "fPersonal"),
            login("d08", "Spotify", user: "demo.listener", uri: "https://accounts.spotify.com", folder: "fPersonal"),
            login("d09", "Home router", user: "admin", uri: "http://192.168.1.1", folder: "fPersonal",
                  notes: "Admin panel. Firmware updated in March.",
                  fields: [CustomField(name: "Wi-Fi PIN", value: "12345670", type: .hidden), CustomField(name: "Location", value: "Hallway", type: .text)]),
            login("d10", "Company VPN", user: "demo.user", totp: "MFRGGZDFMZTWQ2LK", uri: "https://vpn.example.test", folder: "fWork", org: "oAcme"),
            login("d11", "Dropbox", user: "demo@example.com", totp: "ORSXG5BAON2HE2LOM4======", uri: "https://www.dropbox.com/login"),
            login("d12", "Stack Overflow", user: "demo-dev", uri: "https://stackoverflow.com/users/login", folder: "fDev"),
            VaultItem(id: "d13", folderId: "fPersonal", type: .card, name: "Travel Visa", favorite: false,
                      card: CardData(cardholderName: "Demo User", brand: "Visa", number: "4111111111111111", expMonth: "08", expYear: "2029", code: "123")),
            VaultItem(id: "d14", folderId: "fPersonal", type: .identity, name: "Passport (demo)",
                      identity: IdentityData(firstName: "Demo", lastName: "User", country: "Indonesia", passportNumber: "X0000000")),
            VaultItem(id: "d15", folderId: "fWork", type: .secureNote, name: "Server setup checklist",
                      notes: "1. Create the VM\n2. Harden SSH\n3. Enable backups", favorite: true),
        ],
        folders: [
            VaultFolder(id: "fDev", name: "Dev"), VaultFolder(id: "fWork", name: "Work"), VaultFolder(id: "fPersonal", name: "Personal"),
        ],
        organizations: [VaultOrganization(id: "oAcme", name: "Acme Inc")]
    )
}
