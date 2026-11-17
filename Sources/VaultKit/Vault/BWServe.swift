import Foundation
import Darwin

/// Owns the `bw serve` child process. It is bound to 127.0.0.1 on a random
/// port, started only while the vault is unlocked, and stopped on lock/quit.
public final class BWServe: @unchecked Sendable {
    private let cli: BWCLI
    private let lock = NSLock()
    private var process: Process?
    public private(set) var baseURL: URL?

    public init(cli: BWCLI) { self.cli = cli }

    private static var pidFile: URL {
        BWCLI.defaultDataDirectory.deletingLastPathComponent().appendingPathComponent("serve.pid")
    }

    /// If the app crashed last time, its `bw serve` may still be listening.
    /// The pid is not a secret, so a pid file is fine; we still check that the
    /// pid really is a `bw ... serve` before signalling it.
    public static func killStaleServer() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let cmd = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        if cmd.contains("bw") && cmd.contains("serve") { kill(pid, SIGTERM) }
    }

    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    /// Starts `bw serve` with the session key in its environment and waits until it answers.
    public func start(session: String) async throws -> URL {
        stop()
        try cli.prepareDataDirectory()
        guard let port = Self.freePort() else { throw VaultError.serverNotReady }

        let p = Process()
        p.executableURL = cli.executable
        p.arguments = ["serve", "--hostname", "127.0.0.1", "--port", String(port)]
        p.environment = cli.environment(extra: ["BW_SESSION": session])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw VaultError.serverNotReady }
        try? String(p.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)

        let url = URL(string: "http://127.0.0.1:\(port)")!
        lock.withLock { process = p; baseURL = url }

        let client = BWServeClient(baseURL: url)
        for _ in 0..<60 { // up to ~15 s for node to come up
            if !p.isRunning { break }
            if (try? await client.state()) != nil { return url }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw VaultError.serverNotReady
    }

    public func stop() {
        lock.lock()
        let p = process
        process = nil
        baseURL = nil
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }
}
