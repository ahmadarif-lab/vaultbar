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

/// Live code + countdown ring. Click copies.
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
                            .font(.system(size: large ? 19 : 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(urgent ? Theme.warning : Theme.textPrimary)
                            .lineLimit(1).fixedSize()
                    }
                    TOTPRing(fraction: totp.fractionRemaining(at: now), urgent: urgent, size: large ? 22 : 18)
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
    var placeholder: String = t("search.placeholder")
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: $text)
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


// MARK: Shared building blocks (extension-style layout)

/// Opens http(s) links only; anything else (androidapp://, file://…) is ignored.
func openableURL(_ raw: String) -> URL? {
    let text = raw.contains("://") ? raw : "https://" + raw
    guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }
}

/// Full-width dropdown label (Folder / Type), like the extension's selects.
struct SelectChip: View {
    let icon: String
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            Text(title).lineLimit(1).font(.system(size: 13)).foregroundStyle(active ? Theme.accent : Theme.textPrimary)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.accentSoft : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Theme.accent.opacity(0.5) : Theme.stroke))
        .contentShape(Rectangle())
    }
}

struct TabBar: View {
    let state: AppState

    /// SF Symbol names (normal, selected). Spelled out: not every symbol has a ".fill" twin.
    static func symbols(_ tab: AppState.Tab) -> (normal: String, selected: String) {
        switch tab {
        case .vault: return ("lock.shield", "lock.shield.fill")
        case .generator: return ("arrow.triangle.2.circlepath", "arrow.triangle.2.circlepath.circle.fill")
        case .authenticator: return ("clock.badge.checkmark", "clock.badge.checkmark.fill")
        case .settings: return ("gearshape", "gearshape.fill")
        }
    }

    private func label(_ tab: AppState.Tab) -> String {
        switch tab {
        case .vault: return t("tab.vault")
        case .generator: return t("tab.generator")
        case .authenticator: return t("tab.2fa")
        case .settings: return t("tab.settings")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                let symbols = Self.symbols(tab)
                let active = state.tab == tab
                Button { state.tab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: active ? symbols.selected : symbols.normal)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 17, weight: .regular))
                            .frame(height: 20)
                        Text(label(tab)).font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    }
                    .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

struct CheckRow: View {
    let title: String
    @Binding var isOn: Bool
    var mono = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                Text(title).font(.system(size: 13, design: mono ? .monospaced : .default)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NumberStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            Spacer()
            HStack(spacing: 0) {
                IconButton(systemName: "minus", size: 11) { value = max(range.lowerBound, value - 1) }
                Text("\(value)").font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary).frame(minWidth: 28)
                IconButton(systemName: "plus", size: 11) { value = min(range.upperBound, value + 1) }
            }
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        }
    }
}

/// A rounded bordered card that groups form rows.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.stroke))
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
    }
}

struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                Button { selection = value } label: {
                    Text(title).font(.system(size: 12.5, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? Theme.accent : Theme.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selection == value ? Theme.accentSoft : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }
}

/// Initials in a round badge, the header's account menu.
struct AccountBadge: View {
    let initials: String
    var body: some View {
        Text(initials)
            .font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color(nsColor: NSColor(hex: 0x7C3AED))))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var hint: String?
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.textSecondary)
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
