import XCTest
@testable import VaultKit

final class DetailAndStringsTests: XCTestCase {
    func testLanguageTablesHaveSameKeys() {
        XCTAssertEqual(Set(Strings.en.keys), Set(Strings.id.keys))
    }

    func testPlaceholdersMatchBetweenLanguages() {
        for (key, en) in Strings.en {
            let id = Strings.id[key]!
            let a = en.components(separatedBy: "%").count
            let b = id.components(separatedBy: "%").count
            XCTAssertEqual(a, b, "format placeholders differ for \(key)")
        }
    }

    func testFallbackToKey() {
        XCTAssertEqual(Strings.text("does.not.exist", .id), "does.not.exist")
    }

    func testLoginDetailFieldsAndHiddenCustomField() {
        let snapshot = DemoSession.snapshot
        let router = VaultEntry.build(from: snapshot).first { $0.id == "d09" }!
        let sections = router.detailSections()
        let all = sections.flatMap(\.fields)
        XCTAssertEqual(all.first { $0.id == "password" }?.kind, .secret)
        XCTAssertEqual(all.first { $0.id == "uri0" }?.kind, .uri)
        XCTAssertEqual(all.first { $0.literalLabel == "Wi-Fi PIN" }?.kind, .secret)
        XCTAssertEqual(all.first { $0.literalLabel == "Location" }?.kind, .text)
        XCTAssertNotNil(all.first { $0.id == "notes" })
    }

    func testTOTPFieldOnlyWhenKeyIsValid() {
        let entries = VaultEntry.build(from: DemoSession.snapshot)
        XCTAssertTrue(entries.first { $0.id == "d01" }!.detailSections().flatMap(\.fields).contains { $0.kind == .totp })
        XCTAssertFalse(entries.first { $0.id == "d07" }!.detailSections().flatMap(\.fields).contains { $0.kind == .totp })
    }

    func testCardAndIdentityMapping() {
        let entries = VaultEntry.build(from: DemoSession.snapshot)
        let card = entries.first { $0.id == "d13" }!.detailSections().flatMap(\.fields)
        XCTAssertEqual(card.first { $0.id == "expiry" }?.value, "08 / 2029")
        XCTAssertEqual(card.first { $0.id == "number" }?.kind, .secret)
        let ident = entries.first { $0.id == "d14" }!.detailSections().flatMap(\.fields)
        XCTAssertEqual(ident.first { $0.id == "name" }?.value, "Demo User")
    }

    func testDemoVaultTOTPSecretsAllParse() {
        let withKey = DemoSession.snapshot.items.filter { $0.login?.totp != nil }
        XCTAssertGreaterThan(withKey.count, 5)
        for item in withKey { XCTAssertNotNil(TOTP(parsing: item.login!.totp!), item.name) }
    }

    func testSelfHostedURLNormalisation() {
        XCTAssertEqual(ServerChoice.normalizedSelfHosted("vault.example.com/"), "https://vault.example.com")
        XCTAssertEqual(ServerChoice.normalizedSelfHosted("http://localhost:8080"), "http://localhost:8080")
        XCTAssertNil(ServerChoice.normalizedSelfHosted("http://vault.example.com"))
        XCTAssertNil(ServerChoice.normalizedSelfHosted(""))
    }

    func testIconURLs() {
        XCTAssertEqual(ServerChoice.bitwardenUS.iconURL(forDomain: "github.com")?.absoluteString, "https://icons.bitwarden.net/github.com/icon.png")
        XCTAssertEqual(ServerChoice.selfHosted("https://v.example.com/").iconURL(forDomain: "a.com")?.absoluteString, "https://v.example.com/icons/a.com/icon.png")
    }
}

final class AccountTests: XCTestCase {
    func testInitials() {
        XCTAssertEqual(Account.initials(forEmail: "alice.anderson@example.test"), "AA")
        XCTAssertEqual(Account.initials(forEmail: "alice@example.com"), "AL")
        XCTAssertEqual(Account.initials(forEmail: "bob_smith@x.io"), "BS")
        XCTAssertEqual(Account.initials(forEmail: "123@x.io"), "?")
    }

    func testHostPerServer() {
        XCTAssertEqual(Account(email: "a@b.c", server: .bitwardenUS).host, "bitwarden.com")
        XCTAssertEqual(Account(email: "a@b.c", server: .bitwardenEU).host, "bitwarden.eu")
        XCTAssertEqual(Account(email: "a@b.c", server: .selfHosted("https://vault.example.com:8443/")).host, "vault.example.com")
    }

    func testEachAccountHasItsOwnDataFolder() {
        let a = Account(email: "a@b.c", server: .bitwardenUS)
        let b = Account(email: "b@b.c", server: .bitwardenUS)
        XCTAssertNotEqual(a.dataDirectory, b.dataDirectory)
        XCTAssertTrue(a.dataDirectory.path.hasSuffix("/VaultBar/accounts/\(a.id)"))
        XCTAssertNotEqual(a.biometricSlot, b.biometricSlot)
    }

    func testCodableRoundTrip() throws {
        let list = [Account(email: "a@b.c", server: .selfHosted("https://v.example"), touchID: true), Account(email: "b@b.c", server: .bitwardenEU)]
        let back = try JSONDecoder().decode([Account].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(back, list)
    }
}
