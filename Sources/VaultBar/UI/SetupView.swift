import AppKit
import Observation
import SwiftUI
import VaultKit

/// Maps an error to text the user can act on.
@MainActor
func describe(_ error: Error) -> String {
    switch error as? VaultError {
    case .invalidPassword: return t("lock.wrongPassword")
    case .invalidTwoFactorCode: return t("verify.invalidCode")
    case .captchaRequired: return t("error.captcha")
    case .network(let m): return t("error.network", m)
    case .server(let m): return m
    case .some(let e): return e.errorDescription ?? t("error.generic")
    case nil: return t("error.generic")
    }
}

@MainActor @Observable
final class SetupModel {
    enum Step { case email, password, verify, finish }
    enum Kind: Int { case us, eu, selfHosted }

    var step: Step = .email
    var kind: Kind = .us
    var selfURL = ""
    var email = AppDefaults.store.string(forKey: "rememberedEmail") ?? ""
    var rememberEmail = AppDefaults.store.string(forKey: "rememberedEmail") != nil
    var password = ""
    var useAPIKey = false
    var clientID = ""
    var clientSecret = ""

    // Verification step
    var challenge: TwoFactorChallenge?
    var provider: TwoFactorProvider = .authenticator
    var code = ""
    var needsNewDeviceCode = false
    var notice: String?

    var busy = false
    var error: String?
    var enableTouchID = true
    var enableLoginItem = true

    private var login: NativeLogin?
    private var session: NativeSession?
    private var pendingAccount: Account?
    private let state: AppState
    /// Logging in as an additional account: the server step shows Back.
    let isAdding: Bool
    var onCancel: (() -> Void)?

    init(state: AppState, adding: Bool = false) {
        self.state = state
        self.isAdding = adding
    }

    var touchIDAvailable: Bool { BiometricUnlock.isAvailable }

    private var server: ServerChoice? {
        switch kind {
        case .us: return .bitwardenUS
        case .eu: return .bitwardenEU
        case .selfHosted: return ServerChoice.normalizedSelfHosted(selfURL).map { .selfHosted($0) }
        }
    }

    /// "bitwarden.com", "bitwarden.eu" or the self-hosted host, for the "Accessing:" selector.
    var serverLabel: String {
        switch kind {
        case .us: return "bitwarden.com"
        case .eu: return "bitwarden.eu"
        case .selfHosted:
            return ServerChoice.normalizedSelfHosted(selfURL).flatMap { URL(string: $0)?.host } ?? t("setup.serverSelf")
        }
    }

    /// Email step -> password step.
    func continueFromEmail() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        guard mail.contains("@"), mail.count >= 3 else { error = t("login.emailInvalid"); return }
        guard server != nil else { error = t("setup.serverURLInvalid"); return }
        error = nil
        if rememberEmail { AppDefaults.store.set(mail, forKey: "rememberedEmail") }
        else { AppDefaults.store.removeObject(forKey: "rememberedEmail") }
        step = .password
    }

    // MARK: Login

    func submitLogin() async {
        guard let server else { return }
        let mail = email.trimmingCharacters(in: .whitespaces)
        guard !mail.isEmpty, !password.isEmpty, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        let account = Account(email: mail, server: server)
        pendingAccount = account
        let flow = NativeLogin(account: account, api: state.api(for: account), secrets: state.secrets)
        login = flow
        do {
            let apiKey = useAPIKey ? (id: clientID.trimmingCharacters(in: .whitespaces), secret: clientSecret.trimmingCharacters(in: .whitespaces)) : nil
            handle(try await flow.start(password: password, apiKey: apiKey))
        } catch {
            self.error = describe(error)
        }
    }

    private func handle(_ outcome: NativeLogin.Outcome) {
        code = ""
        switch outcome {
        case .success(let s):
            session = s
            step = .finish
        case .twoFactor(let c):
            challenge = c
            needsNewDeviceCode = false
            provider = c.supported.first ?? .authenticator
            step = .verify
            if c.supported.isEmpty { error = t("verify.unsupported") }
            else if provider == .email { Task { await resendCode(silent: true) } }
        case .newDevice:
            needsNewDeviceCode = true
            challenge = nil
            step = .verify
        }
    }

    // MARK: Verify

    var verifyHint: String {
        if needsNewDeviceCode { return t("verify.newDevice") }
        switch provider {
        case .email:
            if let hint = challenge?.emailHint { return t("verify.email", hint) }
            return t("verify.emailNoHint")
        case .yubikey: return t("verify.yubikey")
        default: return t("verify.authenticator")
        }
    }

    func changeProvider(_ p: TwoFactorProvider) {
        provider = p; code = ""; error = nil; notice = nil
        if p == .email { Task { await resendCode(silent: true) } }
    }

    func resendCode(silent: Bool = false) async {
        guard let login else { return }
        do {
            try await login.sendEmailCode()
            notice = silent ? t("verify.sent") : t("verify.sent")
        } catch {
            self.error = describe(error)
        }
    }

    func submitCode() async {
        guard let login, !code.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let outcome = needsNewDeviceCode ? try await login.submitNewDeviceCode(code) : try await login.submitTwoFactor(provider: provider, code: code)
            handle(outcome)
        } catch {
            self.error = describe(error)
            code = ""
        }
    }

    // MARK: Finish

    func finish() async {
        guard let session, var account = pendingAccount else { return }
        busy = true; error = nil
        defer { busy = false }
        var wantsTouchID = false
        if enableTouchID && touchIDAvailable {
            wantsTouchID = (try? BiometricUnlock.store(password: password, slot: account.biometricSlot)) != nil
        }
        account.touchID = wantsTouchID
        LoginItem.setEnabled(enableLoginItem)
        await state.completeLogin(account: account, session: session)
        self.session = nil; pendingAccount = nil; login = nil
        password = ""; code = ""; clientSecret = ""
    }

    func backToLogin() { step = .password; error = nil; notice = nil; code = "" }
}

struct SetupView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                Text(t("app.name")).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.textPrimary).padding(.top, 4)
            switch model.step {
            case .email: emailStep
            case .password: passwordStep
            case .verify: verifyStep
            case .finish: finishStep
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        switch model.step {
        case .finish: return t("setup.finishTitle")
        case .verify: return t("verify.title")
        default: return t("login.title")
        }
    }

    // MARK: Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2) {
                    Text(t("login.emailLabel")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Text("*").foregroundStyle(Theme.danger)
                }
                ThemedField(placeholder: "", text: $model.email) { model.continueFromEmail() }
            }
            if model.kind == .selfHosted {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("setup.serverURL")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    ThemedField(placeholder: "https://vault.example.com", text: $model.selfURL) { model.continueFromEmail() }
                }
            }
            CheckRow(title: t("login.remember"), isOn: $model.rememberEmail)
            Button(t("login.continue")) { model.continueFromEmail() }.buttonStyle(PrimaryButtonStyle()).handCursor()
            if model.isAdding {
                Button(t("setup.back")) { model.onCancel?() }
                    .buttonStyle(.plain).handCursor().font(.system(size: 12.5)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
            }
            Spacer(minLength: 20)
            serverMenu.frame(maxWidth: .infinity)
        }
    }

    /// "Accessing: bitwarden.com ⌄", like the extension.
    private var serverMenu: some View {
        HStack(spacing: 5) {
            Text(t("login.accessing")).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            Menu {
                Button(t("setup.serverUS")) { model.kind = .us }
                Button(t("setup.serverEU")) { model.kind = .eu }
                Button(t("setup.serverSelf")) { model.kind = .selfHosted }
            } label: {
                HStack(spacing: 3) {
                    Text(model.serverLabel).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).handCursor().menuIndicator(.hidden).fixedSize()
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(model.email).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Button(t("login.notYou")) { model.step = .email; model.error = nil; model.password = "" }
                    .buttonStyle(.plain).handCursor().font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
            Text(t("login.passwordLabel")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).padding(.top, 4)
            ThemedField(placeholder: "", text: $model.password, secure: true) { Task { await model.submitLogin() } }
            if model.useAPIKey {
                ThemedField(placeholder: t("setup.clientID"), text: $model.clientID)
                ThemedField(placeholder: t("setup.clientSecret"), text: $model.clientSecret, secure: true) { Task { await model.submitLogin() } }
                Text(t("setup.apiKeyNote")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(model.useAPIKey ? t("login.noAPIKey") : t("setup.useAPIKey")) { model.useAPIKey.toggle(); model.error = nil }
                .buttonStyle(.plain).handCursor().font(.system(size: 12)).foregroundStyle(Theme.accent)
            Spacer().frame(height: 4)
            Button(model.busy ? t("setup.loggingIn") : t("setup.login")) { Task { await model.submitLogin() } }
                .buttonStyle(PrimaryButtonStyle(enabled: !model.busy)).disabled(model.busy)
            Button(t("setup.back")) { model.step = .email; model.error = nil }
                .buttonStyle(.plain).handCursor().font(.system(size: 12.5)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = model.challenge, c.supported.count > 1 {
                SegmentedChoice(options: c.supported.map { ($0, providerName($0)) },
                                selection: Binding(get: { model.provider }, set: { model.changeProvider($0) }))
            }
            if model.challenge?.supported.isEmpty != true {
                Text(model.verifyHint).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ThemedField(placeholder: "123456", text: $model.code) { Task { await model.submitCode() } }
                    .font(.system(size: 18, design: .monospaced))
                if model.provider == .email && !model.needsNewDeviceCode {
                    Button(t("verify.resend")) { Task { await model.resendCode() } }
                        .buttonStyle(.plain).handCursor().font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 8) {
                Button(t("setup.back")) { model.backToLogin() }.buttonStyle(SecondaryButtonStyle()).handCursor()
                if model.challenge?.supported.isEmpty != true {
                    Button(model.busy ? "…" : t("verify.submit")) { Task { await model.submitCode() } }
                        .buttonStyle(PrimaryButtonStyle(enabled: !model.busy && !model.code.isEmpty)).disabled(model.busy || model.code.isEmpty)
                }
            }
        }
    }

    private func providerName(_ p: TwoFactorProvider) -> String {
        switch p {
        case .authenticator: return t("setup.method.authenticator")
        case .email: return t("setup.method.email")
        case .yubikey: return t("setup.method.yubikey")
        default: return "—"
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
