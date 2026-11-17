import SwiftUI
import VaultKit

/// Like the extension's "Account actions": the active account, the other accounts
/// (one login each, only one open at a time), Add account, Lock now, Log out.
struct AccountActionsView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { state.showAccounts = false; state.confirmLogoutAccount = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).handCursor()
                Text(t("acct.title")).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                AccountBadge(initials: state.accountInitials)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let active = state.activeAccountRow {
                        accountCard(active, trailing: AnyView(Image(systemName: "checkmark.circle").foregroundStyle(Theme.textPrimary)))
                    }
                    let others = state.accountRows.filter { !$0.isActive }
                    Text(t("acct.available")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).padding(.top, 6)
                    ForEach(others) { row in
                        accountCard(row, trailing: AnyView(Image(systemName: "lock").foregroundStyle(Theme.textSecondary)))
                            .handCursor()
                            .onTapGesture { Task { await state.switchAccount(to: row.id) } }
                    }
                    if others.isEmpty {
                        Text(t("acct.noAccounts")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    optionRow("plus", state.isDemo ? t("acct.demoAdd") : t("acct.add")) { state.beginAddAccount() }

                    Text(t("acct.options")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).padding(.top, 8)
                    if state.phase == .unlocked {
                        optionRow("lock", t("menu.lock")) { state.lockNow() }
                    }
                    if state.confirmLogoutAccount {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("settings.logoutConfirm")).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                            HStack(spacing: 8) {
                                Button(t("edit.cancel")) { state.confirmLogoutAccount = false }.buttonStyle(SecondaryButtonStyle()).handCursor()
                                Button(t("settings.logout")) { Task { await state.logout() } }.buttonStyle(DangerButtonStyle()).handCursor()
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.danger.opacity(0.5)))
                    } else if !state.isDemo {
                        optionRow("rectangle.portrait.and.arrow.right", t("settings.logout"), tint: Theme.danger) { state.confirmLogoutAccount = true }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func accountCard(_ row: AppState.AccountRow, trailing: AnyView) -> some View {
        HStack(spacing: 12) {
            Text(Account.initials(forEmail: row.email))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Circle().fill(Theme.avatarColor(for: row.email)))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.email).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(row.host).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                Text(row.isActive ? t("acct.active") : t("acct.locked"))
                    .font(.system(size: 12, weight: row.isActive ? .semibold : .regular).italic())
                    .foregroundStyle(row.isActive ? Color(nsColor: NSColor(hex: 0x3DDC84)) : Theme.textSecondary)
            }
            Spacer(minLength: 4)
            trailing.font(.system(size: 15))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
        .contentShape(Rectangle())
    }

    private func optionRow(_ icon: String, _ title: String, tint: Color = Theme.textPrimary, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint).frame(width: 22)
                Text(title).font(.system(size: 13.5)).foregroundStyle(tint)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }
}
