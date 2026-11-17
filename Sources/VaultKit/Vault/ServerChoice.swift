import Foundation

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
