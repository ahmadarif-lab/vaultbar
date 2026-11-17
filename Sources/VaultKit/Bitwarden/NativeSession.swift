import Foundation

/// A vault session that talks to the Bitwarden API directly (no `bw`): the encrypted
/// vault is cached on disk, the keys live in memory only while unlocked.
public final class NativeSession: VaultSession, @unchecked Sendable {
    public let account: Account
    private let storage: AccountStorage
    private let secrets: SecretStore
    private let api: BitwardenAPI

    private let lock = NSLock()
    private var userKey: VaultKey?
    private var decryptor: VaultDecryptor?
    private var syncData: [String: Any]?
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    /// Items skipped in the last decrypt (for diagnostics, never item data).
    public private(set) var skippedItems = 0
    /// Set once the server has been seen to drop `login.totp` on save (free accounts); from then on the key
    /// goes straight into the hidden "VaultBar 2FA" field.
    public private(set) var serverDropsTOTP = false
    /// True when the last save had to fall back to the hidden field (the UI tells the user).
    public private(set) var lastSaveUsedKeyField = false
    /// Test hook: behave as if the server dropped the key on the first attempt.
    var simulateTOTPDrop = false

    public init(account: Account, secrets: SecretStore, api: BitwardenAPI, storage: AccountStorage? = nil) {
        self.account = account
        self.secrets = secrets
        self.api = api
        self.storage = storage ?? AccountStorage(directory: account.dataDirectory)
    }

    // MARK: Unlock / lock

    public func unlock(password: String) async throws {
        guard let record = storage.loadRecord(), let wrapped = EncString(record.encryptedUserKey) else { throw VaultError.notLoggedIn }
        let kdf = record.kdf, salt = record.kdfSalt ?? account.email
        // Argon2id/PBKDF2 are CPU- and memory-heavy: keep them off the caller's (main) thread.
        let key: VaultKey = try await Task.detached(priority: .userInitiated) {
            let master = try MasterKey.derive(password: password, email: salt, kdf: kdf)
            do { return try VaultKey(bytes: wrapped.decrypt(with: MasterKey.stretch(master))) }
            catch CryptoError.macMismatch { throw VaultError.invalidPassword }
            catch let e as CryptoError { throw VaultError.unsupported("\(e)") }
        }.value
        adopt(userKey: key, sync: storage.loadSync())
        if lock.withLock({ syncData == nil }) { try await sync() }
    }

    /// Checks a master password against the stored (encrypted) user key without unlocking anything.
    public static func verifyPassword(_ password: String, for account: Account) async throws {
        guard let record = AccountStorage(directory: account.dataDirectory).loadRecord(), let wrapped = EncString(record.encryptedUserKey) else {
            throw VaultError.notLoggedIn
        }
        let salt = record.kdfSalt ?? account.email, kdf = record.kdf
        try await Task.detached(priority: .userInitiated) {
            let master = try MasterKey.derive(password: password, email: salt, kdf: kdf)
            do { _ = try wrapped.decrypt(with: MasterKey.stretch(master)) } catch CryptoError.macMismatch { throw VaultError.invalidPassword }
        }.value
    }

    /// Deletes everything stored for the account: cached vault, key record and refresh token.
    public static func forget(_ account: Account, secrets: SecretStore) {
        AccountStorage(directory: account.dataDirectory).wipe()
        secrets.remove(account.refreshTokenKey)
    }

    /// Used right after login: the key is already in hand.
    func adopt(userKey: VaultKey, sync: [String: Any]?) {
        let record = storage.loadRecord()
        let profile = sync?["profile"] as? [String: Any]
        let dec = VaultDecryptor(userKey: userKey, encryptedPrivateKey: (profile?["privateKey"] as? String) ?? record?.encryptedPrivateKey,
                                 organizations: (profile?["organizations"] as? [[String: Any]]) ?? [])
        lock.withLock { self.userKey = userKey; decryptor = dec; syncData = sync }
    }

    func setTokens(access: String, expiresIn: Int, refresh: String?) {
        lock.withLock { accessToken = access; accessExpiry = Date().addingTimeInterval(TimeInterval(max(60, expiresIn) - 30)) }
        if let refresh { secrets.set(refresh, for: account.refreshTokenKey) }
    }

    public func lock() async {
        lock.withLock { userKey = nil; decryptor = nil; syncData = nil; accessToken = nil; accessExpiry = .distantPast }
    }

    // MARK: Tokens

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = lock.withLock({ Date() < accessExpiry ? accessToken : nil }) { return t }
        guard let refresh = secrets.get(account.refreshTokenKey) else { throw VaultError.notLoggedIn }
        do {
            let r = try await api.token(TokenGrant(.refresh(refresh)))
            setTokens(access: r.accessToken, expiresIn: r.expiresIn, refresh: r.refreshToken)
            return r.accessToken
        } catch VaultError.invalidPassword {
            throw VaultError.notLoggedIn // refresh token revoked: needs a fresh login
        }
    }

    /// Runs `body` with a token; one retry with a freshly refreshed token on 401.
    private func withToken<T>(_ body: (String) async throws -> T) async throws -> T {
        do { return try await body(try await validAccessToken()) }
        catch VaultError.notLoggedIn { return try await body(try await validAccessToken(forceRefresh: true)) }
    }

    // MARK: Sync and reads

    private func state() throws -> (VaultKey, VaultDecryptor) {
        try lock.withLock {
            guard let userKey, let decryptor else { throw VaultError.notLoggedIn }
            return (userKey, decryptor)
        }
    }

    public func sync() async throws {
        _ = try state()
        let data = try await withToken { try await api.sync(accessToken: $0) }
        let obj = try JSONUtil.parseObject(data)
        try? storage.saveSync(obj)
        // Keep the encrypted private key current (it can change with key rotation).
        if var record = storage.loadRecord(), let pk = (obj["profile"] as? [String: Any])?["privateKey"] as? String, pk != record.encryptedPrivateKey {
            record.encryptedPrivateKey = pk
            try? storage.saveRecord(record)
        }
        let key = try state().0
        adopt(userKey: key, sync: obj)
    }

    public func snapshot() async throws -> VaultSnapshot {
        let (_, dec) = try state()
        guard let sync = lock.withLock({ syncData }) else { throw VaultError.notLoggedIn }
        let result = dec.snapshot(from: sync)
        skippedItems = result.skipped
        return result.snapshot
    }

    // MARK: Writes

    private func cachedCipher(_ id: String) -> [String: Any]? {
        lock.withLock { (syncData?["ciphers"] as? [[String: Any]])?.first { ($0["id"] as? String) == id } }
    }

    private func store(cipher: [String: Any]) {
        lock.withLock {
            var data = syncData ?? [:]
            var list = (data["ciphers"] as? [[String: Any]]) ?? []
            if let i = list.firstIndex(where: { ($0["id"] as? String) == (cipher["id"] as? String) }) { list[i] = cipher } else { list.append(cipher) }
            data["ciphers"] = list
            syncData = data
        }
        persist()
    }

    private func drop(cipherID: String) {
        lock.withLock {
            var data = syncData ?? [:]
            data["ciphers"] = ((data["ciphers"] as? [[String: Any]]) ?? []).filter { ($0["id"] as? String) != cipherID }
            syncData = data
        }
        persist()
    }

    private func persist() {
        if let data = lock.withLock({ syncData }) { try? storage.saveSync(data) }
    }

    private var userID: Any {
        lock.withLock { ((syncData?["profile"] as? [String: Any])?["id"] as? String) as Any? ?? NSNull() }
    }

    /// One create/update request. `existing` is the stored cipher being updated (nil = create).
    private func send(_ draft: ItemDraft, existing raw: [String: Any]?, inField: Bool) async throws -> [String: Any] {
        let (userKey, dec) = try state()
        if let raw, let id = raw["id"] as? String {
            let key = try dec.itemKey(for: raw)
            var body = try draft.json(merging: raw, totpInField: inField) { try EncString.encrypt($0, with: key) }
            try addPasswordHistory(to: &body, draft: draft, original: raw, decryptor: dec, key: key)
            if let revision = raw["revisionDate"] as? String { body["lastKnownRevisionDate"] = revision }
            body["encryptedFor"] = userID
            let request = CipherRequestBody.make(from: body) // drops the stale legacy `data` blob and other response-only keys
            let response = try await withToken { try await api.authorized("PUT", "ciphers/\(id)", body: request, accessToken: $0) }
            return response.isEmpty ? body : response
        }
        var body = try draft.json(merging: nil, totpInField: inField) { try EncString.encrypt($0, with: userKey) }
        body["encryptedFor"] = userID
        let request = CipherRequestBody.make(from: body)
        let response = try await withToken { try await api.authorized("POST", "ciphers", body: request, accessToken: $0) }
        guard response["id"] != nil else { throw VaultError.badResponse }
        return response
    }

    /// Did the server keep the authenticator key in `login.totp`?
    private func serverKeptKey(_ response: [String: Any]) -> Bool {
        guard let dec = try? state().1, let item = try? dec.item(from: response) else { return false }
        return item.login?.totp?.isEmpty == false
    }

    public func save(_ draft: ItemDraft) async throws {
        var existing: [String: Any]?
        if let id = draft.id {
            guard let raw = cachedCipher(id) else { throw VaultError.server("Item not found. Sync and try again.") }
            existing = raw
        }
        lastSaveUsedKeyField = false
        var response = try await send(draft, existing: existing, inField: serverDropsTOTP)
        store(cipher: response)

        // Bitwarden keeps `login.totp` only for Premium accounts and otherwise saves everything else but
        // silently drops the key. Verify instead of assuming: if it did not come back, keep it in a hidden field.
        let wantsKey = draft.type == .login && !draft.totp.trimmingCharacters(in: .whitespaces).isEmpty
        if wantsKey, !serverDropsTOTP {
            let dropped = simulateTOTPDrop || !serverKeptKey(response)
            simulateTOTPDrop = false
            if dropped {
                serverDropsTOTP = true
                response = try await send(draft, existing: response, inField: true)
                store(cipher: response)
            }
        }
        lastSaveUsedKeyField = wantsKey && serverDropsTOTP

        // Trust but verify: fetch the item back and compare. The server's copy wins in the local cache,
        // so the UI never shows something the server does not have.
        if let id = response["id"] as? String, let dec = try? state().1,
           let fresh = try? await withToken({ try await api.authorized("GET", "ciphers/\(id)", body: nil, accessToken: $0) }), fresh["id"] != nil {
            store(cipher: fresh)
            if let item = try? dec.item(from: fresh) {
                let diffs = SaveVerifier.differences(draft: draft, server: item)
                if !diffs.isEmpty { throw VaultError.serverIgnored(diffs) }
            }
        }
    }

    /// Like the official clients: when a login's password changes, the old one is kept in the item's history.
    private func addPasswordHistory(to body: inout [String: Any], draft: ItemDraft, original: [String: Any],
                                    decryptor: VaultDecryptor, key: VaultKey) throws {
        guard draft.type == .login, let old = try? decryptor.item(from: original).login?.password, !old.isEmpty, old != draft.password else { return }
        var history = (original["passwordHistory"] as? [[String: Any]]) ?? []
        history.append(["password": try EncString.encrypt(old, with: key), "lastUsedDate": ISO8601DateFormatter().string(from: Date())])
        body["passwordHistory"] = Array(history.suffix(5))
    }

    public func clone(id: String, nameSuffix: String) async throws {
        let (_, dec) = try state()
        guard let raw = cachedCipher(id) else { throw VaultError.server("Item not found. Sync and try again.") }
        if let org = raw["organizationId"] as? String, !org.isEmpty { throw VaultError.organizationItem }
        var draft = ItemDraft(item: try dec.item(from: raw))
        draft.id = nil
        draft.name += nameSuffix
        try await save(draft)
    }

    public func delete(id: String) async throws {
        _ = try state()
        _ = try await withToken { try await api.authorized("PUT", "ciphers/\(id)/delete", body: nil, accessToken: $0) }
        drop(cipherID: id) // soft delete: the item sits in the trash until the user empties it elsewhere
    }

    /// POST /ciphers with a short retry when the server rate-limits.
    private func createCipher(_ body: [String: Any]) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                let response = try await withToken { try await api.authorized("POST", "ciphers", body: body, accessToken: $0) }
                guard response["id"] != nil else { throw VaultError.badResponse }
                return response
            } catch VaultError.server(let message) where message.lowercased().contains("too many") && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }

    // MARK: Folders

    private func storeFolders(_ change: ([[String: Any]]) -> [[String: Any]]) {
        lock.withLock {
            var data = syncData ?? [:]
            data["folders"] = change((data["folders"] as? [[String: Any]]) ?? [])
            syncData = data
        }
        persist()
    }

    public func createFolder(name: String) async throws {
        let (userKey, _) = try state()
        let body: [String: Any] = ["name": try EncString.encrypt(name, with: userKey)]
        let response = try await withToken { try await api.authorized("POST", "folders", body: body, accessToken: $0) }
        guard response["id"] is String else { throw VaultError.badResponse }
        storeFolders { $0 + [response] }
    }

    public func renameFolder(id: String, name: String) async throws {
        let (userKey, _) = try state()
        let body: [String: Any] = ["name": try EncString.encrypt(name, with: userKey)]
        let response = try await withToken { try await api.authorized("PUT", "folders/\(id)", body: body, accessToken: $0) }
        storeFolders { list in list.map { ($0["id"] as? String) == id ? (response["id"] != nil ? response : $0.merging(["name": body["name"] as Any]) { _, new in new }) : $0 } }
    }

    public func deleteFolder(id: String) async throws {
        _ = try state()
        _ = try await withToken { try await api.authorized("DELETE", "folders/\(id)", body: nil, accessToken: $0) }
        storeFolders { $0.filter { ($0["id"] as? String) != id } }
        // The server moves the folder's items to "No folder"; mirror that in the cache.
        lock.withLock {
            var data = syncData ?? [:]
            data["ciphers"] = ((data["ciphers"] as? [[String: Any]]) ?? []).map { cipher in
                guard (cipher["folderId"] as? String) == id else { return cipher }
                var c = cipher; c["folderId"] = NSNull(); return c
            }
            syncData = data
        }
        persist()
    }

    public func importEntries(_ request: ImportRequest) async throws {
        let (userKey, _) = try state()
        var folderIDs = request.existingFolderIDs

        // Folders first, so each cipher can carry its folder id.
        for name in request.newFolders {
            let body: [String: Any] = ["name": try EncString.encrypt(name, with: userKey)]
            let response = try await withToken { try await api.authorized("POST", "folders", body: body, accessToken: $0) }
            guard let id = response["id"] as? String else { throw VaultError.badResponse }
            folderIDs[name] = id
            lock.withLock {
                var data = syncData ?? [:]
                var list = (data["folders"] as? [[String: Any]]) ?? []
                list.append(response)
                data["folders"] = list
                syncData = data
            }
        }

        let user = userID
        let ciphers: [[String: Any]] = try request.entries.map { entry in
            var body = try entry.draft.json(merging: nil, totpInField: serverDropsTOTP) { try EncString.encrypt($0, with: userKey) }
            body["folderId"] = entry.folderName.flatMap { folderIDs[$0] } ?? NSNull()
            body["encryptedFor"] = user
            if !entry.history.isEmpty {
                body["passwordHistory"] = try entry.history.suffix(5).map {
                    ["password": try EncString.encrypt($0.password, with: userKey), "lastUsedDate": $0.lastUsedDate] as [String: Any]
                }
            }
            return CipherRequestBody.make(from: body)
        }
        // One request per item: the bulk `/ciphers/import` endpoint ignores each cipher's `folderId`
        // (it only honours relationships to folders created in the same request), which would drop
        // every item into "No folder". Four at a time keeps it quick without hammering the server.
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            var next = 0
            var inFlight = 0
            func launch() {
                guard next < ciphers.count else { return }
                let body = ciphers[next]; next += 1; inFlight += 1
                group.addTask { try await self.createCipher(body) }
            }
            for _ in 0..<4 { launch() }
            while inFlight > 0, let created = try await group.next() {
                inFlight -= 1
                store(cipher: created)
                launch()
            }
        }
        persist()
        try await sync() // the server assigned the ids; fetch the real thing
    }
}
