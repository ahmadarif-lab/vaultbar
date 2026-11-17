import XCTest
@testable import VaultKit

final class SuggestionsTests: XCTestCase {
    private func entry(_ id: String, _ name: String, uris: [String] = [], type: ItemType = .login) -> VaultEntry {
        let item = VaultItem(id: id, type: type, name: name, login: LoginData(username: "u", password: "p", totp: nil, uris: uris.map { LoginURI(uri: $0) }))
        return VaultEntry(item: item, folders: [:], organizations: [:])
    }

    func testHostParsing() {
        XCTAssertEqual(Suggestions.host(of: "https://www.GitHub.com/login?x=1"), "github.com")
        XCTAssertEqual(Suggestions.host(of: "github.com/orgs"), "github.com")
        XCTAssertEqual(Suggestions.host(of: "http://user:pw@host.example.org:8443/p"), "host.example.org")
        XCTAssertEqual(Suggestions.host(of: "http://192.168.1.1:8080/admin"), "192.168.1.1")
        XCTAssertNil(Suggestions.host(of: "androidapp://com.example"))
        XCTAssertNil(Suggestions.host(of: "localhost"))
        XCTAssertNil(Suggestions.host(of: ""))
    }

    func testBaseDomain() {
        XCTAssertEqual(Suggestions.baseDomain("mail.google.com"), "google.com")
        XCTAssertEqual(Suggestions.baseDomain("accounts.example.co.id"), "example.co.id")
        XCTAssertEqual(Suggestions.baseDomain("example.com"), "example.com")
        XCTAssertEqual(Suggestions.baseDomain("10.0.0.5"), "10.0.0.5")
    }

    func testMatchesBySiteAndPrefersTheExactHost() {
        let entries = [
            entry("1", "GitHub", uris: ["https://github.com/login"]),
            entry("2", "Gist", uris: ["https://gist.github.com"]),
            entry("3", "GitLab", uris: ["https://gitlab.com"]),
            entry("4", "Card", uris: [], type: .card),
        ]
        let context = SuggestionContext(appName: "Google Chrome", bundleID: "com.google.Chrome", url: "https://github.com/settings", windowTitle: "Settings")
        XCTAssertEqual(Suggestions.match(entries, for: context).map(\.name), ["GitHub", "Gist"])
    }

    func testMatchesANativeAppByName() {
        let entries = [entry("1", "Slack", uris: ["https://slack.com"]), entry("2", "Zoom", uris: ["https://zoom.us"])]
        let context = SuggestionContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(Suggestions.match(entries, for: context).map(\.name), ["Slack"])
    }

    func testFallsBackToTheWindowTitleWhenTheBrowserGivesNoURL() {
        let entries = [entry("1", "Bank Mantap", uris: ["https://ib.example.co.id"]), entry("2", "Dropbox", uris: ["https://dropbox.com"])]
        let context = SuggestionContext(appName: "Firefox", bundleID: "org.mozilla.firefox", windowTitle: "Dropbox - Sign in")
        XCTAssertEqual(Suggestions.match(entries, for: context).map(\.name), ["Dropbox"])
    }

    func testUnrelatedBrowserPageSuggestsNothing() {
        let entries = [entry("1", "GitHub", uris: ["https://github.com"])]
        let context = SuggestionContext(appName: "Safari", bundleID: "com.apple.Safari", url: "https://news.example.org/today", windowTitle: "Today")
        XCTAssertTrue(Suggestions.match(entries, for: context).isEmpty)
    }

    func testAShortAppNameDoesNotMatchEverything() {
        let entries = [entry("1", "Notion", uris: [])]
        XCTAssertTrue(Suggestions.match(entries, for: SuggestionContext(appName: "Go", bundleID: "x.go")).isEmpty)
    }
}
