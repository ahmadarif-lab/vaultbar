import Foundation

/// "Check for updates": asks GitHub for the latest published release. Nothing about the
/// user or the vault is sent; it is one anonymous GET.
public enum UpdateCheck {
    public static let repository = "ahmadarif-lab/vaultbar"

    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
        public init(version: String, url: URL) { self.version = version; self.url = url }
    }

    /// Reads `tag_name` / `html_url` from a GitHub "latest release" response.
    public static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repository)/releases")!
        return Release(version: normalized(tag), url: page)
    }

    /// "v1.2.3" and "1.2.3-beta" both become "1.2.3".
    static func normalized(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        if let dash = v.firstIndex(where: { $0 == "-" || $0 == "+" }) { v = String(v[..<dash]) }
        return v
    }

    /// Numeric, component-wise comparison ("0.10.0" is newer than "0.9.0").
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = normalized(latest).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalized(current).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The latest release, or nil when none has been published (HTTP 404).
    public static func fetchLatest(session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VaultBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status), let release = parse(data) else { throw VaultError.http(status) }
        return release
    }
}
