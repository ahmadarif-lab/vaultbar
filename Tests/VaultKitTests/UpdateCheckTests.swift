import XCTest
@testable import VaultKit

final class UpdateCheckTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.10.0", than: "0.9.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.2.0-beta.1", than: "0.2.0"))
    }

    func testParsesGitHubRelease() {
        let json = #"{"tag_name":"v0.3.1","html_url":"https://github.com/ahmadarif-lab/vaultbar/releases/tag/v0.3.1","draft":false}"#
        let release = UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(release?.version, "0.3.1")
        XCTAssertEqual(release?.url.absoluteString, "https://github.com/ahmadarif-lab/vaultbar/releases/tag/v0.3.1")
        XCTAssertNil(UpdateCheck.parse(Data(#"{"message":"Not Found"}"#.utf8)))
    }
}
