import AppKit
import Observation
import SwiftUI
import VaultKit

@MainActor @Observable
final class SetupModel {
    enum Step { case server, login, finish }
    enum Kind: Int { case us, eu, selfHosted }

    var step: Step = .server
    var kind: Kind = .us
    var selfURL = ""
    var email = ""
    var password = ""
    var twoFactorMethod = 0
    var twoFactorCode = ""
    var needsTwoFactor = false
    var useAPIKey = false
    var clientID = ""
    var clientSecret = ""
    var busy = false
    var error: String?
    var enableTouchID = true
    var enableLoginItem = true

    private var sessionKey: String?
    private let state: AppState
    var onFinished: (() -> Void)?

    init(state: AppState) { self.state = state }

    var touchIDAvailable: Bool { BiometricUnlock.isAvailable }

    private var server: ServerChoice? {
        switch kind {
        case .us: return .bitwardenUS
        case .eu: return .bitwardenEU
        case .selfHosted: return ServerChoice.normalizedSelfHosted(selfURL).map { .selfHosted($0) }
        }
    }

    func continueFromServer() async {
        guard let server, let cli = state.cli else {
            error = t("setup.serverURLInvalid")
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            // `bw config server` is refused while logged in.
            if let status = try? await cli.status(), status.state != .unauthenticated { try await cli.logout() }
            try await cli.configureServer(server)
            state.settings.server = server
            step = .login
        } catch {
            self.error = (error as? VaultError)?.errorDescription ?? t("error.generic")
        }
    }

    func login() async {
        guard let cli = state.cli else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let key: String
            if useAPIKey {
                key = try await cli.loginWithAPIKey(clientID: clientID, clientSecret: clientSecret, password: password)
            } else {
                let factor = needsTwoFactor && !twoFactorCode.isEmpty
                    ? BWCLI.TwoFactor(method: twoFactorMethod, code: twoFactorCode.trimmingCharacters(in: .whitespaces)) : nil
                key = try await cli.login(email: email.trimmingCharacters(in: .whitespaces), password: password, twoFactor: factor)
            }
            sessionKey = key
            state.settings.accountEmail = email.trimmingCharacters(in: .whitespaces)
            step = .finish
        } catch VaultError.twoFactorRequired {
            needsTwoFactor = true
            error = t("setup.twoFactorNeeded")
        } catch VaultError.invalidPassword {
            error = t("lock.wrongPassword")
        } catch {
            self.error = (error as? VaultError)?.errorDescription ?? t("error.generic")
        }
    }

    func finish() async {
        guard let sessionKey else { return }
        busy = true; error = nil
        defer { busy = false }
        if enableTouchID && touchIDAvailable && !state.isDemo {
            if (try? BiometricUnlock.store(password: password)) != nil { state.settings.touchIDEnabled = true }
        }
        LoginItem.setEnabled(enableLoginItem)
        do {
            try await state.finishLogin(sessionKey: sessionKey)
            self.sessionKey = nil
            password = ""; twoFactorCode = ""; clientSecret = ""
            onFinished?()
        } catch {
            self.error = (error as? VaultError)?.errorDescription ?? t("error.generic")
        }
    }
}

struct SetupView: View {
    @Bindable var model: SetupModel
    private let settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                Text(model.step == .finish ? t("setup.finishTitle") : t("setup.title"))
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            switch model.step {
            case .server: serverStep
            case .login: loginStep
            case .finish: finishStep
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 460, alignment: .topLeading)
        .background(Theme.background)
    }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("setup.server")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            VStack(spacing: 6) {
                choice(.us, t("setup.serverUS"))
                choice(.eu, t("setup.serverEU"))
                choice(.selfHosted, t("setup.serverSelf"))
            }
            if model.kind == .selfHosted {
                ThemedField(placeholder: t("setup.serverURL"), text: $model.selfURL)
                Text(t("setup.serverURLHint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer().frame(height: 6)
            Button(model.busy ? "…" : t("setup.next")) { Task { await model.continueFromServer() } }
                .buttonStyle(PrimaryButtonStyle(enabled: !model.busy)).disabled(model.busy)
        }
    }

    private func choice(_ kind: SetupModel.Kind, _ title: String) -> some View {
        Button { model.kind = kind } label: {
            HStack {
                Image(systemName: model.kind == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.kind == kind ? Theme.accent : Theme.textSecondary)
                Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10).fill(model.kind == kind ? Theme.accentSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.kind == kind ? Theme.accent.opacity(0.4) : Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.useAPIKey {
                ThemedField(placeholder: t("setup.clientID"), text: $model.clientID)
                ThemedField(placeholder: t("setup.clientSecret"), text: $model.clientSecret, secure: true)
            } else {
                ThemedField(placeholder: t("setup.email"), text: $model.email)
            }
            ThemedField(placeholder: t("setup.password"), text: $model.password, secure: true) { Task { await model.login() } }
            if model.needsTwoFactor && !model.useAPIKey {
                Picker(t("setup.twoFactorMethod"), selection: $model.twoFactorMethod) {
                    Text(t("setup.method.authenticator")).tag(0)
                    Text(t("setup.method.email")).tag(1)
                    Text(t("setup.method.yubikey")).tag(3)
                }
                ThemedField(placeholder: t("setup.twoFactor"), text: $model.twoFactorCode) { Task { await model.login() } }
            }
            Button(t("setup.useAPIKey")) { model.useAPIKey.toggle(); model.error = nil }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            Spacer().frame(height: 4)
            HStack(spacing: 8) {
                Button(t("setup.back")) { model.step = .server; model.error = nil }.buttonStyle(SecondaryButtonStyle())
                Button(model.busy ? t("setup.loggingIn") : t("setup.login")) { Task { await model.login() } }
                    .buttonStyle(PrimaryButtonStyle(enabled: !model.busy)).disabled(model.busy)
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.touchIDAvailable {
                Toggle(isOn: $model.enableTouchID) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("setup.touchIDOption")).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                        Text(t("setup.touchIDNote")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Toggle(isOn: $model.enableLoginItem) {
                Text(t("setup.loginItemOption")).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
            }
            Spacer().frame(height: 6)
            Button(model.busy ? "…" : t("setup.done")) { Task { await model.finish() } }
                .buttonStyle(PrimaryButtonStyle(enabled: !model.busy)).disabled(model.busy)
        }
    }
}
