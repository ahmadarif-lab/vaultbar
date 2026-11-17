import XCTest
@testable import VaultKit

final class SearchTests: XCTestCase {
    private func entries() -> [VaultEntry] {
        let snapshot = VaultSnapshot(
            items: [
                VaultItem(id: "1", folderId: "f1", type: .login, name: "GitHub", login: LoginData(username: "arif@example.com", password: "x", totp: nil, uris: [LoginURI(uri: "https://github.com/login")])),
                VaultItem(id: "2", type: .login, name: "Café Bank", login: LoginData(username: "arif", password: "y", totp: "GEZDGNBVGY3TQOJQ", uris: [LoginURI(uri: "https://bank.example.org")])),
                VaultItem(id: "3", folderId: "f1", type: .secureNote, name: "Wi-Fi notes"),
            ],
            folders: [VaultFolder(id: "f1", name: "Work")]
        )
        return VaultEntry.build(from: snapshot)
    }

    private func ranked(_ q: String) -> [String] {
        entries().compactMap { e in e.score(for: q).map { (e.name, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func testSubstringAndPrefix() {
        XCTAssertEqual(ranked("git"), ["GitHub"])
        XCTAssertEqual(ranked("bank").first, "Café Bank")
    }

    func testSubsequence() {
        XCTAssertEqual(ranked("gthb"), ["GitHub"])
    }

    func testDiacriticsAndCase() {
        XCTAssertEqual(ranked("CAFE"), ["Café Bank"])
    }

    func testMatchesUsernameURIAndFolder() {
        XCTAssertTrue(ranked("example.com").contains("GitHub"))
        XCTAssertTrue(ranked("bank.example.org").contains("Café Bank"))
        XCTAssertEqual(Set(ranked("work")), ["GitHub", "Wi-Fi notes"])
    }

    func testAllTokensMustMatch() {
        XCTAssertEqual(ranked("git arif"), ["GitHub"])
        XCTAssertEqual(ranked("git zzzz"), [])
    }

    func testNamePrefixOutranksLaterMatch() {
        let snapshot = VaultSnapshot(items: [
            VaultItem(id: "a", type: .login, name: "My Mail"),
            VaultItem(id: "b", type: .login, name: "Mail Server"),
        ])
        let r = VaultEntry.build(from: snapshot).compactMap { e in e.score(for: "mail").map { (e.name, $0) } }.sorted { $0.1 > $1.1 }
        XCTAssertEqual(r.first?.0, "Mail Server")
    }

    func testEntryDerivedFields() {
        let e = entries()
        XCTAssertEqual(e.first { $0.id == "2" }?.totp?.digits, 6)
        XCTAssertNil(e.first { $0.id == "1" }?.totp)
        XCTAssertEqual(e.first { $0.id == "1" }?.folderName, "Work")
    }

    func testDecodesBitwardenJSONLeniently() throws {
        let json = """
        {"id":"abc","organizationId":null,"folderId":null,"type":1,"name":"X","notes":null,"favorite":true,
         "fields":[{"name":"pin","value":"1234","type":1}],
         "login":{"username":"u","password":"p","totp":null,"uris":[{"match":null,"uri":"https://x.test"}]},
         "revisionDate":"2026-01-01T00:00:00.000Z","collectionIds":[]}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(VaultItem.self, from: json)
        XCTAssertEqual(item.login?.uris?.first?.uri, "https://x.test")
        XCTAssertEqual(item.fields?.first?.type, .hidden)
        XCTAssertEqual(item.favorite, true)
    }
}
