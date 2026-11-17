import Foundation

public struct PasswordHistoryEntry: Sendable, Equatable {
    public var password: String
    public var lastUsedDate: String
}

public struct ImportEntry: Sendable {
    public var draft: ItemDraft
    public var folderName: String?
    public var history: [PasswordHistoryEntry]
}

public enum ImportError: Error, Equatable {
    case notBitwardenExport
    case encrypted
}

/// What a Bitwarden `.json` export contains, ready to hand to the session.
public struct ImportPlan: Sendable {
    public var entries: [ImportEntry]
    public var folderNames: [String]
    /// Items the file marked as deleted (trash); not imported.
    public var trashed: Int
    /// Passkeys can't be carried over (the model has no FIDO2 support); the login itself still imports.
    public var passkeys: Int
    public var unsupportedTypes: Int
}

public struct ImportRequest: Sendable {
    public var entries: [ImportEntry]
    public var newFolders: [String]
    public var existingFolderIDs: [String: String]
}

public struct ImportReport: Equatable, Sendable {
    public var added = 0
    public var duplicates = 0
    public var trashed = 0
    public var passkeys = 0
    public var foldersCreated = 0
}

public enum BitwardenFile {
    // MARK: Import

    public static func parse(_ data: Data) throws -> ImportPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.notBitwardenExport }
        // An encrypted export has no readable `items`; say so instead of "not a Bitwarden file".
        if (root["encrypted"] as? Bool) == true { throw ImportError.encrypted }
        guard let rawItems = root["items"] as? [[String: Any]] else { throw ImportError.notBitwardenExport }

        var folderNames: [String: String] = [:]
        var orderedFolders: [String] = []
        for f in (root["folders"] as? [[String: Any]]) ?? [] {
            guard let id = f["id"] as? String, let name = f["name"] as? String, !name.isEmpty else { continue }
            folderNames[id] = name
            if !orderedFolders.contains(name) { orderedFolders.append(name) }
        }

        var entries: [ImportEntry] = []
        var trashed = 0, passkeys = 0, unsupported = 0
        for raw in rawItems {
            if let deleted = raw["deletedDate"] as? String, !deleted.isEmpty { trashed += 1; continue }
            guard let typeValue = raw["type"] as? Int, let type = ItemType(rawValue: typeValue) else { unsupported += 1; continue }

            var draft = ItemDraft(type: type)
            draft.name = (raw["name"] as? String) ?? ""
            draft.notes = (raw["notes"] as? String) ?? ""
            draft.favorite = (raw["favorite"] as? Bool) ?? false
            if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = "(no name)" }

            switch type {
            case .login:
                let login = raw["login"] as? [String: Any] ?? [:]
                draft.username = (login["username"] as? String) ?? ""
                draft.password = (login["password"] as? String) ?? ""
                draft.totp = (login["totp"] as? String) ?? ""
                let uris = ((login["uris"] as? [[String: Any]]) ?? []).compactMap { $0["uri"] as? String }.filter { !$0.isEmpty }
                draft.uris = uris.isEmpty ? [""] : uris
                if let creds = login["fido2Credentials"] as? [Any], !creds.isEmpty { passkeys += 1 }
            case .card:
                draft.card = decode(CardData.self, raw["card"]) ?? CardData()
            case .identity:
                draft.identity = decode(IdentityData.self, raw["identity"]) ?? IdentityData()
            case .secureNote:
                break
            }
            draft.fields = ((raw["fields"] as? [[String: Any]]) ?? []).compactMap { f in
                guard let kind = (f["type"] as? Int).flatMap(CustomField.Kind.init(rawValue:)), kind != .linked else { return nil }
                let field = CustomField(name: f["name"] as? String, value: f["value"] as? String, type: kind)
                if TOTPStorage.isKeyField(field) { // a key VaultBar stored in a field: back to the key input
                    if draft.totp.isEmpty { draft.totp = field.value ?? "" }
                    return nil
                }
                return field
            }
            let history = ((raw["passwordHistory"] as? [[String: Any]]) ?? []).compactMap { h -> PasswordHistoryEntry? in
                guard let pw = h["password"] as? String, !pw.isEmpty else { return nil }
                return PasswordHistoryEntry(password: pw, lastUsedDate: (h["lastUsedDate"] as? String) ?? ISO8601DateFormatter().string(from: Date()))
            }
            entries.append(ImportEntry(draft: draft, folderName: (raw["folderId"] as? String).flatMap { folderNames[$0] }, history: history))
        }
        return ImportPlan(entries: entries, folderNames: orderedFolders, trashed: trashed, passkeys: passkeys, unsupportedTypes: unsupported)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any, JSONSerialization.isValidJSONObject(any), let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Items that are exactly what the vault already holds are skipped, so importing the same file twice is harmless.
    static func fingerprint(_ d: ItemDraft) -> String {
        var parts: [String] = [String(d.type.rawValue), d.name.lowercased()]
        switch d.type {
        case .login: parts += [d.username, d.password, d.uris.first(where: { !$0.isEmpty }) ?? "", d.totp]
        case .card: parts += [d.card.number ?? "", d.card.cardholderName ?? ""]
        case .identity: parts += [d.identity.firstName ?? "", d.identity.lastName ?? "", d.identity.email ?? ""]
        case .secureNote: break
        }
        parts.append(d.notes)
        return parts.joined(separator: "\u{1F}")
    }

    public static func prepare(_ plan: ImportPlan, existing: VaultSnapshot) -> (request: ImportRequest, report: ImportReport) {
        let have = Set(existing.items.map { fingerprint(ItemDraft(item: $0)) })
        var report = ImportReport(trashed: plan.trashed, passkeys: plan.passkeys)
        var keep: [ImportEntry] = []
        for e in plan.entries {
            if have.contains(fingerprint(e.draft)) { report.duplicates += 1 } else { keep.append(e) }
        }
        var existingIDs: [String: String] = [:]
        for f in existing.folders { if let id = f.id { existingIDs[f.name] = id } }
        let newFolders = plan.folderNames.filter { existingIDs[$0] == nil }
        report.added = keep.count
        report.foldersCreated = newFolders.count
        return (ImportRequest(entries: keep, newFolders: newFolders, existingFolderIDs: existingIDs), report)
    }

    // MARK: Export

    /// Bitwarden's own unencrypted `.json` layout, so the file imports into any Bitwarden client.
    public static func export(items: [VaultItem], folders: [VaultFolder], now: Date = Date()) throws -> Data {
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            return f.string(from: now)
        }()
        func v(_ s: String?) -> Any { (s?.isEmpty ?? true) ? NSNull() : s! }
        var out: [[String: Any]] = []
        for item in items where item.organizationId == nil {
            var d: [String: Any] = [
                "passwordHistory": NSNull(), "revisionDate": stamp, "creationDate": stamp, "deletedDate": NSNull(),
                "id": item.id, "organizationId": NSNull(), "folderId": v(item.folderId), "type": item.type.rawValue,
                "reprompt": 0, "name": item.name, "notes": v(item.notes), "favorite": item.favorite ?? false,
                "collectionIds": NSNull(),
            ]
            let fields = (item.fields ?? []).map { f -> [String: Any] in
                ["name": v(f.name), "value": v(f.value), "type": (f.type ?? .text).rawValue, "linkedId": NSNull()]
            }
            if !fields.isEmpty { d["fields"] = fields }
            switch item.type {
            case .login:
                d["login"] = ["uris": (item.login?.uris ?? []).compactMap { u in u.uri.map { ["match": NSNull(), "uri": $0] as [String: Any] } },
                              "username": v(item.login?.username), "password": v(item.login?.password), "totp": v(item.authenticatorKey)] as [String: Any]
            case .secureNote:
                d["secureNote"] = ["type": 0]
            case .card:
                let c = item.card
                d["card"] = ["cardholderName": v(c?.cardholderName), "brand": v(c?.brand), "number": v(c?.number),
                             "expMonth": v(c?.expMonth), "expYear": v(c?.expYear), "code": v(c?.code)] as [String: Any]
            case .identity:
                let i = item.identity
                d["identity"] = ["title": v(i?.title), "firstName": v(i?.firstName), "middleName": v(i?.middleName), "lastName": v(i?.lastName),
                                 "address1": v(i?.address1), "address2": v(i?.address2), "address3": v(i?.address3), "city": v(i?.city),
                                 "state": v(i?.state), "postalCode": v(i?.postalCode), "country": v(i?.country), "company": v(i?.company),
                                 "email": v(i?.email), "phone": v(i?.phone), "ssn": v(i?.ssn), "username": v(i?.username),
                                 "passportNumber": v(i?.passportNumber), "licenseNumber": v(i?.licenseNumber)] as [String: Any]
            }
            out.append(d)
        }
        let folderList = folders.compactMap { f -> [String: Any]? in f.id.map { ["id": $0, "name": f.name] } }
        let root: [String: Any] = ["encrypted": false, "folders": folderList, "items": out]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
