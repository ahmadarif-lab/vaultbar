import XCTest
@testable import VaultKit

final class ImportExportTests: XCTestCase {
    private let sample = """
    {"encrypted": false,
     "folders": [{"id":"f1","name":"Work"},{"id":"f2","name":"Empty folder"}],
     "items": [
       {"id":"a","type":1,"name":"Site","notes":"n","favorite":true,"folderId":"f1","reprompt":0,
        "login":{"username":"u","password":"p","totp":"GEZDGNBVGY3TQOJQ","uris":[{"uri":"https://a.test"},{"uri":"https://b.test","match":1}],
                 "fido2Credentials":[{"credentialId":"x"}]},
        "fields":[{"name":"pin","value":"1","type":1},{"name":"linked","value":null,"type":3,"linkedId":100}],
        "passwordHistory":[{"password":"old","lastUsedDate":"2025-01-01T00:00:00.000Z"}]},
       {"id":"b","type":2,"name":"Note","notes":"text","secureNote":{"type":0}},
       {"id":"c","type":3,"name":"Card","card":{"cardholderName":"A","number":"4111","expMonth":"1","expYear":"2030","code":"123"}},
       {"id":"d","type":4,"name":"Me","identity":{"firstName":"Ann","lastName":"Lee","email":"a@b.c"}},
       {"id":"e","type":1,"name":"Trash","deletedDate":"2026-01-01T00:00:00Z","login":{"username":"x"}},
       {"id":"g","type":9,"name":"Future type"},
       {"id":"h","type":1,"name":"","login":{"username":"nameless"},"organizationId":"org"}
     ]}
    """

    func testParseMapsEveryType() throws {
        let plan = try BitwardenFile.parse(Data(sample.utf8))
        XCTAssertEqual(plan.entries.count, 5) // site, note, card, identity, nameless org item (becomes personal)
        XCTAssertEqual(plan.trashed, 1)
        XCTAssertEqual(plan.unsupportedTypes, 1)
        XCTAssertEqual(plan.passkeys, 1)
        XCTAssertEqual(plan.folderNames, ["Work", "Empty folder"])

        let site = plan.entries[0]
        XCTAssertEqual(site.folderName, "Work")
        XCTAssertEqual(site.draft.uris, ["https://a.test", "https://b.test"])
        XCTAssertEqual(site.draft.totp, "GEZDGNBVGY3TQOJQ")
        XCTAssertTrue(site.draft.favorite)
        XCTAssertEqual(site.draft.fields.map(\.name), ["pin"], "linked fields are dropped")
        XCTAssertEqual(site.history, [PasswordHistoryEntry(password: "old", lastUsedDate: "2025-01-01T00:00:00.000Z")])
        XCTAssertEqual(plan.entries[2].draft.card.number, "4111")
        XCTAssertEqual(plan.entries[3].draft.identity.firstName, "Ann")
        XCTAssertEqual(plan.entries[4].draft.name, "(no name)")
        XCTAssertNil(plan.entries[4].draft.organizationId, "organization items import as personal")
    }

    func testRejectsEncryptedAndForeignFiles() {
        XCTAssertThrowsError(try BitwardenFile.parse(Data(#"{"encrypted":true,"passwordProtected":true,"data":"2.x|y|z"}"#.utf8))) {
            XCTAssertEqual($0 as? ImportError, .encrypted)
        }
        XCTAssertThrowsError(try BitwardenFile.parse(Data(#"{"hello":"world"}"#.utf8))) { XCTAssertEqual($0 as? ImportError, .notBitwardenExport) }
        XCTAssertThrowsError(try BitwardenFile.parse(Data("not json".utf8)))
    }

    func testPrepareSkipsExactDuplicatesAndReusesFolders() throws {
        let plan = try BitwardenFile.parse(Data(sample.utf8))
        let existing = VaultSnapshot(
            items: [VaultItem(id: "x", type: .login, name: "site", notes: nil, login: LoginData(username: "u", password: "p", totp: "GEZDGNBVGY3TQOJQ", uris: [LoginURI(uri: "https://a.test")]))],
            folders: [VaultFolder(id: "F", name: "Work")])
        // identical except notes ("n") -> not a duplicate
        var (request, report) = BitwardenFile.prepare(plan, existing: existing)
        XCTAssertEqual(report.duplicates, 0)
        var same = existing; same.items[0].notes = "n"
        (request, report) = BitwardenFile.prepare(plan, existing: same)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(report.added, 4)
        XCTAssertEqual(request.newFolders, ["Empty folder"], "an existing folder is reused, not duplicated")
        XCTAssertEqual(request.existingFolderIDs["Work"], "F")
        XCTAssertEqual(report.foldersCreated, 1)
    }

    func testExportRoundTripsThroughParse() throws {
        let snapshot = DemoSession.snapshot
        let data = try BitwardenFile.export(items: snapshot.items, folders: snapshot.folders)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(root["encrypted"] as? Bool, false)
        let items = root["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, snapshot.items.filter { $0.organizationId == nil }.count, "organization items are not part of a personal export")
        XCTAssertNotNil(items.first?["revisionDate"])

        let plan = try BitwardenFile.parse(data)
        XCTAssertEqual(plan.entries.count, items.count)
        let github = try XCTUnwrap(plan.entries.first { $0.draft.name == "GitHub" })
        XCTAssertEqual(github.draft.username, "demo@example.com")
        XCTAssertEqual(github.draft.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(github.folderName, "Dev")
        XCTAssertTrue(github.draft.favorite)
        let card = try XCTUnwrap(plan.entries.first { $0.draft.type == .card })
        XCTAssertEqual(card.draft.card.expYear, "2029")
        // importing our own export into the same vault is a no-op
        let (_, report) = BitwardenFile.prepare(plan, existing: snapshot)
        XCTAssertEqual(report.added + report.duplicates, plan.entries.count)
        XCTAssertGreaterThan(report.duplicates, 0)
    }

    func testRealisticExportShapeWithoutOptionalKeys() throws {
        // Same shape as a real extension export: no match key, null totp, extra metadata keys, passkey list empty.
        let json = #"{"encrypted":false,"folders":[],"items":[{"passwordHistory":[],"revisionDate":"2026-01-01T00:00:00.000Z","creationDate":"2026-01-01T00:00:00.000Z","deletedDate":null,"id":"1","organizationId":null,"folderId":null,"type":1,"reprompt":0,"name":"X","notes":null,"favorite":false,"login":{"fido2Credentials":[],"uris":[{"uri":"https://x.test"}],"username":"u","password":"p","totp":null},"collectionIds":null}]}"#
        let plan = try BitwardenFile.parse(Data(json.utf8))
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.passkeys, 0, "an empty passkey list is not a passkey")
        XCTAssertEqual(plan.entries[0].draft.totp, "")
        XCTAssertEqual(plan.entries[0].draft.notes, "")
    }
}
