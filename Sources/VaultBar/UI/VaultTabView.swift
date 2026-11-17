import AppKit
import SwiftUI
import VaultKit

/// Icon-only ⋮ button that opens the item menu.
struct MoreMenu: View {
    let state: AppState
    let entry: VaultEntry
    var includeView = true
    @State private var hovering = false

    var body: some View {
        Button {
            ItemMenu.popUp(ItemMenu.make(state: state, entry: entry, includeView: includeView))
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .help(t("row.more"))
        .onHover { hovering = $0 }
    }
}

struct VaultTabView: View {
    let state: AppState

    var body: some View {
        let rows = state.rows
        VStack(spacing: 0) {
            ScreenHeader(state: state, title: t("tab.vault")) {
                if state.isDemo {
                    Text(t("demo.badge").uppercased())
                        .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                Button { state.beginAdd() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text(t("header.add"))
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 13).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                }
                .buttonStyle(.plain).handCursor()
            }
            searchRow
            selects
            list(rows)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            SearchField(text: Binding(get: { state.query }, set: { state.query = $0 }), focusToken: state.focusToken)
            Menu {
                if state.showsOrgFilter {
                    Button(t("filter.allOrgs")) { state.orgFilter = .all }
                    Button(t("filter.personal")) { state.orgFilter = .personal }
                    ForEach(state.organizations) { o in Button(o.name) { state.orgFilter = .org(o.id) } }
                    Divider()
                }
                Button(t("filter.allFolders")) { state.clearFilters() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.orgFilter != .all ? Theme.accent : Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(state.orgFilter != .all ? Theme.accentSoft : Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
            }
            .menuStyle(.button).buttonStyle(.plain).handCursor().menuIndicator(.hidden).fixedSize()
            .help(t("filter.more"))
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private var selects: some View {
        HStack(spacing: 8) {
            Menu {
                Button(t("filter.allFolders")) { state.folderFilter = .all }
                Button(t("filter.noFolder")) { state.folderFilter = .none }
                Divider()
                ForEach(state.folders, id: \.id) { f in
                    Button(f.name) { if let id = f.id { state.folderFilter = .folder(id) } }
                }
            } label: { SelectChip(icon: "folder", title: folderTitle, active: state.folderFilter != .all) }
            .menuStyle(.button).buttonStyle(.plain).handCursor().menuIndicator(.hidden)

            Menu {
                Button(t("filter.allTypes")) { state.typeFilter = nil }
                Divider()
                ForEach(ItemType.allCases, id: \.self) { type in Button(typeName(type)) { state.typeFilter = type } }
            } label: { SelectChip(icon: "list.bullet", title: state.typeFilter.map(typeName) ?? t("filter.type"), active: state.typeFilter != nil) }
            .menuStyle(.button).buttonStyle(.plain).handCursor().menuIndicator(.hidden)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var folderTitle: String {
        switch state.folderFilter {
        case .all: return t("filter.folder")
        case .none: return t("filter.noFolder")
        case .folder(let id): return state.folders.first { $0.id == id }?.name ?? t("filter.folder")
        }
    }

    private func typeName(_ type: ItemType) -> String {
        switch type {
        case .login: return t("type.login")
        case .card: return t("type.card")
        case .identity: return t("type.identity")
        case .secureNote: return t("type.note")
        }
    }

    @ViewBuilder
    private func list(_ rows: [AppState.Row]) -> some View {
        if rows.isEmpty {
            EmptyState(icon: state.entries.isEmpty ? "tray" : "magnifyingglass",
                       title: state.entries.isEmpty ? t("empty.noItems") : t("empty.noResults"),
                       hint: state.entries.isEmpty ? nil : t("empty.noResultsHint"))
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(sectionOrder(rows), id: \.self) { section in
                            let group = rows.filter { $0.section == section }
                            SectionTitle(title: AppState.title(for: section), count: group.count)
                            ForEach(group) { row in
                                ItemRow(state: state, entry: row.entry, selected: state.selectedRowID == row.id)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity) // ScrollView collapses to 0 without an explicit frame
                .onChange(of: state.selectedRowID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private func sectionOrder(_ rows: [AppState.Row]) -> [AppState.ListSection] {
        var seen: [AppState.ListSection] = []
        for r in rows where !seen.contains(r.section) { seen.append(r.section) }
        return seen
    }
}

struct SectionTitle: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 10).padding(.bottom, 2).padding(.horizontal, 2)
    }
}

struct ItemRow: View {
    let state: AppState
    let entry: VaultEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(entry: entry, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if entry.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.warning) }
                    if let org = entry.organizationName {
                        Text(org).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accentSoft)).lineLimit(1)
                    }
                }
                if let sub = entry.subtitle {
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !ItemMenu.copyOptions(state: state, entry: entry).isEmpty {
                IconButton(systemName: "doc.on.doc", help: t("row.copy")) { ItemMenu.copyButtonPressed(state: state, entry: entry) }
            }
            MoreMenu(state: state, entry: entry)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accentSoft : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent.opacity(0.6) : Theme.stroke))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedRowID = "all-\(entry.id)"; state.openDetail(entry) }
    }
}

// MARK: 2FA tab

struct AuthenticatorTabView: View {
    let state: AppState

    var body: some View {
        let rows = state.rows
        VStack(spacing: 0) {
            ScreenHeader(state: state, title: t("tab.2fa"), showsAccount: false) {
                Text("\(rows.count)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                IconButton(systemName: "qrcode.viewfinder", help: t("qr.scan"), size: 16) { ItemMenu.popUpQRChoices(state: state) }
                Button { state.beginAddAuthenticator() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text(t("header.add"))
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 13).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                }
                .buttonStyle(.plain).handCursor()
            }
            SearchField(text: Binding(get: { state.query }, set: { state.query = $0 }), focusToken: state.focusToken, placeholder: t("twofa.search"))
                .padding(.horizontal, 14).padding(.bottom, 10)
            if rows.isEmpty {
                EmptyState(icon: "clock.badge.checkmark",
                           title: state.query.isEmpty ? t("twofa.empty") : t("empty.noResults"),
                           hint: state.query.isEmpty ? t("twofa.emptyHint") : t("empty.noResultsHint"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(rows) { row in
                                CodeRow(state: state, entry: row.entry, selected: state.selectedRowID == row.id)
                                    .id(row.id)
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: state.selectedRowID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
    }
}

struct CodeRow: View {
    let state: AppState
    let entry: VaultEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(entry: entry, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.totp?.issuer ?? entry.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(entry.subtitle ?? entry.name).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let totp = entry.totp { TOTPBadge(totp: totp, large: true) { state.copyCode(entry) } }
        }
        .padding(.horizontal, 10)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accentSoft : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent.opacity(0.6) : Theme.stroke))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedRowID = "authenticator-\(entry.id)"; state.copyCode(entry) }
    }
}
