import Foundation

/// What the editor works on. Saving merges it into the item's original JSON
/// (`bw` returns fields this app does not model: password history,
/// attachments, passkeys, reprompt…), so editing never silently drops them.
public struct ItemDraft: Sendable, Equatable, Identifiable {
    public var id: String?
    public var type: ItemType
    public var name = ""
    public var folderId: String?
    public var favorite = false
    public var notes = ""
    public var username = ""
    public var password = ""
    public var totp = ""
    public var uris: [String] = [""]
    public var card = CardData()
    public var identity = IdentityData()
    public var fields: [CustomField] = []

    /// Organization items keep their organization and collections on edit; cloning one is not supported.
    public var organizationId: String?

    public init(type: ItemType = .login, folderId: String? = nil) {
        self.type = type
        self.folderId = folderId
    }

    public init(item: VaultItem) {
        id = item.id
        type = item.type
        name = item.name
        folderId = item.folderId
        favorite = item.favorite ?? false
        notes = item.notes ?? ""
        organizationId = item.organizationId
        username = item.login?.username ?? ""
        password = item.login?.password ?? ""
        totp = item.login?.totp ?? ""
        let u = (item.login?.uris ?? []).compactMap { $0.uri }
        uris = u.isEmpty ? [""] : u
        card = item.card ?? CardData()
        identity = item.identity ?? IdentityData()
        fields = (item.fields ?? []).filter { $0.type != .linked }
    }

    public var isNew: Bool { id == nil }

    public enum Problem: Error, Equatable { case nameRequired, invalidTOTP }

    /// nil when the draft can be saved.
    public var problem: Problem? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return .nameRequired }
        if type == .login, !totp.trimmingCharacters(in: .whitespaces).isEmpty, TOTP(parsing: totp) == nil { return .invalidTOTP }
        return nil
    }

    // MARK: JSON

    private static func nullable(_ s: String?) -> Any {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return NSNull() }
        return s
    }

    private static func merged(_ base: Any?, _ values: [String: Any]) -> [String: Any] {
        var out = (base as? [String: Any]) ?? [:]
        for (k, v) in values { out[k] = v }
        return out
    }

    /// The item JSON to send: `original` (when editing) with this draft laid over it.
    public func json(merging original: [String: Any]? = nil) -> [String: Any] {
        var out = original ?? [:]
        out["type"] = type.rawValue
        out["name"] = name.trimmingCharacters(in: .whitespaces)
        out["notes"] = Self.nullable(notes)
        out["favorite"] = favorite
        out["folderId"] = folderId ?? NSNull()
        if original == nil {
            out["organizationId"] = organizationId ?? NSNull()
            out["reprompt"] = 0
        }

        switch type {
        case .login:
            let oldURIs = ((original?["login"] as? [String: Any])?["uris"] as? [[String: Any]]) ?? []
            var uriList: [[String: Any]] = []
            for (i, raw) in uris.enumerated() {
                let uri = raw.trimmingCharacters(in: .whitespaces)
                guard !uri.isEmpty else { continue }
                var entry = i < oldURIs.count ? oldURIs[i] : ["match": NSNull()]
                entry["uri"] = uri
                uriList.append(entry)
            }
            out["login"] = Self.merged(original?["login"], [
                "username": Self.nullable(username),
                "password": Self.nullable(password),
                "totp": Self.nullable(totp.trimmingCharacters(in: .whitespaces)),
                "uris": uriList,
            ])
        case .secureNote:
            out["secureNote"] = Self.merged(original?["secureNote"], ["type": 0])
        case .card:
            out["card"] = Self.merged(original?["card"], [
                "cardholderName": Self.nullable(card.cardholderName), "brand": Self.nullable(card.brand),
                "number": Self.nullable(card.number), "expMonth": Self.nullable(card.expMonth),
                "expYear": Self.nullable(card.expYear), "code": Self.nullable(card.code),
            ])
        case .identity:
            let i = identity
            out["identity"] = Self.merged(original?["identity"], [
                "title": Self.nullable(i.title), "firstName": Self.nullable(i.firstName),
                "middleName": Self.nullable(i.middleName), "lastName": Self.nullable(i.lastName),
                "address1": Self.nullable(i.address1), "address2": Self.nullable(i.address2),
                "address3": Self.nullable(i.address3), "city": Self.nullable(i.city),
                "state": Self.nullable(i.state), "postalCode": Self.nullable(i.postalCode),
                "country": Self.nullable(i.country), "company": Self.nullable(i.company),
                "email": Self.nullable(i.email), "phone": Self.nullable(i.phone), "ssn": Self.nullable(i.ssn),
                "username": Self.nullable(i.username), "passportNumber": Self.nullable(i.passportNumber),
                "licenseNumber": Self.nullable(i.licenseNumber),
            ])
        }

        // Linked custom fields are not editable here; keep them as they were.
        let linked = ((original?["fields"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? Int) == 3 }
        let editable: [[String: Any]] = fields.compactMap { f in
            guard let name = f.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return ["name": name, "value": f.value ?? "", "type": (f.type ?? .text).rawValue, "linkedId": NSNull()]
        }
        out["fields"] = editable + linked
        return out
    }

    /// JSON for a copy of `original` ("clone"): a new item, no history or attachments.
    public static func cloneJSON(from original: [String: Any], nameSuffix: String) -> [String: Any] {
        var out = original
        for key in ["id", "revisionDate", "creationDate", "deletedDate", "attachments", "passwordHistory", "collectionIds", "object", "edit", "viewPassword"] {
            out.removeValue(forKey: key)
        }
        if var login = out["login"] as? [String: Any] {
            login.removeValue(forKey: "fido2Credentials") // a passkey must not exist twice
            login.removeValue(forKey: "passwordRevisionDate")
            out["login"] = login
        }
        let name = (out["name"] as? String) ?? ""
        out["name"] = name + nameSuffix
        return out
    }
}
