import Foundation

public struct CLIResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
}

public enum ServerChoice: Sendable, Equatable, Codable {
    case bitwardenUS
    case bitwardenEU
    case selfHosted(String)

    public var url: String {
        switch self {
        case .bitwardenUS: return "https://bitwarden.com"
        case .bitwardenEU: return "https://bitwarden.eu"
        case .selfHosted(let u): return u
        }
    }

    /// Where the vault's own icon service lives (favicons, decision 3).
    public func iconURL(forDomain domain: String) -> URL? {
        switch self {
        case .bitwardenUS, .bitwardenEU:
            return URL(string: "https://icons.bitwarden.net/\(domain)/icon.png")
        case .selfHosted(let base):
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            return URL(string: "\(trimmed)/icons/\(domain)/icon.png")
        }
    }

    /// Validates a user-typed self-hosted URL; https required except for localhost.
    public static func normalizedSelfHosted(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let comps = URLComponents(string: text), let host = comps.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard comps.scheme == "https" || (comps.scheme == "http" && local) else { return nil }
        var out = text
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

public struct CLIStatus: Sendable, Equatable {
    public enum State: String, Sendable { case unauthenticated, locked, unlocked }
    public var state: State
    public var serverURL: String?
    public var userEmail: String?
}

/// Thin wrapper around the official `bw` binary. Secrets only ever travel in
/// the child's environment (`VB_PW`, `BW_SESSION`), never in argv, where
/// `ps` would show them.
public struct BWCLI: Sendable {
    public let executable: URL
    public let dataDirectory: URL

    public init(executable: URL, dataDirectory: URL = BWCLI.defaultDataDirectory) {
        self.executable = executable
        self.dataDirectory = dataDirectory
    }

    /// VaultBar keeps its own CLI state so logging in or out here never
    /// touches a `bw` login the user may already have.
    public static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultBar", isDirectory: true)
            .appendingPathComponent("bw", isDirectory: true)
    }

    /// Where an account's `bw` state lives. The first account of the early single-account
    /// builds ("default") keeps the original folder, so nobody has to log in again.
    public static func dataDirectory(forAccount id: String) -> URL {
        let base = defaultDataDirectory.deletingLastPathComponent()
        if id == Account.legacyID { return defaultDataDirectory }
        return base.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("bw", isDirectory: true)
    }

    public static var searchPath: String {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (extra + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public static func locate() -> URL? {
        let fm = FileManager.default
        for dir in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("bw")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func environment(extra: [String: String]) -> [String: String] {
        let real = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": Self.searchPath,
            "HOME": real["HOME"] ?? NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": real["TMPDIR"] ?? "/tmp",
            "BITWARDENCLI_APPDATA_DIR": dataDirectory.path,
            "BW_NOINTERACTION": "true",
            "BITWARDENCLI_DEBUG": "false",
            "NODE_NO_WARNINGS": "1",
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }

    func prepareDataDirectory() throws {
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func run(_ arguments: [String], env: [String: String] = [:], timeout: TimeInterval = 90) async throws -> CLIResult {
        try prepareDataDirectory()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(extra: env)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try process.run() } catch {
                    continuation.resume(throwing: VaultError.commandFailed("Could not start bw: \(error.localizedDescription)"))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: CLIResult(
                    stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    status: process.terminationStatus
                ))
            }
        }
    }

    // MARK: Commands

    public func version() async -> String? {
        guard let r = try? await run(["--version"], timeout: 20), r.status == 0 else { return nil }
        return r.stdout
    }

    public func status() async throws -> CLIStatus {
        let r = try await run(["status"], timeout: 30)
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["status"] as? String, let state = CLIStatus.State(rawValue: raw)
        else { throw VaultError.commandFailed(Self.cleaned(r.stderr.isEmpty ? r.stdout : r.stderr)) }
        return CLIStatus(state: state, serverURL: obj["serverUrl"] as? String, userEmail: obj["userEmail"] as? String)
    }

    /// `bw config server` only works while logged out.
    public func configureServer(_ server: ServerChoice) async throws {
        let r = try await run(["config", "server", server.url], timeout: 30)
        guard r.status == 0 else { throw VaultError.commandFailed(Self.cleaned(r.stderr.isEmpty ? r.stdout : r.stderr)) }
    }

    public struct TwoFactor: Sendable {
        /// 0 authenticator app, 1 email, 3 YubiKey (bw's `--method` values).
        public var method: Int
        public var code: String
        public init(method: Int, code: String) { self.method = method; self.code = code }
    }

    /// Email + master password login. Returns the session key.
    public func login(email: String, password: String, twoFactor: TwoFactor?) async throws -> String {
        var args = ["login", email, "--passwordenv", "VB_PW", "--raw"]
        if let twoFactor { args += ["--method", String(twoFactor.method), "--code", twoFactor.code] }
        let r = try await run(args, env: ["VB_PW": password])
        guard r.status == 0, !r.stdout.isEmpty else { throw Self.classify(r) }
        return r.stdout
    }

    /// API key login (client id/secret), then an unlock with the master password.
    public func loginWithAPIKey(clientID: String, clientSecret: String, password: String) async throws -> String {
        let r = try await run(["login", "--apikey"], env: ["BW_CLIENTID": clientID, "BW_CLIENTSECRET": clientSecret])
        guard r.status == 0 else { throw Self.classify(r) }
        return try await unlock(password: password)
    }

    /// Returns the session key; the password is passed only via the child's environment.
    public func unlock(password: String) async throws -> String {
        let r = try await run(["unlock", "--passwordenv", "VB_PW", "--raw"], env: ["VB_PW": password])
        guard r.status == 0, !r.stdout.isEmpty else { throw Self.classify(r) }
        return r.stdout
    }

    public func lock() async {
        _ = try? await run(["lock"], timeout: 20)
    }

    public func logout() async throws {
        let r = try await run(["logout"], timeout: 30)
        if r.status != 0, !r.stderr.lowercased().contains("not logged in") {
            throw VaultError.commandFailed(Self.cleaned(r.stderr))
        }
    }

    // MARK: Error mapping

    static func classify(_ r: CLIResult) -> VaultError {
        let text = (r.stderr.isEmpty ? r.stdout : r.stderr)
        let lower = text.lowercased()
        if lower.contains("invalid master password") || lower.contains("username or password is incorrect") {
            return .invalidPassword
        }
        if lower.contains("two-step") || lower.contains("two step") || lower.contains("code is required")
            || lower.contains("verification code") || lower.contains("2fa") {
            return .twoFactorRequired
        }
        if lower.contains("not logged in") { return .notLoggedIn }
        return .commandFailed(cleaned(text))
    }

    static func cleaned(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.isEmpty ? "bw failed." : line
    }
}
