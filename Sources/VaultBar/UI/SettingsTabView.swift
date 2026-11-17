import SwiftUI
import VaultKit

// MARK: Themed settings controls

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary).padding(.horizontal, 2)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.stroke))
        }
    }
}

struct SettingsRowBox<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content.padding(.horizontal, 12).frame(minHeight: 42)
            if divider { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 12) }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var divider = true
    var body: some View {
        SettingsRowBox(divider: divider) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool
    var divider = true

    var body: some View {
        SettingsRowBox(divider: divider) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                    if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.accent).controlSize(.small)
            }
            .padding(.vertical, 6)
        }
    }
}

struct PickerRow<Value: Hashable>: View {
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Value
    var divider = true

    var body: some View {
        SettingsRowBox(divider: divider) {
            HStack {
                Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Menu {
                    ForEach(options.indices, id: \.self) { i in
                        Button(options[i].1) { selection = options[i].0 }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(options.first { $0.0 == selection }?.1 ?? "").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                }
                .menuStyle(.button).buttonStyle(.plain).handCursor().menuIndicator(.hidden).fixedSize()
            }
        }
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    var detail: String?
    var tint: Color = Theme.accent
    var divider = true
    let run: () -> Void

    var body: some View {
        SettingsRowBox(divider: divider) {
            Button(action: run) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
                    Text(title).font(.system(size: 13.5)).foregroundStyle(tint == Theme.accent ? Theme.textPrimary : tint)
                    Spacer()
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                }
                .frame(minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
        }
    }
}

// MARK: The tab

struct SettingsTabView: View {
    let state: AppState
    @Bindable var settings: AppSettings
    @State private var enablingTouchID = false
    @State private var touchPassword = ""
    @State private var touchError: String?
    @State private var confirmLogout = false
    @State private var loginItemOn = LoginItem.isEnabled
    @State private var exporting = false
    @State private var exportPassword = ""
    @State private var exportError: String?

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(state: state, title: t("tab.settings")) {
                if state.isDemo {
                    Text(t("demo.badge").uppercased())
                        .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentSoft))
                }
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if state.isDemo {
                        SettingsGroup(title: t("settings.account")) {
                            Text(t("settings.loginRealNote")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            Rectangle().fill(Theme.stroke).frame(height: 1)
                            ActionRow(icon: "person.crop.circle.badge.plus", title: t("settings.loginReal"), divider: false) { state.leaveDemo() }
                        }
                    } else {
                        accountGroup
                    }
                    vaultGroup
                    securityGroup
                    autoTypeGroup
                    generalGroup
                    dataGroup
                    aboutGroup
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { loginItemOn = LoginItem.isEnabled }
    }

    // MARK: Groups

    private var accountGroup: some View {
        SettingsGroup(title: t("settings.account")) {
            InfoRow(label: t("settings.email"), value: settings.accountEmail ?? "—")
            InfoRow(label: t("settings.server"), value: settings.server?.url ?? "—", divider: false)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ActionRow(icon: "person.2", title: t("acct.title")) { state.showAccounts = true }
            if confirmLogout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("settings.logoutConfirm")).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 8) {
                        Button(t("edit.cancel")) { confirmLogout = false }.buttonStyle(SecondaryButtonStyle()).handCursor()
                        Button(t("settings.logout")) { Task { await state.logout() } }.buttonStyle(DangerButtonStyle()).handCursor()
                    }
                }
                .padding(12)
            } else {
                ActionRow(icon: "rectangle.portrait.and.arrow.right", title: t("settings.logout"), tint: Theme.danger, divider: false) {
                    confirmLogout = true
                }
            }
        }
    }

    private var securityGroup: some View {
        SettingsGroup(title: t("settings.security")) {
            if BiometricUnlock.isAvailable {
                ToggleRow(title: t("settings.touchID"), isOn: Binding(
                    get: { state.touchIDActive || enablingTouchID },
                    set: { on in
                        if !on { Task { _ = await state.setTouchIDEnabled(false) }; enablingTouchID = false; touchPassword = ""; return }
                        touchError = nil
                        if state.isDemo { Task { touchError = await state.setTouchIDEnabled(true) } } // no real password to ask for
                        else { enablingTouchID = true }
                    }))
                if enablingTouchID && !state.touchIDActive {
                    SettingsRowBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ThemedField(placeholder: t("settings.touchIDEnterPassword"), text: $touchPassword, secure: true) { Task { await submitTouchID() } }
                                Button(t("settings.touchIDEnable")) { Task { await submitTouchID() } }
                                    .buttonStyle(CompactPrimaryStyle()).handCursor().disabled(touchPassword.isEmpty)
                            }
                            if let touchError { Text(touchError).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            ToggleRow(title: t("settings.lockOnClose"), note: t("settings.lockOnCloseNote"), isOn: $settings.lockOnClose)
            PickerRow(title: t("settings.autoLock"), options: [
                (1, t("settings.minutes", 1)), (5, t("settings.minutes", 5)), (15, t("settings.minutes", 15)),
                (30, t("settings.minutes", 30)), (60, t("settings.hours", 1)), (0, t("settings.never")),
            ], selection: $settings.autoLockMinutes)
            PickerRow(title: t("settings.clipboard"), options: [
                (10, t("settings.seconds", 10)), (30, t("settings.seconds", 30)), (60, t("settings.seconds", 60)),
                (120, t("settings.seconds", 120)), (0, t("settings.never")),
            ], selection: $settings.clipboardSeconds, divider: false)
        }
    }

    private var autoTypeGroup: some View {
        SettingsGroup(title: t("autotype.title")) {
            Text(t("autotype.note")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ToggleRow(title: t("autotype.enter"), isOn: $settings.autoTypeEnter)
            ActionRow(icon: AutoType.isTrusted ? "checkmark.shield" : "exclamationmark.shield", title: t("autotype.access"),
                      detail: AutoType.isTrusted ? t("autotype.allowed") : t("autotype.notAllowed"), divider: false) {
                if AutoType.isTrusted { AutoType.openPrivacySettings() } else { AutoType.promptForAccess() }
            }
        }
    }

    private var generalGroup: some View {
        SettingsGroup(title: t("settings.general")) {
            hotkeyRow
            ToggleRow(title: t("settings.loginItem"), isOn: Binding(
                get: { loginItemOn },
                set: { on in LoginItem.setEnabled(on); loginItemOn = LoginItem.isEnabled }))
            ToggleRow(title: t("settings.closeAfterCopy"), note: t("settings.closeAfterCopyNote"), isOn: $settings.closeAfterCopy)
            ToggleRow(title: t("settings.favicons"), note: t("settings.faviconsNote"), isOn: $settings.showFavicons)
            ToggleRow(title: t("settings.hideOrg"), isOn: $settings.hideOrgItems)
            PickerRow(title: t("settings.theme"), options: AppearanceChoice.allCases.map { ($0, t($0.titleKey)) },
                      selection: $settings.appearance)
            PickerRow(title: t("settings.language"), options: Language.allCases.map { ($0, $0.displayName) },
                      selection: $settings.language, divider: false)
        }
    }

    private var hotkeyRow: some View {
        SettingsRowBox {
            HStack(spacing: 6) {
                Text(t("settings.hotkey")).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                Button { state.isRecordingHotkey.toggle() } label: {
                    Text(state.isRecordingHotkey ? t("settings.hotkeyRecord")
                         : (settings.hotkeyEnabled ? HotkeyFormat.string(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers) : t("settings.hotkeyOff")))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(state.isRecordingHotkey ? Theme.accent : Theme.textPrimary)
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(state.isRecordingHotkey ? Theme.accentSoft : Theme.background))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(state.isRecordingHotkey ? Theme.accent : Theme.stroke))
                }
                .buttonStyle(.plain).handCursor()
                if settings.hotkeyEnabled && !state.isRecordingHotkey {
                    IconButton(systemName: "xmark.circle", help: t("settings.hotkeyOff")) { settings.hotkeyEnabled = false }
                }
                IconButton(systemName: "arrow.counterclockwise", help: t("settings.hotkeyReset")) {
                    state.isRecordingHotkey = false
                    settings.hotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
                    settings.hotkeyModifiers = AppSettings.defaultHotkeyModifiers
                    settings.hotkeyEnabled = true
                }
            }
        }
    }

    private var dataGroup: some View {
        SettingsGroup(title: t("data.title")) {
            ActionRow(icon: "square.and.arrow.down", title: t("data.import")) { Task { await state.pickAndImport() } }
            if let report = state.importReport { importReportCard(report) }
            if let error = state.importError {
                SettingsRowBox { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8) }
            }
            if exporting {
                SettingsRowBox(divider: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("data.exportWarning")).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            ThemedField(placeholder: t("data.exportPassword"), text: $exportPassword, secure: true) { Task { await runExport() } }
                            Button(t("data.exportConfirm")) { Task { await runExport() } }.buttonStyle(CompactPrimaryStyle()).handCursor().disabled(exportPassword.isEmpty)
                            Button(t("edit.cancel")) { exporting = false; exportPassword = ""; exportError = nil }.buttonStyle(SecondaryButtonStyle()).handCursor()
                        }
                        if let exportError { Text(exportError).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
                    }
                    .padding(.vertical, 10)
                }
            } else {
                ActionRow(icon: "square.and.arrow.up", title: t("data.export"), divider: false) { exporting = true; state.importReport = nil; state.importError = nil }
            }
        }
    }

    private func importReportCard(_ r: ImportReport) -> some View {
        SettingsRowBox {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: NSColor(hex: 0x2F9E6B)))
                    Text(t("data.importDone", r.added)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button(t("data.dismiss")) { state.importReport = nil }.buttonStyle(.plain).handCursor().font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                }
                if r.foldersCreated > 0 { detail(t("data.importFolders", r.foldersCreated)) }
                if r.duplicates > 0 { detail(t("data.importDuplicates", r.duplicates)) }
                if r.trashed > 0 { detail(t("data.importTrashed", r.trashed)) }
                if r.passkeys > 0 { detail(t("data.importPasskeys", r.passkeys)) }
            }
            .padding(.vertical, 8)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private func runExport() async {
        let password = exportPassword
        guard !password.isEmpty else { return }
        if let error = await state.exportVault(password: password) {
            exportError = error
        } else {
            exporting = false; exportPassword = ""; exportError = nil
        }
    }

    private var vaultGroup: some View {
        SettingsGroup(title: t("settingsTab.vault")) {
            ActionRow(icon: "folder", title: t("folders.title")) { state.folderError = nil; state.showFolders = true }
            ActionRow(icon: "arrow.triangle.2.circlepath", title: t("menu.sync"),
                      detail: state.isSyncing ? t("footer.syncing") : state.syncedText()) { Task { await state.sync() } }
            ActionRow(icon: "lock", title: t("menu.lock")) { state.lockNow() }
            ActionRow(icon: "power", title: t("menu.quit"), divider: false) { NSApp.terminate(nil) }
        }
    }

    private var aboutGroup: some View {
        SettingsGroup(title: t("about.title")) {
            ActionRow(icon: "info.circle", title: t("about.open"), detail: state.appVersion) { state.openAbout() }
            ActionRow(icon: "arrow.down.circle", title: t("about.check"), detail: updateDetail, divider: updateRelease != nil) {
                Task { await state.checkForUpdates() }
            }
            if let release = updateRelease {
                ActionRow(icon: "safari", title: t("about.download"), detail: release.version, divider: false) { NSWorkspace.shared.open(release.url) }
            }
        }
    }

    private var updateRelease: UpdateCheck.Release? {
        if case .available(let release) = state.updateStatus { return release }
        return nil
    }

    private var updateDetail: String? {
        switch state.updateStatus {
        case .idle: return nil
        case .checking: return t("about.checking")
        case .upToDate: return t("about.upToDate")
        case .noRelease: return t("about.noRelease")
        case .failed: return t("about.failed")
        case .available(let release): return t("about.available", release.version)
        }
    }

    private func submitTouchID() async {
        let password = touchPassword
        guard !password.isEmpty else { return }
        if let error = await state.setTouchIDEnabled(true, password: password) {
            touchError = error
        } else {
            enablingTouchID = false
            touchPassword = ""
            touchError = nil
        }
    }
}
