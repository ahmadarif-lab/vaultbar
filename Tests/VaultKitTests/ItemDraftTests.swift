import XCTest
@testable import VaultKit

final class ItemDraftTests: XCTestCase {
    private let original: [String: Any] = [
        "id": "abc", "type": 1, "name": "Old", "notes": NSNull(), "favorite": false, "folderId": NSNull(),
        "organizationId": NSNull(), "reprompt": 1, "revisionDate": "2026-01-01T00:00:00Z",
        "passwordHistory": [["password": "older", "lastUsedDate": "2025-01-01T00:00:00Z"]],
        "attachments": [["id": "att1"]],
        "login": ["username": "u", "password": "p", "totp": NSNull(),
                  "uris": [["match": 1, "uri": "https://a.test"]],
                  "fido2Credentials": [["credentialId": "x"]]],
        "fields": [["name": "linked", "value": NSNull(), "type": 3, "linkedId": 100], ["name": "old", "value": "v", "type": 0]],
    ]

    func testEditKeepsUnknownFieldsAndURIMatchRules() throws {
        var d = ItemDraft(item: try JSONDecoder().decode(VaultItem.self, from: JSONSerialization.data(withJSONObject: original)))
        d.name = "  New  "
        d.password = "p2"
        d.uris = ["https://a.test", "https://b.test"]
        d.fields = [CustomField(name: "pin", value: "1234", type: .hidden)]
        let out = d.json(merging: original)

        XCTAssertEqual(out["name"] as? String, "New")
        XCTAssertEqual(out["reprompt"] as? Int, 1)
        XCTAssertNotNil(out["passwordHistory"])
        XCTAssertNotNil(out["attachments"])
        XCTAssertEqual(out["revisionDate"] as? String, "2026-01-01T00:00:00Z")
        let login = out["login"] as! [String: Any]
        XCTAssertEqual(login["password"] as? String, "p2")
        XCTAssertNotNil(login["fido2Credentials"], "passkeys survive an edit")
        let uris = login["uris"] as! [[String: Any]]
        XCTAssertEqual(uris.count, 2)
        XCTAssertEqual(uris[0]["match"] as? Int, 1, "existing match rule kept")
        XCTAssertTrue(uris[1]["match"] is NSNull)
        let fields = out["fields"] as! [[String: Any]]
        XCTAssertEqual(fields.map { $0["name"] as? String }, ["pin", "linked"], "linked fields are preserved")
    }

    func testNewItemJSONPerType() {
        var login = ItemDraft(type: .login, folderId: "f1")
        login.name = "Site"; login.username = "me"; login.password = ""; login.totp = "GEZDGNBVGY3TQOJQ"; login.uris = ["", "https://x.test"]
        let l = login.json()
        XCTAssertEqual(l["folderId"] as? String, "f1")
        XCTAssertEqual(l["reprompt"] as? Int, 0)
        let ld = l["login"] as! [String: Any]
        XCTAssertTrue(ld["password"] is NSNull, "empty string becomes null")
        XCTAssertEqual((ld["uris"] as! [[String: Any]]).count, 1, "blank URIs dropped")

        var note = ItemDraft(type: .secureNote); note.name = "N"; note.notes = "body"
        let n = note.json()
        XCTAssertEqual((n["secureNote"] as? [String: Any])?["type"] as? Int, 0)
        XCTAssertEqual(n["notes"] as? String, "body")

        var card = ItemDraft(type: .card); card.name = "C"; card.card.number = "4111"
        XCTAssertEqual((card.json()["card"] as? [String: Any])?["number"] as? String, "4111")

        var ident = ItemDraft(type: .identity); ident.name = "I"; ident.identity.firstName = "Ann"
        XCTAssertEqual((ident.json()["identity"] as? [String: Any])?["firstName"] as? String, "Ann")
    }

    func testValidation() {
        var d = ItemDraft()
        XCTAssertEqual(d.problem, .nameRequired)
        d.name = "x"
        XCTAssertNil(d.problem)
        d.totp = "not base32!"
        XCTAssertEqual(d.problem, .invalidTOTP)
        d.totp = "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ"
        XCTAssertNil(d.problem)
        d.type = .card; d.totp = "garbage" // TOTP only matters for logins
        XCTAssertNil(d.problem)
    }

    func testCloneStripsIdentityAndHistory() {
        let c = ItemDraft.cloneJSON(from: original, nameSuffix: " - Clone")
        XCTAssertNil(c["id"]); XCTAssertNil(c["revisionDate"]); XCTAssertNil(c["attachments"]); XCTAssertNil(c["passwordHistory"])
        XCTAssertEqual(c["name"] as? String, "Old - Clone")
        let login = c["login"] as! [String: Any]
        XCTAssertNil(login["fido2Credentials"])
        XCTAssertEqual(login["password"] as? String, "p")
    }

    func testRoundTripThroughDecoder() throws {
        var d = ItemDraft(type: .login); d.name = "RT"; d.username = "u"; d.password = "p"; d.uris = ["https://rt.test"]; d.favorite = true
        var json = d.json(); json["id"] = "new1"
        let item = try JSONDecoder().decode(VaultItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(item.name, "RT")
        XCTAssertEqual(item.login?.uris?.first?.uri, "https://rt.test")
        XCTAssertEqual(item.favorite, true)
        XCTAssertEqual(ItemDraft(item: item).username, "u")
    }
}

final class AuthenticatorKeyStorageTests: XCTestCase {
    func testFieldModeMovesKeyOutOfLoginTotp() throws {
        var d = ItemDraft(type: .login); d.name = "X"; d.totp = "GEZDGNBVGY3TQOJQ"
        d.fields = [CustomField(name: "PIN", value: "1", type: .text)]
        let plain = d.json()
        XCTAssertEqual((plain["login"] as? [String: Any])?["totp"] as? String, "GEZDGNBVGY3TQOJQ")

        let inField = try d.json(merging: nil, totpInField: true, transform: { "enc(\($0))" })
        XCTAssertTrue((inField["login"] as? [String: Any])?["totp"] is NSNull)
        let fields = try XCTUnwrap(inField["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.map { $0["name"] as? String }, ["enc(PIN)", "enc(VaultBar 2FA)"])
        XCTAssertEqual(fields.last?["value"] as? String, "enc(GEZDGNBVGY3TQOJQ)")
        XCTAssertEqual(fields.last?["type"] as? Int, 1, "stored as a hidden field")
    }

    func testItemReadsKeyFromEitherPlace() {
        let a = VaultItem(id: "1", type: .login, name: "a", login: LoginData(username: nil, password: nil, totp: "AAAA", uris: nil))
        let b = VaultItem(id: "2", type: .login, name: "b", login: LoginData(), fields: [CustomField(name: "vaultbar 2fa", value: "BBBB", type: .hidden)])
        XCTAssertEqual(a.authenticatorKey, "AAAA")
        XCTAssertEqual(b.authenticatorKey, "BBBB", "field name is matched case-insensitively")
        XCTAssertNil(VaultItem(id: "3", type: .login, name: "c").authenticatorKey)
        XCTAssertFalse(ItemDraft(item: b).fields.contains { TOTPStorage.isKeyField($0) })
        XCTAssertEqual(ItemDraft(item: b).totp, "BBBB")
    }

    func testImportMovesStorageFieldBackToKeyInput() throws {
        let json = #"{"encrypted":false,"folders":[],"items":[{"id":"1","type":1,"name":"X","login":{"username":"u","totp":null},"fields":[{"name":"VaultBar 2FA","value":"CCCC","type":1},{"name":"keep","value":"v","type":0}]}]}"#
        let plan = try BitwardenFile.parse(Data(json.utf8))
        XCTAssertEqual(plan.entries[0].draft.totp, "CCCC")
        XCTAssertEqual(plan.entries[0].draft.fields.map(\.name), ["keep"])
    }
}

final class SaveVerifierTests: XCTestCase {
    private func server(totp: String? = nil, notes: String? = nil) -> VaultItem {
        VaultItem(id: "1", type: .login, name: "Site", notes: notes, login: LoginData(username: "u", password: "p", totp: totp, uris: [LoginURI(uri: "https://a.test")]))
    }
    private func draft(totp: String = "", notes: String = "") -> ItemDraft {
        var d = ItemDraft(type: .login); d.name = "Site"; d.username = "u"; d.password = "p"; d.uris = ["https://a.test"]; d.totp = totp; d.notes = notes
        return d
    }

    func testIdenticalIsClean() {
        XCTAssertEqual(SaveVerifier.differences(draft: draft(totp: "K", notes: "n"), server: server(totp: "K", notes: "n")), [])
        XCTAssertEqual(SaveVerifier.differences(draft: draft(), server: server()), [], "empty and missing are the same")
    }

    func testReportsFieldNamesOnly() {
        XCTAssertEqual(SaveVerifier.differences(draft: draft(totp: ""), server: server(totp: "OLDKEY")), ["authenticator key"], "a clear that the server ignored")
        XCTAssertEqual(SaveVerifier.differences(draft: draft(totp: "NEW"), server: server(totp: nil)), ["authenticator key"])
        var d = draft(); d.password = "changed"; d.name = "Renamed"
        XCTAssertEqual(SaveVerifier.differences(draft: d, server: server()), ["name", "password"])
    }

    func testKeyInHiddenFieldCountsAsKept() {
        var s = server(); s.fields = [CustomField(name: TOTPStorage.fieldName, value: "K", type: .hidden)]
        XCTAssertEqual(SaveVerifier.differences(draft: draft(totp: "K"), server: s), [])
    }
}
