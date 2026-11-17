import AppKit
import SwiftUI

struct LockView: View {
    let state: AppState
    @State private var password = ""
    @FocusState private var focused: Bool

    private var settings: AppSettings { state.settings }
    private var touchIDShown: Bool { state.touchIDActive }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 64, height: 64)
                Image(systemName: "lock.fill").font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.accent)
            }
            VStack(spacing: 3) {
                Text(t("lock.title")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let email = state.activeAccountRow?.email ?? settings.accountEmail {
                    Text(email).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            if touchIDShown {
                Button { Task { await state.unlockWithBiometrics() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "touchid").font(.system(size: 16))
                        Text(t("lock.touchID"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 40)
            }
            VStack(spacing: 8) {
                ThemedField(placeholder: t("lock.passwordPlaceholder"), text: $password, secure: true) { submit() }
                    .focused($focused)
                Button(state.isUnlocking ? t("lock.unlocking") : t("lock.unlock")) { submit() }
                    .buttonStyle(touchIDShown ? AnyButtonStyle(SecondaryButtonStyleFull()) : AnyButtonStyle(PrimaryButtonStyle(enabled: !password.isEmpty)))
                    .disabled(password.isEmpty || state.isUnlocking)
            }
            .padding(.horizontal, 40)
            if let message = state.lockMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.danger).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()
            HStack {
                Button(t("acct.switch")) { state.showAccounts = true }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                Spacer()
                Button(t("menu.quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .onAppear { focused = true }
        .onChange(of: state.focusToken) { _, _ in focused = true }
    }

    private func submit() {
        let value = password
        guard !value.isEmpty else { return }
        Task {
            await state.unlock(password: value)
            if state.phase == .unlocked { password = "" }
        }
    }
}

private struct SecondaryButtonStyleFull: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? Theme.hover : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct CLIMissingView: View {
    let state: AppState
    static let command = "brew install bitwarden-cli"

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "terminal").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
            Text(t("cli.title")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(t("cli.body")).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 36)
            Text(Self.command)
                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(t("cli.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                }.buttonStyle(SecondaryButtonStyle())
                Button(t("cli.check")) { Task { await state.recheckCLI() } }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
        }
    }
}

/// Login, inline in the popover (no separate window): first run, or "Add account".
struct NeedsSetupView: View {
    let state: AppState
    @State private var model: SetupModel

    init(state: AppState, adding: Bool = false) {
        self.state = state
        let m = SetupModel(state: state, adding: adding)
        if adding { m.onCancel = { [weak state] in state?.cancelAddAccount() } }
        _model = State(initialValue: m)
    }

    var body: some View { SetupView(model: model) }
}
