import XCTest
@testable import VaultKit

final class AutoTypePlanTests: XCTestCase {
    func testLoginTypesUsernameTabPassword() {
        let steps = AutoTypePlan.steps(username: "me@example.test", password: "p@ss", code: nil, mode: .login, pressEnter: false)
        XCTAssertEqual(steps, [.text("me@example.test"), .tab, .text("p@ss")])
    }

    func testLoginWithOnlyOneFieldHasNoTab() {
        XCTAssertEqual(AutoTypePlan.steps(username: nil, password: "p", code: nil, mode: .login, pressEnter: false), [.text("p")])
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "", code: nil, mode: .login, pressEnter: false), [.text("u")])
        XCTAssertEqual(AutoTypePlan.steps(username: nil, password: nil, code: nil, mode: .login, pressEnter: true), [])
    }

    func testReturnIsAddedExceptAfterALoneUsername() {
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "p", code: nil, mode: .login, pressEnter: true), [.text("u"), .tab, .text("p"), .enter])
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "p", code: nil, mode: .password, pressEnter: true), [.text("p"), .enter])
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "p", code: "123456", mode: .code, pressEnter: true), [.text("123456"), .enter])
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "p", code: nil, mode: .username, pressEnter: true), [.text("u")])
    }

    func testSingleFieldModes() {
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "p", code: "654321", mode: .username, pressEnter: false), [.text("u")])
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: "p", code: "654321", mode: .code, pressEnter: false), [.text("654321")])
        XCTAssertEqual(AutoTypePlan.steps(username: "u", password: nil, code: nil, mode: .password, pressEnter: false), [])
    }

    func testChunksNeverSplitACharacter() {
        let text = "ab👩‍👩‍👧cd" + String(repeating: "é", count: 20) + "🔑"
        let chunks = AutoTypePlan.chunks(of: text, maxUnits: 8)
        XCTAssertEqual(chunks.joined(), text, "nothing lost or reordered")
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 8 || $0.count == 1 }, "pieces stay small unless one character is bigger")
        XCTAssertEqual(AutoTypePlan.chunks(of: "", maxUnits: 8), [])
        XCTAssertEqual(AutoTypePlan.chunks(of: "short"), ["short"])
    }
}
