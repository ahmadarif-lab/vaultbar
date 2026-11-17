import AppKit
import SwiftUI
import VaultKit

struct ItemDetailView: View {
    let state: AppState
    let entry: VaultEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { state.closeDetail() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text(t("detail.back")).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                IconButton(systemName: "pencil", help: t("menu.edit")) { state.beginEdit(entry) }
                MoreMenu(state: state, entry: entry, includeView: false)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            HStack(spacing: 12) {
                Avatar(entry: entry, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    if let sub = entry.subtitle { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(entry.detailSections()) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = section.titleKey {
                                Text(t(title).uppercased())
                                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                            }
                            ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                                if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 12) }
                                DetailFieldRow(state: state, entry: entry, field: field)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.stroke))
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DetailFieldRow: View {
    let state: AppState
    let entry: VaultEntry
    let field: DetailField
    @State private var revealed = false

    private var label: String { field.labelKey.map { t($0) } ?? field.literalLabel ?? "" }

    private var fieldURL: URL? {
        field.kind == .uri ? openableURL(field.value) : nil
    }

    var body: some View {
        Group {
            if field.kind == .totp, let totp = entry.totp {
                HStack {
                    Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TOTPBadge(totp: totp, large: true) { state.copyCode(entry) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        value
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 0) {
                        if field.kind == .secret {
                            IconButton(systemName: revealed ? "eye.slash" : "eye", help: revealed ? t("detail.hide") : t("detail.reveal")) { revealed.toggle() }
                        }
                        if let url = fieldURL {
                            IconButton(systemName: "arrow.up.right.square", help: t("detail.open")) { NSWorkspace.shared.open(url) }
                        }
                        IconButton(systemName: "doc.on.doc", help: t("detail.copy")) { state.copyField(field.value) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        if field.kind == .secret && !revealed {
            Text(String(repeating: "•", count: min(max(field.value.count, 8), 14)))
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textPrimary)
        } else {
            Text(field.value)
                .font(.system(size: 13, design: field.kind == .secret ? .monospaced : .default))
                .foregroundStyle(field.kind == .uri ? Theme.accent : Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(field.kind == .multiline ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
