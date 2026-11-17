import XCTest
@testable import VaultKit

/// Drives the real BWCLI / BWServe / BWServeClient code against a fake `bw`.
final class BWIntegrationTests: XCTestCase {
    private var dir: URL!
    private var cli: BWCLI!

    override func setUpWithError() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-bw")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vaultbar-test-\(UUID().uuidString)")
        cli = BWCLI(executable: fixture, dataDirectory: dir)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func argvLog() -> String { (try? String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)) ?? "" }

    func testStatusLoginUnlockLogout() async throws {
        var status = try await cli.status()
        XCTAssertEqual(status.state, .unauthenticated)

        try await cli.configureServer(.selfHosted("https://vault.example.test"))
        do { _ = try await cli.login(email: "me@example.com", password: "wrong", twoFactor: nil); XCTFail("should fail") }
        catch { XCTAssertEqual(error as? VaultError, .invalidPassword) }

        let key = try await cli.login(email: "me@example.com", password: "correct-horse", twoFactor: nil)
        XCTAssertEqual(key, "fake-session-key")
        status = try await cli.status()
        XCTAssertEqual(status.state, .locked)
        XCTAssertEqual(status.userEmail, "me@example.com")
        XCTAssertEqual(status.serverURL, "https://vault.example.test")

        do { _ = try await cli.unlock(password: "nope"); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .invalidPassword) }

        // Server config is refused while logged in, like the real CLI.
        do { try await cli.configureServer(.bitwardenEU); XCTFail() } catch {}

        try await cli.logout()
        let after = try await cli.status()
        XCTAssertEqual(after.state, .unauthenticated)
    }

    func testPasswordNeverAppearsInArguments() async throws {
        _ = try await cli.login(email: "me@example.com", password: "correct-horse", twoFactor: nil)
        _ = try await cli.unlock(password: "correct-horse")
        let log = argvLog()
        XCTAssertFalse(log.isEmpty)
        XCTAssertFalse(log.contains("correct-horse"), "master password leaked into argv")
        XCTAssertTrue(log.contains("--passwordenv VB_PW"))
    }

    func testTwoFactorRequiredIsClassified() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("needs2fa").path, contents: Data())
        do { _ = try await cli.login(email: "me@example.com", password: "correct-horse", twoFactor: nil); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .twoFactorRequired) }
        let key = try await cli.login(email: "me@example.com", password: "correct-horse", twoFactor: .init(method: 0, code: "123456"))
        XCTAssertEqual(key, "fake-session-key")
        XCTAssertTrue(argvLog().contains("--method 0 --code 123456"))
    }

    func testSessionServesVaultAndLockStopsServer() async throws {
        _ = try await cli.login(email: "me@example.com", password: "correct-horse", twoFactor: nil)
        let session = BWSession(cli: cli)
        try await session.unlock(password: "correct-horse")

        var snap = try await session.snapshot()
        XCTAssertEqual(snap.items.map(\.name).sorted(), ["Alpha", "Beta"], "malformed item must be dropped, not fatal")
        XCTAssertEqual(snap.folders.first?.name, "Work")
        let entries = VaultEntry.build(from: snap)
        XCTAssertNotNil(entries.first { $0.name == "Alpha" }?.totp)
        XCTAssertEqual(entries.first { $0.name == "Alpha" }?.folderName, "Work")

        try await session.sync()
        snap = try await session.snapshot()
        XCTAssertTrue(snap.items.contains { $0.name == "Added by sync" })

        await session.lock()
        do { _ = try await session.snapshot(); XCTFail("snapshot after lock must fail") }
        catch { XCTAssertEqual(error as? VaultError, .notLoggedIn) }
    }

    func testServeStopsAnsweringAfterStop() async throws {
        let serve = BWServe(cli: cli)
        let url = try await serve.start(session: "k")
        XCTAssertEqual(url.host, "127.0.0.1")
        let client = BWServeClient(baseURL: url)
        let state = try await client.state()
        XCTAssertEqual(state, "unlocked")
        serve.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        do { _ = try await client.state(); XCTFail("server should be gone") } catch {}
        XCTAssertFalse(serve.isRunning)
    }

    func testServeWithoutSessionReportsLocked() async throws {
        let serve = BWServe(cli: cli)
        let url = try await serve.start(session: "")
        defer { serve.stop() }
        // Empty BW_SESSION is falsy in the fake, like a missing key in the real CLI.
        let state = try await BWServeClient(baseURL: url).state()
        XCTAssertEqual(state, "locked")
    }
}
