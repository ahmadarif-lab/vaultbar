import Foundation

/// What the editor works on. Saving merges it into the item's original JSON
/// (the server returns fields this app does not model: password history,
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
        totp = item.authenticatorKey ?? ""
        let u = (item.login?.uris ?? []).compactMap { $0.uri }
        uris = u.isEmpty ? [""] : u
        card = item.card ?? CardData()
        identity = item.identity ?? IdentityData()
        fields = (item.fields ?? []).filter { $0.type != .linked && !TOTPStorage.isKeyField($0) } // the key has its own input
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

    private static func merged(_ base: Any?, _ values: [String: Any]) -> [String: Any] {
        var out = (base as? [String: Any]) ?? [:]
        for (k, v) in values { out[k] = v }
        return out
    }

    /// The item JSON to send: `original` (when editing) with this draft laid over it.
    /// `transform` is applied to every user-text string (name, notes, username, password,
    /// URIs, card/identity values, custom fields). Identity for plaintext (demo, tests);
    /// the native client passes an encrypter, since Bitwarden stores each field as an EncString.
    public func json(merging original: [String: Any]? = nil) -> [String: Any] {
        // The identity transform cannot throw.
        // swiftlint:disable:next force_try
        try! json(merging: original, totpInField: false, transform: { $0 })
    }

    /// `totpInField`: store the authenticator key in the "VaultBar 2FA" hidden field instead of `login.totp`
    /// (free Bitwarden accounts can't keep `login.totp`).
    public func json(merging original: [String: Any]?, totpInField: Bool = false, transform: (String) throws -> String) throws -> [String: Any] {
        func text(_ s: String?) throws -> Any {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return NSNull() }
            return try transform(s)
        }
        var out = original ?? [:]
        out["type"] = type.rawValue
        out["name"] = try transform(name.trimmingCharacters(in: .whitespaces))
        out["notes"] = try text(notes)
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
                entry["uri"] = try transform(uri)
                if entry["uriChecksum"] != nil { entry["uriChecksum"] = NSNull() } // stale once the URI changes
                uriList.append(entry)
            }
            out["login"] = Self.merged(original?["login"], [
                "username": try text(username),
                "password": try text(password),
                "totp": totpInField ? NSNull() : try text(totp.trimmingCharacters(in: .whitespaces)),
                "uris": uriList,
            ])
        case .secureNote:
            out["secureNote"] = Self.merged(original?["secureNote"], ["type": 0])
        case .card:
            out["card"] = Self.merged(original?["card"], [
                "cardholderName": try text(card.cardholderName), "brand": try text(card.brand),
                "number": try text(card.number), "expMonth": try text(card.expMonth),
                "expYear": try text(card.expYear), "code": try text(card.code),
            ])
        case .identity:
            let i = identity
            out["identity"] = Self.merged(original?["identity"], [
                "title": try text(i.title), "firstName": try text(i.firstName),
                "middleName": try text(i.middleName), "lastName": try text(i.lastName),
                "address1": try text(i.address1), "address2": try text(i.address2),
                "address3": try text(i.address3), "city": try text(i.city),
                "state": try text(i.state), "postalCode": try text(i.postalCode),
                "country": try text(i.country), "company": try text(i.company),
                "email": try text(i.email), "phone": try text(i.phone), "ssn": try text(i.ssn),
                "username": try text(i.username), "passportNumber": try text(i.passportNumber),
                "licenseNumber": try text(i.licenseNumber),
            ])
        }

        // Linked custom fields are not editable here; keep them as they were.
        let linked = ((original?["fields"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? Int) == 3 }
        var editable: [[String: Any]] = []
        for f in fields {
            guard let name = f.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            editable.append(["name": try transform(name), "value": try text(f.value ?? "") , "type": (f.type ?? .text).rawValue, "linkedId": NSNull()])
        }
        let key = totp.trimmingCharacters(in: .whitespaces)
        if totpInField, type == .login, !key.isEmpty {
            editable.append(["name": try transform(TOTPStorage.fieldName), "value": try transform(key), "type": CustomField.Kind.hidden.rawValue, "linkedId": NSNull()])
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
