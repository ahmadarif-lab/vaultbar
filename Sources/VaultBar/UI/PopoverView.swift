import SwiftUI
import VaultKit

enum PopoverMetrics {
    static let width: CGFloat = 380
    static let height: CGFloat = 540
}

struct PopoverView: View {
    let state: AppState

    var body: some View {
        ZStack {
            Theme.background
            switch state.phase {
            case .checking:
                ProgressView().controlSize(.small)
            case .cliMissing:
                CLIMissingView(state: state)
            case .needsSetup:
                NeedsSetupView(state: state)
            case .locked:
                LockView(state: state)
            case .unlocked:
                if let entry = state.detailEntry {
                    ItemDetailView(state: state, entry: entry)
                } else {
                    VaultListView(state: state)
                }
            }
        }
        .frame(width: PopoverMetrics.width, height: PopoverMetrics.height)
    }
}

struct VaultListView: View {
    let state: AppState

    var body: some View {
        let rows = state.rows
        VStack(spacing: 0) {
            header
            chips
            Rectangle().fill(Theme.stroke).frame(height: 1)
            list(rows)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SearchField(text: Binding(get: { state.query }, set: { state.query = $0 }), focusToken: state.focusToken)
            IconButton(systemName: "lock.fill", help: t("menu.lock")) { state.lockNow() }
            Menu {
                Button(t("menu.sync")) { Task { await state.sync() } }
                Button(t("menu.settings")) { NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil) }
                Divider()
                Button(t("menu.quit")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Menu {
                Button(t("filter.allFolders")) { state.folderFilter = .all }
                Button(t("filter.noFolder")) { state.folderFilter = .none }
                Divider()
                ForEach(state.folders, id: \.id) { f in
                    Button(f.name) { if let id = f.id { state.folderFilter = .folder(id) } }
                }
            } label: {
                ChipLabel(title: folderTitle, active: state.folderFilter != .all)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Menu {
                Button(t("filter.allTypes")) { state.typeFilter = nil }
                Divider()
                ForEach(ItemType.allCases, id: \.self) { type in
                    Button(typeName(type)) { state.typeFilter = type }
                }
            } label: {
                ChipLabel(title: state.typeFilter.map(typeName) ?? t("filter.type"), active: state.typeFilter != nil)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            if state.showsOrgFilter {
                Menu {
                    Button(t("filter.allOrgs")) { state.orgFilter = .all }
                    Button(t("filter.personal")) { state.orgFilter = .personal }
                    Divider()
                    ForEach(state.organizations) { o in Button(o.name) { state.orgFilter = .org(o.id) } }
                } label: {
                    ChipLabel(title: orgTitle, active: state.orgFilter != .all)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            Spacer(minLength: 0)
            if state.hasActiveFilters {
                Button { state.folderFilter = .all; state.typeFilter = nil; state.orgFilter = .all } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var folderTitle: String {
        switch state.folderFilter {
        case .all: return t("filter.folder")
        case .none: return t("filter.noFolder")
        case .folder(let id): return state.folders.first { $0.id == id }?.name ?? t("filter.folder")
        }
    }

    private var orgTitle: String {
        switch state.orgFilter {
        case .all: return t("filter.org")
        case .personal: return t("filter.personal")
        case .org(let id): return state.organizations.first { $0.id == id }?.name ?? t("filter.org")
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
            VStack(spacing: 6) {
                Image(systemName: state.entries.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textSecondary)
                Text(state.entries.isEmpty ? t("empty.noItems") : t("empty.noResults"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if !state.entries.isEmpty {
                    Text(t("empty.noResultsHint")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(sectionOrder(rows), id: \.self) { section in
                            SectionHeader(title: AppState.title(for: section))
                            ForEach(rows.filter { $0.section == section }) { row in
                                ItemRow(state: state, entry: row.entry, selected: state.selectedRowID == row.id)
                                    .id(row.id)
                                    .onTapGesture { state.selectedRowID = row.id; state.openDetail(row.entry) }
                            }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
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

    private var footer: some View {
        HStack(spacing: 8) {
            Button { Task { await state.sync() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                    Text(state.isSyncing ? t("footer.syncing") : state.syncedText())
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(t("footer.syncNow"))
            Spacer()
            if state.isDemo {
                Text(t("demo.badge").uppercased())
                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accentSoft))
            } else {
                Text(t("footer.hints")).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

struct ItemRow: View {
    let state: AppState
    let entry: VaultEntry
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(entry: entry)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let org = entry.organizationName {
                        Text(org).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accentSoft)).lineLimit(1)
                    }
                }
                if let sub = entry.subtitle {
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let totp = entry.totp {
                TOTPBadge(totp: totp) { state.copyCode(entry) }
            } else if hovering || selected {
                HStack(spacing: 0) {
                    if entry.username != nil { IconButton(systemName: "person", help: t("row.copyUser")) { state.copyUsername(entry) } }
                    if entry.password != nil { IconButton(systemName: "key", help: t("row.copyPassword")) { state.copyPassword(entry) } }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Theme.accentSoft : (hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
