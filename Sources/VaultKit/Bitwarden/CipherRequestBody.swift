import Foundation

/// Builds the body of a cipher create/update from a merged item, keeping only what the API accepts.
///
/// The merged JSON starts from the server's *response* for the item, which carries response-only keys.
/// The one that matters: newer servers store each item as a legacy `data` blob and derive the structured
/// fields (`login`, `name`, ...) from it, so sending the old `data` back makes the server keep the old
/// values and silently drop the edit. The official clients build the request field by field (see
/// `CipherRequest` in bitwarden/clients); this mirrors that list.
public enum CipherRequestBody {
    static let topLevel: Set<String> = [
        "encryptedFor", "encryptedByKeyId", "type", "folderId", "organizationId", "name", "notes", "favorite",
        "login", "secureNote", "card", "identity", "sshKey", "bankAccount", "driversLicense", "passport",
        "fields", "passwordHistory", "lastKnownRevisionDate", "archivedDate", "reprompt", "key",
    ]
    static let loginKeys: Set<String> = ["uris", "username", "password", "passwordRevisionDate", "totp", "autofillOnPageLoad", "fido2Credentials"]
    static let uriKeys: Set<String> = ["uri", "match", "uriChecksum"]
    static let fieldKeys: Set<String> = ["name", "value", "type", "linkedId"]
    static let historyKeys: Set<String> = ["password", "lastUsedDate"]

    /// Which type-specific object belongs to which item type.
    private static func detailKey(for type: Int) -> String? {
        switch type {
        case 1: return "login"
        case 2: return "secureNote"
        case 3: return "card"
        case 4: return "identity"
        case 5: return "sshKey"
        default: return nil
        }
    }

    private static func pick(_ dict: [String: Any], _ keys: Set<String>) -> [String: Any] {
        dict.filter { keys.contains($0.key) }
    }

    public static func make(from merged: [String: Any]) -> [String: Any] {
        var out = pick(merged, topLevel)
        let type = merged["type"] as? Int ?? 1
        let own = detailKey(for: type)
        for key in ["login", "secureNote", "card", "identity", "sshKey", "bankAccount", "driversLicense", "passport"] where key != own {
            out.removeValue(forKey: key) // a null placeholder for another type's data is not part of the request
        }
        if var login = out["login"] as? [String: Any] {
            login = pick(login, loginKeys)
            if let uris = login["uris"] as? [[String: Any]] { login["uris"] = uris.map { pick($0, uriKeys) } }
            out["login"] = login
        }
        if let fields = out["fields"] as? [[String: Any]] { out["fields"] = fields.map { pick($0, fieldKeys) } }
        if let history = out["passwordHistory"] as? [[String: Any]] { out["passwordHistory"] = history.map { pick($0, historyKeys) } }
        return out
    }
}
