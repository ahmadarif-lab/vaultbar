import Foundation

/// Small secret storage (refresh tokens). The app backs it with the Keychain.
public protocol SecretStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String, for key: String)
    func remove(_ key: String)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? { lock.withLock { values[key] } }
    public func set(_ value: String, for key: String) { lock.withLock { values[key] = value } }
    public func remove(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// What must survive between launches to unlock offline: the KDF settings and the
/// user key *as the server stores it* (encrypted with the master password).
public struct AccountRecord: Codable, Equatable, Sendable {
    public var kdf: KDFConfig
    /// Salt for the master key when the server supplies one; otherwise the e-mail.
    public var kdfSalt: String?
    public var encryptedUserKey: String
    public var encryptedPrivateKey: String?
}

/// Per-account files: `record.json` and `sync.json`. Both hold only ciphertext, like
/// the official clients' caches; permissions are owner-only.
public struct AccountStorage: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var recordURL: URL { directory.appendingPathComponent("record.json") }
    private var syncURL: URL { directory.appendingPathComponent("sync.json") }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func loadRecord() -> AccountRecord? {
        (try? Data(contentsOf: recordURL)).flatMap { try? JSONDecoder().decode(AccountRecord.self, from: $0) }
    }

    public func saveRecord(_ record: AccountRecord) throws { try write(JSONEncoder().encode(record), to: recordURL) }

    public func loadSync() -> [String: Any]? {
        (try? Data(contentsOf: syncURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    public func saveSync(_ sync: [String: Any]) throws {
        try write(JSONSerialization.data(withJSONObject: sync), to: syncURL)
    }

    public func wipe() { try? FileManager.default.removeItem(at: directory) }
}
