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
