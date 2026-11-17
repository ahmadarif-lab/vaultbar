import SwiftUI
import VaultKit

enum PopoverMetrics {
    static let width: CGFloat = 380
    static let height: CGFloat = 580
}

struct PopoverView: View {
    let state: AppState

    var body: some View {
        ZStack {
            Theme.background
            switch state.phase {
            case .checking:
                ProgressView().controlSize(.small)
            case .needsSetup:
                NeedsSetupView(state: state)
            case .locked:
                if state.addingAccount { NeedsSetupView(state: state, adding: true) }
                else if state.showAccounts { AccountActionsView(state: state) }
                else { LockView(state: state) }
            case .unlocked:
                UnlockedView(state: state)
            }
        }
        .frame(width: PopoverMetrics.width, height: PopoverMetrics.height)
    }
}

/// Tabs (Vault, Generator, 2FA, Settings) or, while editing, the item editor.
struct UnlockedView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if state.addingAccount {
                    NeedsSetupView(state: state, adding: true)
                } else if state.showAccounts {
                    AccountActionsView(state: state)
                } else if state.showAbout {
                    AboutView(state: state)
                } else if state.showFolders {
                    FoldersView(state: state)
                } else if state.editor != nil {
                    ItemEditorView(state: state)
                } else {
                    switch state.tab {
                    case .vault:
                        if let entry = state.detailEntry { ItemDetailView(state: state, entry: entry) }
                        else { VaultTabView(state: state) }
                    case .generator: GeneratorTabView(state: state)
                    case .authenticator: AuthenticatorTabView(state: state)
                    case .settings: SettingsTabView(state: state)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.editor == nil && !state.showAccounts && !state.showFolders && !state.showAbout && !state.addingAccount { TabBar(state: state) }
        }
        .overlay { if let entry = state.pendingDeleteEntry { DeleteConfirm(state: state, entry: entry) } }
    }
}

struct DeleteConfirm: View {
    let state: AppState
    let entry: VaultEntry

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).onTapGesture { state.cancelDelete() }
            VStack(spacing: 12) {
                Image(systemName: "trash").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.danger)
                Text(t("delete.title")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(t("delete.body", entry.name)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(t("edit.cancel")) { state.cancelDelete() }.buttonStyle(SecondaryButtonStyle()).handCursor()
                    Button(t("delete.confirm")) { Task { await state.confirmDelete() } }
                        .buttonStyle(DangerButtonStyle()).handCursor()
                }
            }
            .padding(20)
            .frame(width: 310)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: NSColor(hex: 0xD1242F)).opacity(configuration.isPressed ? 0.75 : 1)))
    }
}
