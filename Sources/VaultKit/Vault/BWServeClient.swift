import Foundation

/// REST client for the local `bw serve` (Vault Management API).
public struct BWServeClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // never route localhost through a proxy
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    private struct Envelope<T: Decodable>: Decodable {
        var success: Bool
        var data: T?
        var message: String?
    }

    private struct ListData<T: Decodable>: Decodable { var data: [Lossy<T>] }
    private struct Template: Decodable { var template: StatusTemplate }
    private struct StatusTemplate: Decodable { var status: String }

    /// Drops an item that fails to decode instead of failing the whole list.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private func request(_ method: String, _ path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if method == "POST" {
            req.httpBody = Data("{}".utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw VaultError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw VaultError.http(http.statusCode) }
        return data
    }

    /// "locked" / "unlocked" / "unauthenticated".
    public func state() async throws -> String {
        let data = try await request("GET", "status")
        let env = try JSONDecoder().decode(Envelope<Template>.self, from: data)
        guard let s = env.data?.template.status else { throw VaultError.badResponse }
        return s
    }

    private func list<T: Decodable>(_ path: String, as: T.Type) async throws -> [T] {
        let data = try await request("GET", path)
        let env = try JSONDecoder().decode(Envelope<ListData<T>>.self, from: data)
        guard env.success, let list = env.data else { throw VaultError.commandFailed(env.message ?? "Request failed.") }
        return list.data.compactMap(\.value)
    }

    public func snapshot() async throws -> VaultSnapshot {
        async let items = list("list/object/items", as: VaultItem.self)
        async let folders = list("list/object/folders", as: VaultFolder.self)
        async let orgs = list("list/object/organizations", as: VaultOrganization.self)
        return try await VaultSnapshot(items: items, folders: folders, organizations: orgs)
    }

    public func sync() async throws {
        let data = try await request("POST", "sync")
        let env = try JSONDecoder().decode(Envelope<Empty>.self, from: data)
        guard env.success else { throw VaultError.commandFailed(env.message ?? "Sync failed.") }
    }

    public func lock() async {
        _ = try? await request("POST", "lock")
    }

    private struct Empty: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
