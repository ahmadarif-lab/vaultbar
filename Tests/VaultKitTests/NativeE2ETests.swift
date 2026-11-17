import XCTest
@testable import VaultKit

/// End-to-end against a real Vaultwarden: `VW_URL=http://127.0.0.1:18222 swift test -c release --filter NativeE2ETests`.
final class NativeE2ETests: XCTestCase {
    private var fixture: VaultwardenFixture!
    private var secrets: InMemorySecretStore!
    private let device = DeviceInfo(identifier: UUID().uuidString)
    private var accounts: [Account] = []

    override func setUpWithError() throws {
        guard let f = VaultwardenFixture.current else { throw XCTSkip("set VW_URL to run the Vaultwarden end-to-end tests") }
        fixture = f
        secrets = InMemorySecretStore()
    }

    override func tearDown() { for a in accounts { try? FileManager.default.removeItem(at: a.dataDirectory) } }

    private func newAccount(kdf: KDFConfig = KDFConfig(type: 0, iterations: 600_000)) async throws -> (Account, String) {
        let email = "e2e-\(UUID().uuidString.prefix(8).lowercased())@example.test"
        let password = "correct horse battery staple"
        try await fixture.register(email: email, password: password, kdf: kdf)
        let account = Account(email: email, server: fixture.server)
        accounts.append(account)
        return (account, password)
    }

    private func login(_ account: Account, _ password: String) async throws -> NativeSession {
        let api = BitwardenAPI(server: account.server, device: device)
        let outcome = try await NativeLogin(account: account, api: api, secrets: secrets).start(password: password)
        guard case .success(let session) = outcome else { XCTFail("expected success, got \(outcome)"); throw VaultError.badResponse }
        return session
    }

    private func reopen(_ account: Account) -> NativeSession {
        NativeSession(account: account, secrets: secrets, api: BitwardenAPI(server: account.server, device: device))
    }

    func testLoginSyncCreateEditCloneDelete() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        var snap = try await session.snapshot()
        XCTAssertTrue(snap.items.isEmpty)

        var draft = ItemDraft(type: .login)
        draft.name = "Example Site"; draft.username = "me@example.test"; draft.password = "pw-1"
        draft.totp = "JBSWY3DPEHPK3PXP"; draft.uris = ["https://example.test/login"]; draft.notes = "secret notes — ünïcode"
        draft.fields = [CustomField(name: "PIN", value: "1234", type: .hidden)]
        try await session.save(draft)

        try await session.sync() // round trip through the server
        snap = try await session.snapshot()
        let created = try XCTUnwrap(snap.items.first { $0.name == "Example Site" })
        XCTAssertEqual(created.login?.username, "me@example.test")
        XCTAssertEqual(created.login?.password, "pw-1")
        XCTAssertEqual(created.login?.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(created.login?.uris?.first?.uri, "https://example.test/login")
        XCTAssertEqual(created.notes, "secret notes — ünïcode")
        XCTAssertEqual(created.fields?.first?.value, "1234")
        XCTAssertEqual(created.fields?.first?.type, .hidden)

        // edit: name + password change; old password goes to history
        var edit = ItemDraft(item: created)
        edit.name = "Renamed"; edit.password = "pw-2"; edit.favorite = true
        try await session.save(edit)
        try await session.sync()
        snap = try await session.snapshot()
        let edited = try XCTUnwrap(snap.items.first { $0.id == created.id })
        XCTAssertEqual(edited.name, "Renamed")
        XCTAssertEqual(edited.login?.password, "pw-2")
        XCTAssertEqual(edited.favorite, true)
        XCTAssertEqual(edited.login?.username, "me@example.test", "untouched fields survive")

        // clone
        try await session.clone(id: created.id, nameSuffix: " - Clone")
        try await session.sync()
        snap = try await session.snapshot()
        let clone = try XCTUnwrap(snap.items.first { $0.name == "Renamed - Clone" })
        XCTAssertNotEqual(clone.id, created.id)
        XCTAssertEqual(clone.login?.password, "pw-2")

        // delete (trash)
        try await session.delete(id: clone.id)
        try await session.sync()
        snap = try await session.snapshot()
        XCTAssertFalse(snap.items.contains { $0.id == clone.id })
        XCTAssertTrue(snap.items.contains { $0.id == created.id })
    }

    func testLockUnlockOfflineAndWrongPassword() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        var d = ItemDraft(type: .secureNote); d.name = "Offline note"; d.notes = "hello"
        try await session.save(d)
        await session.lock()
        do { _ = try await session.snapshot(); XCTFail("snapshot after lock must fail") } catch { XCTAssertEqual(error as? VaultError, .notLoggedIn) }

        // A fresh object with an unreachable server still unlocks from the on-disk cache.
        let offline = NativeSession(account: account, secrets: secrets,
                                    api: BitwardenAPI(server: .selfHosted("http://127.0.0.1:9"), device: device))
        do { try await offline.unlock(password: "wrong"); XCTFail("wrong password must fail") }
        catch { XCTAssertEqual(error as? VaultError, .invalidPassword) }
        try await offline.unlock(password: password)
        let snap = try await offline.snapshot()
        XCTAssertEqual(snap.items.first { $0.name == "Offline note" }?.notes, "hello")
    }

    func testWrongPasswordAtLogin() async throws {
        let (account, _) = try await newAccount()
        let api = BitwardenAPI(server: account.server, device: device)
        do { _ = try await NativeLogin(account: account, api: api, secrets: secrets).start(password: "not it"); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .invalidPassword) }
        XCTAssertNil(AccountStorage(directory: account.dataDirectory).loadRecord(), "a failed login leaves nothing on disk")
    }

    func testRefreshTokenKeepsSessionAlive() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        XCTAssertNotNil(secrets.get(account.refreshTokenKey))
        session.setTokens(access: "expired-garbage", expiresIn: 0, refresh: nil) // force the refresh path
        try await session.sync()
        _ = try await session.snapshot()
    }

    func testTwoFactorAuthenticatorFlow() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        // enable TOTP 2FA using the freshly issued token
        let master = try MasterKey.derive(password: password, email: account.email, kdf: KDFConfig())
        let secret = try await fixture.enableAuthenticator(accessToken: try await tokenFor(session), authHash: MasterKey.authHash(masterKey: master, password: password))
        await session.lock()
        secrets.remove(account.refreshTokenKey)
        AccountStorage(directory: account.dataDirectory).wipe()

        let api = BitwardenAPI(server: account.server, device: DeviceInfo(identifier: UUID().uuidString))
        let flow = NativeLogin(account: account, api: api, secrets: secrets)
        let first = try await flow.start(password: password)
        guard case .twoFactor(let challenge) = first else { return XCTFail("expected a 2FA challenge, got \(first)") }
        XCTAssertTrue(challenge.supported.contains(.authenticator))

        do { _ = try await flow.submitTwoFactor(provider: .authenticator, code: "000000"); XCTFail("bad code must fail") }
        catch { XCTAssertEqual(error as? VaultError, .invalidTwoFactorCode) }

        // The server rejects re-use of the code that just enabled 2FA, so use the next 30 s step (inside its drift window).
        let ok = try await flow.submitTwoFactor(provider: .authenticator, code: TOTP(parsing: secret)!.code(at: Date().addingTimeInterval(30)))
        guard case .success(let s2) = ok else { return XCTFail("expected success after the right code") }
        _ = try await s2.snapshot()
    }

    func testApiKeyLogin() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        let master = try MasterKey.derive(password: password, email: account.email, kdf: KDFConfig())
        let hash = MasterKey.authHash(masterKey: master, password: password)
        let secret = try await fixture.apiKey(accessToken: try await tokenFor(session), authHash: hash)
        let userID = try await userID(of: session)

        let api = BitwardenAPI(server: account.server, device: DeviceInfo(identifier: UUID().uuidString))
        let outcome = try await NativeLogin(account: account, api: api, secrets: InMemorySecretStore())
            .start(password: password, apiKey: (id: "user.\(userID)", secret: secret))
        guard case .success(let s) = outcome else { return XCTFail("API key login failed: \(outcome)") }
        _ = try await s.snapshot()
    }

    func testArgon2idAccount() async throws {
        let (account, password) = try await newAccount(kdf: KDFConfig(type: 1, iterations: 3, memory: 64, parallelism: 4))
        let session = try await login(account, password)
        await session.lock()
        try await session.unlock(password: password) // exercises Argon2id on the unlock path too
        _ = try await session.snapshot()
    }

    /// Imports a real Bitwarden export (VB_IMPORT_FILE) into a throwaway vault and checks every item survives,
    /// without printing any item content.
    func testImportRealExportFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["VB_IMPORT_FILE"] else { throw XCTSkip("set VB_IMPORT_FILE to a Bitwarden .json export") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plan = try BitwardenFile.parse(data)
        XCTAssertGreaterThan(plan.entries.count, 0)

        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        var snapshot = try await session.snapshot()
        let (request, report) = BitwardenFile.prepare(plan, existing: snapshot)
        XCTAssertEqual(report.duplicates, 0)
        try await session.importEntries(request)

        snapshot = try await session.snapshot()
        XCTAssertEqual(snapshot.items.count, plan.entries.count, "every importable item arrived")
        XCTAssertEqual(Set(snapshot.folders.map(\.name)), Set(plan.folderNames), "folders were created")

        // field-by-field comparison (by fingerprint, so duplicate names do not matter); report counts only
        var imported: [String: Int] = [:]
        for item in snapshot.items { imported[BitwardenFile.fingerprint(ItemDraft(item: item)), default: 0] += 1 }
        var missing = 0
        for e in plan.entries {
            let key = BitwardenFile.fingerprint(e.draft)
            if let n = imported[key], n > 0 { imported[key] = n - 1 } else { missing += 1 }
        }
        XCTAssertEqual(missing, 0, "\(missing) items differ after the round trip")

        // folder assignment and password history
        var folderMismatch = 0
        let folderName = Dictionary(uniqueKeysWithValues: snapshot.folders.compactMap { f in f.id.map { ($0, f.name) } })
        var expected: [String: [String?]] = [:]
        for e in plan.entries { expected[BitwardenFile.fingerprint(e.draft), default: []].append(e.folderName) }
        for item in snapshot.items {
            let key = BitwardenFile.fingerprint(ItemDraft(item: item))
            let got = item.folderId.flatMap { folderName[$0] }
            if var list = expected[key], let i = list.firstIndex(where: { $0 == got }) { list.remove(at: i); expected[key] = list } else { folderMismatch += 1 }
        }
        XCTAssertEqual(folderMismatch, 0, "\(folderMismatch) items landed in the wrong folder")
        let withHistory = plan.entries.filter { !$0.history.isEmpty }.count
        let sync = try XCTUnwrap(AccountStorage(directory: account.dataDirectory).loadSync())
        let storedHistory = ((sync["ciphers"] as? [[String: Any]]) ?? []).filter { !(($0["passwordHistory"] as? [Any]) ?? []).isEmpty }.count
        XCTAssertEqual(storedHistory, withHistory, "password history survived")

        // importing the same file again adds nothing
        let (again, report2) = BitwardenFile.prepare(plan, existing: snapshot)
        XCTAssertEqual(again.entries.count, 0)
        XCTAssertEqual(report2.duplicates, plan.entries.count)

        // export and re-parse
        let exported = try BitwardenFile.export(items: snapshot.items, folders: snapshot.folders)
        let replan = try BitwardenFile.parse(exported)
        XCTAssertEqual(replan.entries.count, plan.entries.count)
        print("IMPORT-CHECK items=\(plan.entries.count) folders=\(plan.folderNames.count) history=\(withHistory) passkeys=\(plan.passkeys)")
    }

    /// Items created by the official clients carry a per-item key (`key`); editing one must keep it and encrypt with it.
    func testEditItemWithPerItemKey() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        let sync0 = try XCTUnwrap(AccountStorage(directory: account.dataDirectory).loadSync())
        let userID = try XCTUnwrap((sync0["profile"] as? [String: Any])?["id"] as? String)

        // Build the cipher exactly like an official client: item key wrapped by the user key, fields under the item key.
        let master = try MasterKey.derive(password: password, email: account.email, kdf: KDFConfig())
        let record = try XCTUnwrap(AccountStorage(directory: account.dataDirectory).loadRecord())
        let userKey = try VaultKey(bytes: EncString(record.encryptedUserKey)!.decrypt(with: MasterKey.stretch(master)))
        let itemKey = VaultKey.random()
        func e(_ s: String) -> String { try! EncString.encrypt(s, with: itemKey) }
        let body: [String: Any] = [
            "type": 1, "name": e("Keyed login"), "notes": e("2FA TOTP"), "favorite": false, "folderId": NSNull(), "organizationId": NSNull(),
            "key": try EncString.encrypt(itemKey.bytes, with: userKey), "reprompt": 0, "encryptedFor": userID,
            "login": ["username": e("keyed.user"), "password": e("keyed-pw"), "totp": NSNull(),
                      "uris": [["uri": e("https://www.instagram.com/"), "match": NSNull()]]],
        ]
        let api = BitwardenAPI(server: account.server, device: device)
        let token = try await api.token(TokenGrant(.refresh(try XCTUnwrap(secrets.get(account.refreshTokenKey))))).accessToken
        let created = try await api.authorized("POST", "ciphers", body: body, accessToken: token)
        XCTAssertNotNil(created["key"], "the server kept the cipher key")

        try await session.sync()
        let snap1 = try await session.snapshot()
        let item = try XCTUnwrap(snap1.items.first { $0.name == "Keyed login" })
        XCTAssertEqual(item.login?.password, "keyed-pw")

        var draft = ItemDraft(item: item)
        draft.totp = "JBSWY3DPEHPK3PXP"; draft.password = "changed-pw"; draft.name = "Keyed login v2"
        try await session.save(draft)
        try await session.sync()
        let snap2 = try await session.snapshot()
        let after = try XCTUnwrap(snap2.items.first { $0.id == item.id })
        XCTAssertEqual(after.name, "Keyed login v2")
        XCTAssertEqual(after.login?.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(after.login?.password, "changed-pw")
        XCTAssertEqual(after.login?.uris?.first?.uri, "https://www.instagram.com/")
        let raw = try XCTUnwrap((AccountStorage(directory: account.dataDirectory).loadSync()?["ciphers"] as? [[String: Any]])?.first { ($0["id"] as? String) == item.id })
        XCTAssertNotNil(raw["key"], "the per-item key survives an edit")
        XCTAssertEqual((raw["passwordHistory"] as? [Any])?.count, 1, "the old password went to the history")
    }

    /// The exact sequence from a bug report: set a key, save; clear it, save; reopen. It must stay cleared.
    func testClearingTheAuthenticatorKeyPersists() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        var d = ItemDraft(type: .login); d.name = "Example Login"; d.username = "u"; d.password = "p"; d.notes = "2FA TOTP\nJBSWY3DPEHPK3PXP"
        try await session.save(d)
        try await session.sync()
        var snap = try await session.snapshot()
        var item = try XCTUnwrap(snap.items.first { $0.name == "Example Login" })

        var edit = ItemDraft(item: item); edit.totp = "JBSWY3DPEHPK3PXP"
        try await session.save(edit)
        try await session.sync()
        snap = try await session.snapshot()
        item = try XCTUnwrap(snap.items.first { $0.name == "Example Login" })
        XCTAssertEqual(item.authenticatorKey, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(item.login?.totp, "JBSWY3DPEHPK3PXP", "a Premium-style server keeps login.totp")

        var clear = ItemDraft(item: item); clear.totp = ""
        try await session.save(clear)
        // without a sync: what the app shows right after saving
        snap = try await session.snapshot()
        XCTAssertNil(snap.items.first { $0.name == "Example Login" }?.authenticatorKey, "cleared right after save")
        // and after a fresh sync + a lock/unlock from the on-disk cache
        try await session.sync()
        await session.lock()
        try await session.unlock(password: password)
        snap = try await session.snapshot()
        XCTAssertNil(snap.items.first { $0.name == "Example Login" }?.authenticatorKey, "still cleared after sync and re-unlock")
        XCTAssertEqual(snap.items.first { $0.name == "Example Login" }?.notes, "2FA TOTP\nJBSWY3DPEHPK3PXP", "notes untouched")
    }

    /// If the server drops `login.totp` (free accounts), the key must end up in the hidden field and still produce codes.
    func testAuthenticatorKeyFallsBackToHiddenFieldWhenServerDropsIt() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        var draft = ItemDraft(type: .login)
        draft.name = "Free plan login"; draft.username = "u"; draft.password = "p"; draft.totp = "JBSWY3DPEHPK3PXP"
        session.simulateTOTPDrop = true
        try await session.save(draft)
        XCTAssertTrue(session.lastSaveUsedKeyField)
        XCTAssertTrue(session.serverDropsTOTP)

        try await session.sync() // from the server this time
        var snap = try await session.snapshot()
        let item = try XCTUnwrap(snap.items.first { $0.name == "Free plan login" })
        XCTAssertNil(item.login?.totp, "login.totp stays empty")
        XCTAssertEqual(item.authenticatorKey, "JBSWY3DPEHPK3PXP")
        let entry = try XCTUnwrap(VaultEntry.build(from: snap).first { $0.id == item.id })
        XCTAssertNotNil(entry.totp, "the code is generated from the hidden field")
        XCTAssertEqual(entry.item.fields?.filter { TOTPStorage.isKeyField($0) }.count, 1)
        XCTAssertFalse(entry.detailSections().flatMap(\.fields).contains { $0.literalLabel == TOTPStorage.fieldName }, "the storage field is not shown as a custom field")

        // editing again keeps exactly one key field and the key input is filled from it
        var again = ItemDraft(item: item)
        XCTAssertEqual(again.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertFalse(again.fields.contains { TOTPStorage.isKeyField($0) })
        again.name = "Free plan login v2"
        try await session.save(again)
        try await session.sync()
        snap = try await session.snapshot()
        let after = try XCTUnwrap(snap.items.first { $0.id == item.id })
        XCTAssertEqual(after.name, "Free plan login v2")
        XCTAssertEqual(after.fields?.filter { TOTPStorage.isKeyField($0) }.count, 1)
        XCTAssertEqual(after.authenticatorKey, "JBSWY3DPEHPK3PXP")

        // clearing the key removes the field
        var cleared = ItemDraft(item: after); cleared.totp = ""
        try await session.save(cleared)
        try await session.sync()
        snap = try await session.snapshot()
        XCTAssertNil(snap.items.first { $0.id == item.id }?.authenticatorKey)
    }

    /// Edits every item of a real export after importing it (adds an authenticator key, renames), the way a user does,
    /// and reports only counts and server messages, never item content.
    func testEditEveryImportedItem() async throws {
        guard let path = ProcessInfo.processInfo.environment["VB_IMPORT_FILE"] else { throw XCTSkip("set VB_IMPORT_FILE") }
        let plan = try BitwardenFile.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
        let (account, password) = try await newAccount()
        let session = try await login(account, password)
        let (request, _) = BitwardenFile.prepare(plan, existing: try await session.snapshot())
        try await session.importEntries(request)

        var failures: [String: Int] = [:]
        var ok = 0
        for item in try await session.snapshot().items {
            var draft = ItemDraft(item: item)
            draft.name += " (edited)"
            if draft.type == .login { draft.totp = "JBSWY3DPEHPK3PXP" }
            draft.notes += "\n2FA TOTP"
            do { try await session.save(draft); ok += 1 }
            catch { failures[String(describing: error).prefix(160).description, default: 0] += 1 }
        }
        try await session.sync()
        let after = try await session.snapshot()
        XCTAssertEqual(failures.count, 0, "edit failures: \(failures)")
        XCTAssertEqual(after.items.filter { $0.name.hasSuffix(" (edited)") }.count, ok)
        XCTAssertEqual(after.items.filter { $0.login?.totp == "JBSWY3DPEHPK3PXP" }.count, plan.entries.filter { $0.draft.type == .login }.count)
        print("EDIT-CHECK edited=\(ok) failed=\(failures.values.reduce(0, +))")
    }

    func testFolderCreateRenameDelete() async throws {
        let (account, password) = try await newAccount()
        let session = try await login(account, password)

        try await session.createFolder(name: "Work")
        try await session.createFolder(name: "Café ünï")
        var snap = try await session.snapshot()
        XCTAssertEqual(Set(snap.folders.map(\.name)), ["Work", "Café ünï"])
        let work = try XCTUnwrap(snap.folders.first { $0.name == "Work" }?.id)

        var draft = ItemDraft(type: .login)
        draft.name = "In folder"; draft.folderId = work
        try await session.save(draft)

        try await session.renameFolder(id: work, name: "Office")
        try await session.sync() // what the server really has
        snap = try await session.snapshot()
        XCTAssertEqual(Set(snap.folders.map(\.name)), ["Office", "Café ünï"])
        XCTAssertEqual(snap.items.first { $0.name == "In folder" }?.folderId, work)

        try await session.deleteFolder(id: work)
        snap = try await session.snapshot()
        XCTAssertEqual(snap.folders.map(\.name), ["Café ünï"])
        XCTAssertNil(snap.items.first { $0.name == "In folder" }?.folderId, "cache mirrors the server: items leave the deleted folder")
        try await session.sync()
        snap = try await session.snapshot()
        XCTAssertEqual(snap.folders.map(\.name), ["Café ünï"])
        XCTAssertNil(snap.items.first { $0.name == "In folder" }?.folderId)
        XCTAssertEqual(snap.items.count, 1, "deleting a folder keeps its items")
    }

    /// Not a real test: `VW_REGISTER_OUT=/path swift test ... --filter testRegisterForAppSelftest` writes
    /// credentials of a fresh account for the app's `--selftest-live` run.
    func testRegisterForAppSelftest() async throws {
        guard let out = ProcessInfo.processInfo.environment["VW_REGISTER_OUT"] else { throw XCTSkip("only used to prepare --selftest-live") }
        let (account, password) = try await newAccount()
        let json = try JSONSerialization.data(withJSONObject: ["email": account.email, "password": password, "server": fixture.base.absoluteString])
        try json.write(to: URL(fileURLWithPath: out))
    }

    // MARK: helpers

    /// A currently valid access token of `session` (read through its own refresh path).
    private func tokenFor(_ session: NativeSession) async throws -> String {
        let refresh = try XCTUnwrap(secrets.get(session.account.refreshTokenKey))
        let api = BitwardenAPI(server: session.account.server, device: device)
        return try await api.token(TokenGrant(.refresh(refresh))).accessToken
    }

    private func userID(of session: NativeSession) async throws -> String {
        let sync = try XCTUnwrap(AccountStorage(directory: session.account.dataDirectory).loadSync())
        return try XCTUnwrap((sync["profile"] as? [String: Any])?["id"] as? String)
    }
}
