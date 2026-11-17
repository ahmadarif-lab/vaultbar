import Foundation

/// The real vault session: unlocks through `bw unlock --raw`, then serves the
/// decrypted items from a local `bw serve` that lives only while unlocked.
public final class BWSession: VaultSession, @unchecked Sendable {
    public let cli: BWCLI
    private let serve: BWServe
    private let stateLock = NSLock()
    private var client: BWServeClient?

    public init(cli: BWCLI) {
        self.cli = cli
        self.serve = BWServe(cli: cli)
    }

    /// Adopts a session key obtained elsewhere (the login flow already has one).
    public func start(sessionKey: String) async throws {
        let url = try await serve.start(session: sessionKey)
        stateLock.withLock { client = BWServeClient(baseURL: url) }
    }

    public func unlock(password: String) async throws {
        let key = try await cli.unlock(password: password)
        try await start(sessionKey: key)
    }

    private var currentClient: BWServeClient {
        get throws {
            stateLock.lock(); defer { stateLock.unlock() }
            guard let client else { throw VaultError.notLoggedIn }
            return client
        }
    }

    public func lock() async {
        let c = try? currentClient
        if let c { await c.lock() }
        stateLock.withLock { client = nil }
        serve.stop()
        await cli.lock()
    }

    /// Synchronous kill used when the app quits.
    public func stopServeNow() { serve.stop() }

    public func sync() async throws { try await currentClient.sync() }

    public func snapshot() async throws -> VaultSnapshot { try await currentClient.snapshot() }

    public func save(_ draft: ItemDraft) async throws {
        let client = try currentClient
        if let id = draft.id {
            let raw = try await client.rawItem(id: id)
            try await client.updateItem(id: id, draft.json(merging: raw))
        } else {
            try await client.createItem(draft.json())
        }
    }

    public func clone(id: String, nameSuffix: String) async throws {
        let client = try currentClient
        let raw = try await client.rawItem(id: id)
        if let org = raw["organizationId"] as? String, !org.isEmpty { throw VaultError.organizationItem }
        try await client.createItem(ItemDraft.cloneJSON(from: raw, nameSuffix: nameSuffix))
    }

    public func delete(id: String) async throws {
        try await currentClient.deleteItem(id: id)
    }
}
