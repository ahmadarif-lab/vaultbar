import Foundation

public enum ItemType: Int, Codable, Sendable, CaseIterable {
    case login = 1
    case secureNote = 2
    case card = 3
    case identity = 4
}

public struct LoginURI: Codable, Sendable, Hashable {
    public var uri: String?
}

public struct LoginData: Codable, Sendable, Hashable {
    public var username: String?
    public var password: String?
    public var totp: String?
    public var uris: [LoginURI]?
}

public struct CardData: Codable, Sendable, Hashable {
    public var cardholderName: String?
    public var brand: String?
    public var number: String?
    public var expMonth: String?
    public var expYear: String?
    public var code: String?
}

public struct IdentityData: Codable, Sendable, Hashable {
    public var title: String?
    public var firstName: String?
    public var middleName: String?
    public var lastName: String?
    public var address1: String?
    public var address2: String?
    public var address3: String?
    public var city: String?
    public var state: String?
    public var postalCode: String?
    public var country: String?
    public var company: String?
    public var email: String?
    public var phone: String?
    public var ssn: String?
    public var username: String?
    public var passportNumber: String?
    public var licenseNumber: String?
}

public struct CustomField: Codable, Sendable, Hashable {
    public enum Kind: Int, Codable, Sendable { case text = 0, hidden = 1, boolean = 2, linked = 3 }
    public var name: String?
    public var value: String?
    public var type: Kind?
    public init(name: String? = nil, value: String? = nil, type: Kind? = .text) {
        self.name = name; self.value = value; self.type = type
    }
}

/// Bitwarden keeps `login.totp` only for Premium accounts (free accounts can't store it), so VaultBar
/// falls back to an ordinary encrypted hidden custom field, which no plan restricts.
public enum TOTPStorage {
    public static let fieldName = "VaultBar 2FA"
    static func isKeyField(_ f: CustomField) -> Bool { f.name?.caseInsensitiveCompare(fieldName) == .orderedSame }
}

/// One vault item as decrypted from the server's `/sync` payload.
/// Decoding is lenient: every field the server may omit is optional.
public struct VaultItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var organizationId: String?
    public var folderId: String?
    public var type: ItemType
    public var name: String
    public var notes: String?
    public var favorite: Bool?
    public var login: LoginData?
    public var card: CardData?
    public var identity: IdentityData?
    public var fields: [CustomField]?

    /// The authenticator key, wherever it is stored: `login.totp`, else the VaultBar custom field.
    public var authenticatorKey: String? {
        if let t = login?.totp?.nonEmpty { return t }
        return fields?.first(where: TOTPStorage.isKeyField)?.value?.nonEmpty
    }

    public init(id: String, organizationId: String? = nil, folderId: String? = nil, type: ItemType, name: String,
                notes: String? = nil, favorite: Bool? = nil, login: LoginData? = nil, card: CardData? = nil,
                identity: IdentityData? = nil, fields: [CustomField]? = nil) {
        self.id = id
        self.organizationId = organizationId
        self.folderId = folderId
        self.type = type
        self.name = name
        self.notes = notes
        self.favorite = favorite
        self.login = login
        self.card = card
        self.identity = identity
        self.fields = fields
    }
}

public struct VaultFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: String?
    public var name: String
    public init(id: String?, name: String) { self.id = id; self.name = name }
}

public struct VaultOrganization: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct VaultSnapshot: Sendable {
    public var items: [VaultItem]
    public var folders: [VaultFolder]
    public var organizations: [VaultOrganization]
    public init(items: [VaultItem] = [], folders: [VaultFolder] = [], organizations: [VaultOrganization] = []) {
        self.items = items
        self.folders = folders
        self.organizations = organizations
    }
}

/// A vault item with everything the UI derives from it resolved once at load
/// time (parsed TOTP, folder/org names, normalised search text) so a 1 s tick
/// only has to compute codes, never re-parse.
public struct VaultEntry: Identifiable, Sendable {
    public let item: VaultItem
    public let totp: TOTP?
    public let folderName: String?
    public let organizationName: String?
    public let uris: [String]
    let searchName: String
    let searchUser: String
    let searchURIs: String
    let searchFolder: String

    public var id: String { item.id }
    public var name: String { item.name }
    public var username: String? { item.login?.username?.nonEmpty }
    public var password: String? { item.login?.password?.nonEmpty }
    public var isFavorite: Bool { item.favorite ?? false }
    public var type: ItemType { item.type }

    public init(item: VaultItem, folders: [String: String], organizations: [String: String]) {
        self.item = item
        if let raw = item.authenticatorKey { self.totp = TOTP(parsing: raw) } else { self.totp = nil }
        self.folderName = item.folderId.flatMap { folders[$0] }
        self.organizationName = item.organizationId.flatMap { organizations[$0] }
        self.uris = (item.login?.uris ?? []).compactMap { $0.uri?.nonEmpty }
        self.searchName = Self.fold(item.name)
        let user = item.login?.username ?? item.identity?.username ?? item.identity?.email ?? item.card?.cardholderName ?? ""
        self.searchUser = Self.fold(user)
        self.searchURIs = Self.fold(uris.joined(separator: " "))
        self.searchFolder = Self.fold([folderName, organizationName].compactMap { $0 }.joined(separator: " "))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The secondary line shown under the name.
    public var subtitle: String? {
        switch item.type {
        case .login: return username
        case .card:
            let brand = item.card?.brand?.nonEmpty
            let last4 = item.card?.number?.nonEmpty.map { "•••• " + $0.suffix(4) }
            return [brand, last4].compactMap { $0 }.joined(separator: " ").nonEmpty
        case .identity:
            let n = [item.identity?.firstName, item.identity?.lastName].compactMap { $0?.nonEmpty }.joined(separator: " ")
            return n.nonEmpty
        case .secureNote: return nil
        }
    }

    /// Weighted fuzzy score, nil when some query token matches nothing.
    public func score(for query: String) -> Int? {
        Fuzzy.score(query: query, fields: [
            (searchName, 3), (searchUser, 2), (searchURIs, 2), (searchFolder, 1),
        ])
    }

    public static func build(from snapshot: VaultSnapshot) -> [VaultEntry] {
        var folders: [String: String] = [:]
        for f in snapshot.folders { if let id = f.id { folders[id] = f.name } }
        let orgs = Dictionary(uniqueKeysWithValues: snapshot.organizations.map { ($0.id, $0.name) })
        return snapshot.items
            .map { VaultEntry(item: $0, folders: folders, organizations: orgs) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
