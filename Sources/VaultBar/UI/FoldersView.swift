import SwiftUI
import VaultKit

/// Manage folders (add, rename, delete), inline in the popover like the extension's "Folders".
struct FoldersView: View {
    let state: AppState
    @State private var newName = ""
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var deletingID: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { close() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).handCursor()
                Text(t("folders.title")).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 8) {
                ThemedField(placeholder: t("folders.name"), text: $newName) { add() }
                Button(t("folders.add")) { add() }
                    .buttonStyle(PrimaryButtonStyle()).handCursor().disabled(busy)
            }
            .padding(.horizontal, 14)

            if let error = state.folderError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    if state.folders.isEmpty {
                        Text(t("folders.empty")).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).padding(.top, 20)
                    }
                    ForEach(state.folders) { folder in row(folder) }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func row(_ folder: VaultFolder) -> some View {
        let id = folder.id ?? folder.name
        VStack(alignment: .leading, spacing: 8) {
            if renamingID == id {
                HStack(spacing: 8) {
                    ThemedField(placeholder: t("folders.name"), text: $renameText) { Task { await rename(folder) } }
                    Button(t("edit.save")) { Task { await rename(folder) } }.buttonStyle(PrimaryButtonStyle()).handCursor().disabled(busy)
                    Button(t("edit.cancel")) { renamingID = nil; state.folderError = nil }.buttonStyle(SecondaryButtonStyle()).handCursor()
                }
            } else if deletingID == id {
                Text(t("folders.deleteConfirm", folder.name)).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(t("edit.cancel")) { deletingID = nil }.buttonStyle(SecondaryButtonStyle()).handCursor()
                    Button(t("folders.delete")) { Task { busy = true; await state.deleteFolder(folder); busy = false; deletingID = nil } }
                        .buttonStyle(DangerButtonStyle()).handCursor().disabled(busy)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Theme.textSecondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(t("folders.items", state.itemCount(inFolder: folder.id))).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    IconButton(systemName: "pencil", help: t("folders.rename")) {
                        renamingID = id; renameText = folder.name; deletingID = nil; state.folderError = nil
                    }
                    IconButton(systemName: "trash", help: t("folders.delete"), tint: Theme.danger) {
                        deletingID = id; renamingID = nil; state.folderError = nil
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
    }

    private func add() {
        guard !busy else { return }
        Task {
            busy = true
            if await state.addFolder(newName) { newName = "" }
            busy = false
        }
    }

    private func rename(_ folder: VaultFolder) async {
        busy = true
        if await state.renameFolder(folder, to: renameText) { renamingID = nil }
        busy = false
    }

    private func close() { state.showFolders = false; state.folderError = nil }
}
