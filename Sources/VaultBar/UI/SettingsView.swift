import AppKit
import SwiftUI
import VaultKit

struct SettingsView: View {
    let state: AppState
    @Bindable var settings: AppSettings
    @State private var enablingTouchID = false
    @State private var touchPassword = ""
    @State private var touchError: String?
    @State private var confirmLogout = false
    @State private var recording = false
    @State private var monitor: Any?

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    var body: some View {
        Form {
            if state.isDemo {
                Section { Text(t("settings.demoNote")).foregroundStyle(.secondary) }
            } else {
                accountSection
            }
            securitySection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: state.isDemo ? 520 : 600)
        .onDisappear { stopRecording() }
    }

    private var accountSection: some View {
        Section(t("settings.account")) {
            LabeledContent(t("settings.server"), value: settings.server?.url ?? "—")
            LabeledContent(t("settings.email"), value: settings.accountEmail ?? "—")
            Button(t("settings.logout"), role: .destructive) { confirmLogout = true }
                .confirmationDialog(t("settings.logoutConfirm"), isPresented: $confirmLogout) {
                    Button(t("settings.logout"), role: .destructive) { Task { await state.logout() } }
                }
        }
    }

    private var securitySection: some View {
        Section(t("settings.security")) {
            if BiometricUnlock.isAvailable && !state.isDemo {
                Toggle(t("settings.touchID"), isOn: Binding(
                    get: { settings.touchIDEnabled || enablingTouchID },
                    set: { on in
                        if on { enablingTouchID = true; touchError = nil }
                        else { BiometricUnlock.remove(); settings.touchIDEnabled = false; enablingTouchID = false }
                    }))
                if enablingTouchID && !settings.touchIDEnabled {
                    HStack {
                        SecureField(t("settings.touchIDEnterPassword"), text: $touchPassword)
                            .onSubmit { Task { await enableTouchID() } }
                        Button(t("settings.touchIDEnable")) { Task { await enableTouchID() } }
                            .disabled(touchPassword.isEmpty)
                    }
                    if let touchError { Text(touchError).font(.caption).foregroundStyle(.red) }
                }
            }
            Picker(t("settings.autoLock"), selection: $settings.autoLockMinutes) {
                ForEach([1, 5, 15, 30, 60], id: \.self) { m in
                    Text(m >= 60 ? t("settings.hours", m / 60) : t("settings.minutes", m)).tag(m)
                }
                Text(t("settings.never")).tag(0)
            }
            Picker(t("settings.clipboard"), selection: $settings.clipboardSeconds) {
                ForEach([10, 30, 60, 120], id: \.self) { s in Text(t("settings.seconds", s)).tag(s) }
                Text(t("settings.never")).tag(0)
            }
        }
    }

    private var generalSection: some View {
        Section(t("settings.general")) {
            LabeledContent(t("settings.hotkey")) {
                HStack {
                    Button(recording ? t("settings.hotkeyRecord") : (settings.hotkeyEnabled
                           ? HotkeyFormat.string(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
                           : t("settings.hotkeyOff"))) { toggleRecording() }
                    if settings.hotkeyEnabled {
                        Button(t("settings.hotkeyOff")) { settings.hotkeyEnabled = false }
                    }
                    Button(t("settings.hotkeyReset")) {
                        settings.hotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
                        settings.hotkeyModifiers = AppSettings.defaultHotkeyModifiers
                        settings.hotkeyEnabled = true
                    }
                }
            }
            Toggle(t("settings.loginItem"), isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.setEnabled($0) }))
            Toggle(isOn: $settings.showFavicons) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("settings.favicons"))
                    Text(t("settings.faviconsNote")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(t("settings.hideOrg"), isOn: $settings.hideOrgItems)
            Picker(t("settings.language"), selection: $settings.language) {
                ForEach(Language.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    private func enableTouchID() async {
        guard let cli = state.cli, !touchPassword.isEmpty else { return }
        do {
            _ = try await cli.unlock(password: touchPassword) // verifies the password before storing it
            try BiometricUnlock.store(password: touchPassword)
            settings.touchIDEnabled = true
            enablingTouchID = false
            touchPassword = ""
            touchError = nil
        } catch VaultError.invalidPassword {
            touchError = t("lock.wrongPassword")
        } catch {
            touchError = t("error.generic")
        }
    }

    // MARK: Hotkey recording

    private func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotkeyFormat.carbonModifiers(from: event.modifierFlags)
            if event.keyCode == 53 { stopRecording(); return nil } // esc cancels
            guard mods != 0 else { return nil } // needs at least one modifier
            settings.hotkeyKeyCode = UInt32(event.keyCode)
            settings.hotkeyModifiers = mods
            settings.hotkeyEnabled = true
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
