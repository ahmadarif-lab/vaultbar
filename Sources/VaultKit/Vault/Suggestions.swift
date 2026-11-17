import Foundation

/// What was in front when the popover opened: the app and, for a browser, the page.
public struct SuggestionContext: Equatable, Sendable {
    public var appName: String
    public var bundleID: String?
    /// The active tab's address, when the browser could tell.
    public var url: String?
    /// The focused window's title.
    public var windowTitle: String?

    public init(appName: String, bundleID: String? = nil, url: String? = nil, windowTitle: String? = nil) {
        self.appName = appName; self.bundleID = bundleID; self.url = url; self.windowTitle = windowTitle
    }

    public var isBrowser: Bool { bundleID.map(Suggestions.browserBundleIDs.contains) ?? false }
    public var host: String? { url.flatMap(Suggestions.host(of:)) }

    /// A short label for the section title: the site when known, else the app.
    public var label: String { host ?? appName }
}

/// Picks the vault items that fit the app or site in front, for one-step auto-type.
public enum Suggestions {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "org.mozilla.firefox",
    ]

    /// Lower-case host of a URL or a bare "example.com/path"; nil for IP-less junk and non-web schemes.
    public static func host(of raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") {
            let scheme = String(text[..<range.lowerBound])
            guard scheme == "http" || scheme == "https" else { return nil } // androidapp://, iosapp://, …
            text = String(text[range.upperBound...])
        }
        if let at = text.firstIndex(of: "@"), at < (text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex) {
            text = String(text[text.index(after: at)...]) // user:pass@host
        }
        let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        var host = String(text[..<end])
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) { host = String(host[..<colon]) }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return host
    }

    private static let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "go", "or", "sch", "web"]

    /// "mail.example.co.id" → "example.co.id". IP addresses stay whole.
    public static func baseDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        guard labels.count > 2 else { return host }
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let take = (tld.count == 2 && secondLevel.contains(second)) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// The best matches first (at most `limit`). Logins only.
    public static func match(_ entries: [VaultEntry], for context: SuggestionContext, limit: Int = 5) -> [VaultEntry] {
        let title = context.windowTitle?.lowercased() ?? ""
        let app = context.appName.lowercased()
        let host = context.host
        var scored: [(VaultEntry, Int)] = []
        for entry in entries where entry.type == .login {
            var best = 0
            let hosts = entry.uris.compactMap(host(of:))
            if let host {
                for h in hosts {
                    if h == host { best = max(best, 100) }
                    else if baseDomain(h) == baseDomain(host) { best = max(best, 80) }
                }
            }
            if best == 0 {
                let name = entry.name.lowercased()
                if !context.isBrowser, app.count >= 3, name == app || name.contains(app) || app.contains(name) && name.count >= 3 { best = 60 }
                if !title.isEmpty {
                    // The page title often carries the site's name ("Sign in · GitHub").
                    if name.count >= 3, title.contains(name) { best = max(best, 50) }
                    for h in hosts {
                        let main = baseDomain(h).split(separator: ".").first.map(String.init) ?? ""
                        if main.count >= 4, title.contains(main) { best = max(best, 40) }
                    }
                }
            }
            if best > 0 { scored.append((entry, best)) }
        }
        scored.sort { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }
        return scored.prefix(limit).map(\.0)
    }
}
