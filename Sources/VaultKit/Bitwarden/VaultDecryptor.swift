import Foundation
import Security

/// Turns the encrypted `/sync` payload into readable items (and the other way round for writes).
public struct VaultDecryptor: @unchecked Sendable {
    public let userKey: VaultKey
    /// Organization keys that could be unwrapped, by organization id.
    public let orgKeys: [String: VaultKey]

    /// `organizations` is `profile.organizations` from `/sync`; their keys are RSA-wrapped for the user's private key.
    public init(userKey: VaultKey, encryptedPrivateKey: String?, organizations: [[String: Any]]) {
        self.userKey = userKey
        var keys: [String: VaultKey] = [:]
        if let encPriv = encryptedPrivateKey, !organizations.isEmpty,
           let der = try? EncString(encPriv)?.decrypt(with: userKey), let rsa = try? RSAKey.privateKey(pkcs8: der) {
            for org in organizations {
                guard let id = org["id"] as? String, let wrapped = (org["key"] as? String).flatMap(EncString.init),
                      let bytes = try? RSAKey.decrypt(wrapped, with: rsa), let key = try? VaultKey(bytes: bytes) else { continue }
                keys[id] = key
            }
        }
        orgKeys = keys
    }

    /// The key a cipher's fields are encrypted with: the org key or user key, or the per-item key when it has one.
    public func itemKey(for cipher: [String: Any]) throws -> VaultKey {
        var base = userKey
        if let org = cipher["organizationId"] as? String, !org.isEmpty {
            guard let k = orgKeys[org] else { throw CryptoError.unsupported("organization key unavailable") }
            base = k
        }
        if let wrapped = cipher["key"] as? String, !wrapped.isEmpty {
            guard let enc = EncString(wrapped) else { throw CryptoError.invalidFormat }
            return try VaultKey(bytes: enc.decrypt(with: base))
        }
        return base
    }

    // MARK: Decrypt

    public func item(from cipher: [String: Any]) throws -> VaultItem {
        let key = try itemKey(for: cipher)
        func d(_ v: Any?) throws -> String? {
            guard let s = v as? String, !s.isEmpty else { return nil }
            return try EncString.decryptString(s, with: key)
        }
        var out: [String: Any] = [
            "id": cipher["id"] as? String ?? "",
            "type": cipher["type"] as? Int ?? 1,
            "name": try d(cipher["name"]) ?? "",
        ]
        out["organizationId"] = cipher["organizationId"] as? String
        out["folderId"] = cipher["folderId"] as? String
        out["favorite"] = cipher["favorite"] as? Bool ?? false
        out["notes"] = try d(cipher["notes"])

        if let login = cipher["login"] as? [String: Any] {
            var uris: [[String: Any]] = []
            for u in (login["uris"] as? [[String: Any]]) ?? [] {
                if let uri = try d(u["uri"]) { uris.append(["uri": uri, "match": u["match"] as Any]) }
            }
            out["login"] = ["username": try d(login["username"]) as Any, "password": try d(login["password"]) as Any,
                            "totp": try d(login["totp"]) as Any, "uris": uris]
        }
        if let card = cipher["card"] as? [String: Any] {
            var c: [String: Any] = [:]
            for k in ["cardholderName", "brand", "number", "expMonth", "expYear", "code"] { c[k] = try d(card[k]) as Any }
            out["card"] = c
        }
        if let identity = cipher["identity"] as? [String: Any] {
            var i: [String: Any] = [:]
            for k in ["title", "firstName", "middleName", "lastName", "address1", "address2", "address3", "city", "state",
                      "postalCode", "country", "company", "email", "phone", "ssn", "username", "passportNumber", "licenseNumber"] {
                i[k] = try d(identity[k]) as Any
            }
            out["identity"] = i
        }
        var fields: [[String: Any]] = []
        for f in (cipher["fields"] as? [[String: Any]]) ?? [] {
            fields.append(["name": try d(f["name"]) as Any, "value": try d(f["value"]) as Any, "type": f["type"] as? Int ?? 0])
        }
        out["fields"] = fields

        let data = try JSONSerialization.data(withJSONObject: out.mapValues { $0 is NSNull ? NSNull() : $0 })
        return try JSONDecoder().decode(VaultItem.self, from: data)
    }

    public struct Result: Sendable {
        public var snapshot: VaultSnapshot
        /// Items that could not be decrypted (bad MAC, missing org key); skipped rather than failing the whole vault.
        public var skipped: Int
    }

    public func snapshot(from sync: [String: Any]) -> Result {
        var items: [VaultItem] = []
        var skipped = 0
        for cipher in (sync["ciphers"] as? [[String: Any]]) ?? [] {
            if let deleted = cipher["deletedDate"] as? String, !deleted.isEmpty { continue } // trash
            do { items.append(try item(from: cipher)) } catch { skipped += 1 }
        }
        var folders: [VaultFolder] = []
        for f in (sync["folders"] as? [[String: Any]]) ?? [] {
            guard let id = f["id"] as? String, let name = (f["name"] as? String).flatMap({ try? EncString.decryptString($0, with: userKey) }) else { continue }
            folders.append(VaultFolder(id: id, name: name))
        }
        let profile = sync["profile"] as? [String: Any]
        let orgs: [VaultOrganization] = ((profile?["organizations"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return VaultOrganization(id: id, name: name)
        }
        return Result(snapshot: VaultSnapshot(items: items, folders: folders, organizations: orgs), skipped: skipped)
    }
}
