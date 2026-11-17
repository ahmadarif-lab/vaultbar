import AppKit
import SwiftUI
import VaultKit

// MARK: Avatar and favicons

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage?] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral // memory only: a disk cache would leak the site list
        c.urlCache = nil
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    func image(forDomain domain: String, server: ServerChoice?) async -> NSImage? {
        if let hit = cache[domain] { return hit }
        guard let server, let url = server.iconURL(forDomain: domain), !inFlight.contains(domain) else { return nil }
        inFlight.insert(domain)
        defer { inFlight.remove(domain) }
        let image: NSImage?
        if let (data, response) = try? await session.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            image = NSImage(data: data)
        } else {
            image = nil
        }
        cache[domain] = .some(image)
        return image
    }
}

struct Avatar: View {
    let entry: VaultEntry
    var size: CGFloat = 34
    @State private var favicon: NSImage?
    private let settings = AppSettings.shared

    private var domain: String? {
        guard settings.showFavicons, entry.type == .login, let raw = entry.uris.first else { return nil }
        let text = raw.contains("://") ? raw : "https://" + raw
        guard let host = URL(string: text)?.host, host.contains(".") else { return nil }
        return host
    }

    private var symbol: String? {
        switch entry.type {
        case .card: return "creditcard.fill"
        case .identity: return "person.text.rectangle.fill"
        case .secureNote: return "note.text"
        case .login: return nil
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Theme.avatarColor(for: entry.name))
            if let favicon {
                Image(nsImage: favicon).resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.14)
                    .background(RoundedRectangle(cornerRadius: size * 0.28).fill(.white))
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(String(entry.name.first.map { String($0).uppercased() } ?? "?"))
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .task(id: domain) {
            guard let domain else { favicon = nil; return }
            favicon = await IconCache.shared.image(forDomain: domain, server: settings.server)
        }
    }
}

// MARK: TOTP

struct TOTPRing: View {
    let fraction: Double
    let urgent: Bool
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(urgent ? Theme.warning : Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Live code + countdown ring. Click copies. Previews the next code in the last 5 s.
struct TOTPBadge: View {
    let totp: TOTP
    var large = false
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let now = context.date
            let left = totp.remaining(at: now)
            let urgent = left <= 5
            Button(action: onCopy) {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(totp.displayCode(at: now))
                            .font(.system(size: large ? 22 : 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(urgent ? Theme.warning : Theme.textPrimary)
                        if urgent {
                            Text("\(t("row.next")) \(TOTP.grouped(totp.nextCode(at: now)))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    TOTPRing(fraction: totp.fractionRemaining(at: now), urgent: urgent, size: large ? 24 : 18)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("row.copyCode"))
            .onHover { hovering = $0 }
        }
    }
}

// MARK: Search field and chips

struct SearchField: View {
    @Binding var text: String
    var focusToken: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextField(t("search.placeholder"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: focused ? 1.5 : 1))
        .onAppear { focused = true }
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}

struct ChipLabel: View {
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(active ? Theme.accentSoft : Theme.surface))
        .overlay(Capsule().stroke(active ? Theme.accent.opacity(0.35) : Theme.stroke))
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12).padding(.bottom, 4)
    }
}
