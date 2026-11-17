import AppKit
import Observation
import VaultKit

@MainActor @Observable
final class AppState {
    enum Phase { case checking, needsSetup, locked, unlocked }
    enum Tab: CaseIterable { case vault, generator, authenticator, settings }
    enum ListSection: String { case favorites, authenticator, all, results }
    enum FolderFilter: Hashable { case all, none, folder(String) }
    enum OrgFilter: Hashable { case all, personal, org(String) }

    struct Row: Identifiable {
        let id: String
        let section: ListSection
        let entry: VaultEntry
    }

    let settings = AppSettings.shared
    let isDemo: Bool

    var phase: Phase = .checking
    private(set) var entries: [VaultEntry] = []
    private(set) var folders: [VaultFolder] = []
    private(set) var organizations: [VaultOrganization] = []

    var query = "" { didSet { if query != oldValue { selectFirst() } } }
    var folderFilter: FolderFilter = .all { didSet { selectFirst() } }
    var typeFilter: ItemType? { didSet { selectFirst() } }
    var orgFilter: OrgFilter = .all { didSet { selectFirst() } }
    var selectedRowID: String?
    var detailEntryID: String?

    var tab: Tab = .vault {
        didSet {
            guard tab != oldValue else { return }
            detailEntryID = nil
            query = ""
            selectFirst()
            focusToken += 1
        }
    }

    // Editing, deleting
    var editor: ItemDraft?
    var editorError: String?
    /// Opening the editor from the 2FA tab: the authenticator-key field takes focus first.
    var editorFocusesKey = false
    var isSaving = false
    var pendingDeleteID: String?

    let generator = GeneratorModel()

    /// True while the Settings tab is waiting for the user to press a new global hotkey.
    var isRecordingHotkey = false { didSet { settings.onHotkeyChanged?() } }

    var lastSync: Date?
    var importReport: ImportReport?
    var importError: String?
    /// While a file panel is up, closing the popover must not hide the whole app (that would hide the panel).
    var keepAppActive = false

    // Accounts screen / add-account flow
    var showAccounts = false
    var showFolders = false
    var showAbout = false
    var serverVersion: String?
    var folderError: String?
    var updateStatus: UpdateStatus = .idle
    var addingAccount = false
    var confirmLogoutAccount = false
    /// Demo only: which of the two fake accounts is active.
    var demoActiveAccount = "demo-1"
    /// Demo-only Touch ID switch (in memory; real mode uses `settings.touchIDEnabled`).
    var demoTouchID = false
    var isSyncing = false
    var isUnlocking = false
    var lockMessage: String?
    /// Bumped every time the popover opens so the search field refocuses.
    var focusToken = 0

    @ObservationIgnored let secrets: SecretStore = KeychainSecretStore()
    @ObservationIgnored private var session: VaultSession?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var distributedObservers: [NSObjectProtocol] = []

    // Hooks wired by the status bar controller / app delegate.
    @ObservationIgnored var showToast: ((String) -> Void)?
    @ObservationIgnored var closePopover: (() -> Void)?
    @ObservationIgnored var openSetup: (() -> Void)?
    @ObservationIgnored var requestShowPopover: (() -> Void)?
    @ObservationIgnored var lockChanged: ((Bool) -> Void)?

    init(demo: Bool) {
        isDemo = demo
        // Timers live here, not in a popover `.task`: those die when the
        // popover closes (MenuBarExtra/popover lesson, PRD §6.4).
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoLockTick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.phase == .unlocked { Task { await self?.sync(silent: true) } } }
        })
        installLockObservers()
    }

    // MARK: Bootstrap

    func bootstrap() async {
        if isDemo {
            session = DemoSession()
            await loadVault()
            lastSync = Date()
            phase = .unlocked
            lockChanged?(false)
            return
        }
        // Accounts without a stored key record (e.g. from the first, bw-based builds) cannot be unlocked.
        for account in settings.accounts where AccountStorage(directory: account.dataDirectory).loadRecord() == nil { forget(account) }
        if settings.activeAccount == nil {
            phase = .needsSetup
            openSetup?()
        } else {
            phase = .locked
            lockChanged?(true)
        }
    }

    /// Stable id of this installation, sent to the server as the device identifier.
    var deviceInfo: DeviceInfo {
        let key = "deviceIdentifier"
        let id = AppDefaults.store.string(forKey: key) ?? {
            let new = UUID().uuidString
            AppDefaults.store.set(new, forKey: key)
            return new
        }()
        return DeviceInfo(identifier: id)
    }

    func api(for account: Account) -> BitwardenAPI { BitwardenAPI(server: account.server, device: deviceInfo) }

    /// Removes an account from the list, with its cached vault, refresh token and Touch ID item.
    private func forget(_ account: Account) {
        BiometricUnlock.remove(slot: account.biometricSlot)
        NativeSession.forget(account, secrets: secrets)
        settings.accounts.removeAll { $0.id == account.id }
        if settings.activeAccountID == account.id { settings.activeAccountID = settings.accounts.first?.id }
    }

    // MARK: Unlock / lock

    func unlock(password: String, fromBiometric: Bool = false) async {
        guard !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        lockMessage = nil
        defer { isUnlocking = false }
        do {
            if isDemo {
                try await session?.unlock(password: password)
            } else {
                guard let account = settings.activeAccount else { phase = .needsSetup; return }
                let s = NativeSession(account: account, secrets: secrets, api: api(for: account))
                try await s.unlock(password: password) // works offline from the encrypted cache
                session = s
            }
            await enterUnlocked()
        } catch VaultError.invalidPassword {
            lockMessage = t("lock.wrongPassword")
            if fromBiometric {
                BiometricUnlock.remove(slot: biometricSlot)
                if isDemo { demoTouchID = false } else { settings.touchIDEnabled = false }
            }
        } catch {
            lockMessage = (error as? VaultError)?.errorDescription ?? t("error.generic")
        }
    }

    /// Used by the setup flow once the server accepted the login (the session is unlocked and synced).
    /// Makes `account` the active one; any other account that was open is locked first.
    func completeLogin(account: Account, session newSession: NativeSession) async {
        if phase == .unlocked { await lock() }
        if !settings.accounts.contains(where: { $0.id == account.id }) { settings.accounts.append(account) }
        settings.activeAccountID = account.id
        session = newSession
        addingAccount = false
        showAccounts = false; showFolders = false; showAbout = false
        await enterUnlocked()
    }

    private func enterUnlocked() async {
        await loadVault()
        phase = .unlocked
        lastActivity = Date()
        lockMessage = nil
        generator.regenerate()
        lockChanged?(false)
        Task { await sync(silent: true) } // PRD 5.5: sync on unlock
    }

    /// Keychain slot of the active account's Touch ID item.
    var biometricSlot: String { isDemo ? BiometricUnlock.demoSlot : (settings.activeAccount?.biometricSlot ?? "none") }

    /// Whether the lock screen offers Touch ID right now.
    var touchIDActive: Bool { (isDemo ? demoTouchID : settings.touchIDEnabled) && BiometricUnlock.isAvailable }

    func setTouchIDEnabled(_ on: Bool, password: String? = nil) async -> String? {
        if !on {
            BiometricUnlock.remove(slot: biometricSlot)
            if isDemo { demoTouchID = false } else { settings.touchIDEnabled = false }
            return nil
        }
        if isDemo {
            do { try BiometricUnlock.store(password: "demo", slot: biometricSlot); demoTouchID = true; return nil }
            catch { return t("error.generic") }
        }
        return await enableTouchID(password: password ?? "")
    }

    func unlockWithBiometrics() async {
        guard touchIDActive, phase == .locked, !isUnlocking else { return }
        do {
            let password = try await BiometricUnlock.retrieve(reason: t("lock.touchIDReason"), slot: biometricSlot)
            await unlock(password: password, fromBiometric: true)
            // The system Touch ID sheet takes focus, which closes the transient popover; bring it back once unlocked.
            if phase == .unlocked { requestShowPopover?() }
        } catch BiometricUnlock.Failure.cancelled {
            return
        } catch BiometricUnlock.Failure.invalidated {
            if isDemo { demoTouchID = false } else { settings.touchIDEnabled = false }
            lockMessage = t("lock.touchIDInvalidated")
        } catch {
            lockMessage = t("lock.touchIDFailed")
        }
    }

    func lock(announce: Bool = false) async {
        guard phase == .unlocked else { return }
        phase = .locked // flip first: nothing decrypted stays reachable
        entries = []
        folders = []
        organizations = []
        query = ""
        detailEntryID = nil
        selectedRowID = nil
        editor = nil
        editorError = nil
        pendingDeleteID = nil
        generator.clear()
        tab = .vault
        showAccounts = false; showFolders = false; showAbout = false
        addingAccount = false
        confirmLogoutAccount = false
        Clipboard.clearIfOurs()
        lockChanged?(true)
        if announce { showToast?(t("toast.locked")) }
        await session?.lock()
        if !isDemo { session = nil }
    }

    func lockNow() { Task { await lock(announce: true) } }

    func shutdown() {
        if isDemo { BiometricUnlock.remove(slot: BiometricUnlock.demoSlot) } // leave no demo item in the Keychain
        Clipboard.clearIfOurs()
    }

    // MARK: Account

    /// Logs the active account out and forgets it; falls back to another account or the setup screen.
    func logout() async {
        guard let account = settings.activeAccount else { return }
        entries = []
        await session?.lock()
        session = nil
        query = ""
        detailEntryID = nil
        showAccounts = false; showFolders = false; showAbout = false
        confirmLogoutAccount = false
        tab = .vault
        forget(account)
        if settings.activeAccount != nil {
            phase = .locked // next account
            lockChanged?(true)
            focusToken += 1
        } else {
            phase = .needsSetup
            lockChanged?(true)
            openSetup?()
        }
    }

    // MARK: Accounts

    struct AccountRow: Identifiable {
        let id: String
        let email: String
        let host: String
        let isActive: Bool
    }

    /// Accounts for the account screen. Demo shows two invented ones so the screen can be tried.
    var accountRows: [AccountRow] {
        if isDemo {
            return [("demo-1", "demo.user@example.com", "bitwarden.com"), ("demo-2", "work@example.com", "vault.example.test")]
                .map { AccountRow(id: $0.0, email: $0.1, host: $0.2, isActive: $0.0 == demoActiveAccount) }
        }
        return settings.accounts.map { AccountRow(id: $0.id, email: $0.email, host: $0.host, isActive: $0.id == settings.activeAccountID) }
    }

    var activeAccountRow: AccountRow? { accountRows.first { $0.isActive } }

    /// Locks the current account and makes `id` the active (locked) one.
    func switchAccount(to id: String) async {
        guard id != (isDemo ? demoActiveAccount : settings.activeAccountID) else { return }
        if phase == .unlocked { await lock() }
        showAccounts = false; showFolders = false; showAbout = false
        if isDemo {
            demoActiveAccount = id
            demoTouchID = false
            BiometricUnlock.remove(slot: BiometricUnlock.demoSlot)
        } else {
            guard settings.accounts.contains(where: { $0.id == id }) else { return }
            settings.activeAccountID = id
        }
        phase = .locked
        lockMessage = nil
        lockChanged?(true)
        focusToken += 1
        await unlockWithBiometrics() // the prompt appears right away when this account uses Touch ID
    }

    func beginAddAccount() {
        if isDemo { leaveDemo(); return }
        showAccounts = false; showFolders = false; showAbout = false
        addingAccount = true
    }

    func cancelAddAccount() { addingAccount = false; showAccounts = true }

    // MARK: Loading and sync

    private func loadVault() async {
        guard let session, let snapshot = try? await session.snapshot() else { return }
        folders = snapshot.folders.filter { $0.id != nil }
        organizations = snapshot.organizations
        entries = VaultEntry.build(from: snapshot)
        selectFirst()
    }

    func sync(silent: Bool = false) async {
        guard phase == .unlocked, !isSyncing, let session else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await session.sync()
            await loadVault()
            lastSync = Date()
        } catch {
            if !silent { showToast?(t("toast.syncFailed")) }
        }
    }

    // MARK: Derived list

    private var baseEntries: [VaultEntry] {
        entries.filter { e in
            if settings.hideOrgItems, e.item.organizationId != nil { return false }
            if let typeFilter, e.type != typeFilter { return false }
            switch folderFilter {
            case .all: break
            case .none: if e.item.folderId != nil { return false }
            case .folder(let id): if e.item.folderId != id { return false }
            }
            switch orgFilter {
            case .all: break
            case .personal: if e.item.organizationId != nil { return false }
            case .org(let id): if e.item.organizationId != id { return false }
            }
            return true
        }
    }

    var rows: [Row] {
        if tab == .authenticator { return authenticatorRows }
        let base = baseEntries
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var scored: [(entry: VaultEntry, score: Int)] = []
            for e in base {
                if let s = e.score(for: q) { scored.append((e, s)) }
            }
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
            }
            return scored.map { Row(id: "results-\($0.entry.id)", section: .results, entry: $0.entry) }
        }
        var out: [Row] = []
        for e in base where e.isFavorite { out.append(Row(id: "favorites-\(e.id)", section: .favorites, entry: e)) }
        for e in base { out.append(Row(id: "all-\(e.id)", section: .all, entry: e)) }
        return out
    }

    private var authenticatorRows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var scored: [(entry: VaultEntry, score: Int)] = []
        for e in entries where e.totp != nil && !(settings.hideOrgItems && e.item.organizationId != nil) {
            if q.isEmpty { scored.append((e, 0)) } else if let s = e.score(for: q) { scored.append((e, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        }
        return scored.map { Row(id: "authenticator-\($0.entry.id)", section: .authenticator, entry: $0.entry) }
    }

    static func title(for section: ListSection) -> String {
        switch section {
        case .favorites: return t("section.favorites")
        case .authenticator: return t("section.authenticator")
        case .all: return t("section.all")
        case .results: return t("section.results")
        }
    }

    var hasActiveFilters: Bool { folderFilter != .all || typeFilter != nil || orgFilter != .all }

    var showsOrgFilter: Bool { !organizations.isEmpty && !settings.hideOrgItems }

    func clearFilters() {
        folderFilter = .all; typeFilter = nil; orgFilter = .all; query = ""
    }

    // MARK: Selection and keyboard actions

    private func selectFirst() { selectedRowID = rows.first?.id }

    func moveSelection(_ delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let idx = rows.firstIndex { $0.id == selectedRowID } ?? (delta > 0 ? -1 : rows.count)
        selectedRowID = rows[min(max(idx + delta, 0), rows.count - 1)].id
    }

    var selectedEntry: VaultEntry? {
        rows.first { $0.id == selectedRowID }?.entry
    }

    var detailEntry: VaultEntry? {
        detailEntryID.flatMap { id in entries.first { $0.id == id } }
    }

    /// The entry keyboard shortcuts act on: the open detail, else the selected row.
    var targetEntry: VaultEntry? { detailEntry ?? selectedEntry }

    func openDetail(_ entry: VaultEntry) { detailEntryID = entry.id }
    func closeDetail() { detailEntryID = nil }
    func noteActivity() { lastActivity = Date() }

    // MARK: Copy

    private func finishCopy(_ value: String) {
        Clipboard.copy(value, clearAfter: settings.clipboardSeconds)
        noteActivity()
        let seconds = settings.clipboardSeconds
        if settings.closeAfterCopy { closePopover?() }
        showToast?(seconds > 0 ? t("toast.copiedClears", seconds) : t("toast.copied"))
    }

    /// Copy any value and close the popover with the usual toast.
    func copyValue(_ value: String?, missingKey: String) {
        guard let value, !value.isEmpty else { showToast?(t(missingKey)); return }
        finishCopy(value)
    }

    /// Copy without closing the popover (generator, detail fields).
    func copyKeepingOpen(_ value: String) { copyField(value) }

    func copyPassword(_ e: VaultEntry) {
        guard let p = e.password else { showToast?(t("toast.noPassword")); return }
        finishCopy(p)
    }

    func copyUsername(_ e: VaultEntry) {
        guard let u = e.username else { showToast?(t("toast.noUsername")); return }
        finishCopy(u)
    }

    func copyCode(_ e: VaultEntry) {
        guard let totp = e.totp else { showToast?(t("toast.noCode")); return }
        finishCopy(totp.code())
    }

    /// Copy of an arbitrary detail field (keeps the popover open: the user is browsing).
    func copyField(_ value: String) {
        Clipboard.copy(value, clearAfter: settings.clipboardSeconds)
        noteActivity()
        let seconds = settings.clipboardSeconds
        showToast?(seconds > 0 ? t("toast.copiedClears", seconds) : t("toast.copied"))
    }

    // MARK: Settings

    /// Quits the demo and starts the app again in normal mode (first-run login, or the real vault).
    /// The restart is a detached shell so the new copy starts after this one has exited
    /// (the single-instance check would otherwise make the newcomer quit).
    func leaveDemo() {
        let target = Bundle.main.bundleURL
        let script: String
        if target.pathExtension == "app" { script = "sleep 0.8; /usr/bin/open -n \"$0\"" }
        else { script = "sleep 0.8; exec \"$0\"" } // dev build: re-run the bare binary without --demo
        let path = target.pathExtension == "app" ? target.path : CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, path]
        try? p.run()
        NSApp.terminate(nil)
    }

    func openSettingsTab() {
        tab = .settings
        requestShowPopover?()
    }

    /// Called by the key monitor while recording; returns true when the key was consumed.
    func recordHotkey(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if keyCode == 53 { isRecordingHotkey = false; return } // esc cancels
        let mods = HotkeyFormat.carbonModifiers(from: flags)
        // Needs ⌘, ⌥ or ⌃: with ⇧ alone the hotkey would swallow capital letters system-wide.
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return }
        isRecordingHotkey = false
        settings.hotkeyKeyCode = UInt32(keyCode)
        settings.hotkeyModifiers = mods
        settings.hotkeyEnabled = true
    }

    /// Verifies the master password against the stored key, then stores it behind Touch ID. Returns an error message or nil.
    func enableTouchID(password: String) async -> String? {
        guard let account = settings.activeAccount, !password.isEmpty else { return t("error.generic") }
        do {
            try await NativeSession.verifyPassword(password, for: account) // proves it before it is stored
            try BiometricUnlock.store(password: password, slot: biometricSlot)
            settings.touchIDEnabled = true
            return nil
        } catch VaultError.invalidPassword {
            return t("lock.wrongPassword")
        } catch {
            return t("error.generic")
        }
    }

    // MARK: Import / export (Bitwarden .json)

    func pickAndImport() async {
        keepAppActive = true
        closePopover?()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = t("data.importPanel")
        let ok = panel.runModal() == .OK
        keepAppActive = false
        if ok, let url = panel.url { await importFile(at: url) }
        openSettingsTab()
    }

    func importFile(at url: URL) async {
        importReport = nil
        importError = nil
        guard let session else { return }
        do {
            let data = try Data(contentsOf: url)
            let plan = try BitwardenFile.parse(data)
            let existing = try await session.snapshot()
            let (request, report) = BitwardenFile.prepare(plan, existing: existing)
            if !request.entries.isEmpty || !request.newFolders.isEmpty { try await session.importEntries(request) }
            await loadVault()
            lastSync = Date()
            importReport = report
            noteActivity()
        } catch ImportError.encrypted {
            importError = t("data.importEncrypted")
        } catch ImportError.notBitwardenExport {
            importError = t("data.importUnknown")
        } catch {
            importError = t("data.importFailed", describe(error))
        }
    }

    /// The vault as a Bitwarden `.json` export (personal items only) and how many items it holds.
    func exportJSON() throws -> (data: Data, count: Int) {
        let items = entries.map(\.item).filter { $0.organizationId == nil }
        return (try BitwardenFile.export(items: items, folders: folders), items.count)
    }

    /// Re-checks the master password, then asks where to save. Returns an error message, or nil (also when cancelled).
    func exportVault(password: String) async -> String? {
        if isDemo { guard !password.isEmpty else { return t("lock.wrongPassword") } }
        else {
            guard let account = settings.activeAccount else { return t("error.generic") }
            do { try await NativeSession.verifyPassword(password, for: account) }
            catch { return describe(error) }
        }
        do {
            let (data, count) = try exportJSON()
            keepAppActive = true
            closePopover?()
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMddHHmmss"
            panel.nameFieldStringValue = "vaultbar_export_\(stamp.string(from: Date())).json"
            panel.message = t("data.exportPanel")
            let ok = panel.runModal() == .OK
            keepAppActive = false
            if ok, let url = panel.url {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                showToast?(t("toast.exported", count))
            }
            openSettingsTab()
            return nil
        } catch {
            keepAppActive = false
            return describe(error)
        }
    }

    // MARK: Add / edit / clone / delete

    func beginAdd() {
        var folderId: String?
        if case .folder(let id) = folderFilter { folderId = id }
        editor = ItemDraft(type: typeFilter ?? .login, folderId: folderId)
        editorError = nil
        editorFocusesKey = false
        noteActivity()
    }

    /// "Add" on the 2FA tab: a new login with the key field ready for pasting.
    func beginAddAuthenticator() {
        editor = ItemDraft(type: .login)
        editorError = nil
        editorFocusesKey = true
        noteActivity()
    }

    // MARK: Scan a 2FA QR code

    enum QRSource { case screen, file, clipboard }

    /// Reads a 2FA setup QR code from the screen, an image file or the clipboard and puts its key in the editor
    /// (a new login is opened first when no editor is open, as on the 2FA tab).
    func scanAuthenticatorQR(from source: QRSource) async {
        noteActivity()
        let openedHere = editor == nil
        if openedHere { beginAddAuthenticator() }
        guard editor?.type == .login else { return }

        let image: CGImage?
        switch source {
        case .clipboard:
            image = Self.clipboardImage()
            if image == nil { editorError = t("qr.noClipboard"); return }
        case .file:
            image = await pickImageFile()
        case .screen:
            image = await captureScreenRegion()
        }
        guard let image else { // cancelled
            if openedHere { cancelEditor() }
            requestShowPopover?()
            return
        }
        switch QRScanner.outcome(in: image) {
        case .key(let link):
            editor?.totp = link
            authenticatorKeyChanged()
            editorError = nil
            showToast?(t("qr.read"))
        case .noQR: editorError = t("qr.notFound")
        case .notAuthenticator: editorError = t("qr.notAuthenticator")
        case .migrationExport: editorError = t("qr.migration")
        }
        requestShowPopover?()
    }

    private static func clipboardImage() -> CGImage? {
        guard let image = NSImage(pasteboard: .general) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func pickImageFile() async -> CGImage? {
        keepAppActive = true
        closePopover?()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = t("qr.filePanel")
        let ok = panel.runModal() == .OK
        keepAppActive = false
        guard ok, let url = panel.url else { return nil }
        return QRScanner.image(at: url)
    }

    /// Lets the user drag a region with the system screenshot tool. The picture goes to a temp file that is deleted right away.
    private func captureScreenRegion() async -> CGImage? {
        keepAppActive = true
        closePopover?()
        try? await Task.sleep(nanoseconds: 350_000_000) // let the popover finish closing so it is not in the shot
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vaultbar-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file); keepAppActive = false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume() }
        }
        return QRScanner.image(at: file) // nil when the user pressed esc
    }

    /// Pasting an `otpauth://` link names the item and fills the username when they are still empty.
    func authenticatorKeyChanged() {
        guard var draft = editor, draft.type == .login, let totp = TOTP(parsing: draft.totp) else { return }
        var changed = false
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty, let issuer = totp.issuer { draft.name = issuer; changed = true }
        if draft.username.isEmpty, let account = totp.account { draft.username = account; changed = true }
        if changed { editor = draft }
    }

    func beginEdit(_ e: VaultEntry) {
        editor = ItemDraft(item: e.item)
        editorError = nil
        noteActivity()
    }

    func cancelEditor() { editor = nil; editorError = nil; editorFocusesKey = false }

    func saveEditor() async {
        guard let draft = editor, !isSaving, let session else { return }
        if let problem = draft.problem {
            editorError = problem == .nameRequired ? t("edit.nameRequired") : t("edit.invalidTOTP")
            return
        }
        isSaving = true
        editorError = nil
        defer { isSaving = false }
        do {
            try await session.save(draft)
            editor = nil
            editorFocusesKey = false
            noteActivity()
            await loadVault()
            showToast?(session.lastSaveUsedKeyField ? t("toast.savedKeyField") : t("toast.saved"))
            Task { await sync(silent: true) }
        } catch VaultError.serverIgnored(let fields) {
            await loadVault() // show what the server really has
            editorError = t("edit.serverIgnored", fields.joined(separator: ", "))
        } catch {
            editorError = t("edit.saveFailed", (error as? VaultError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func clone(_ e: VaultEntry) async {
        guard let session else { return }
        do {
            try await session.clone(id: e.id, nameSuffix: t("clone.suffix"))
            noteActivity()
            await loadVault()
            showToast?(t("toast.cloned"))
            Task { await sync(silent: true) }
        } catch {
            showToast?(t("toast.actionFailed", (error as? VaultError)?.errorDescription ?? error.localizedDescription))
        }
    }

    // MARK: Folders

    func itemCount(inFolder id: String?) -> Int { entries.filter { $0.item.folderId == id }.count }

    /// Returns true on success; the reason is left in `folderError`.
    func addFolder(_ rawName: String) async -> Bool {
        guard let name = validFolderName(rawName, excluding: nil), let session else { return false }
        return await runFolderChange { try await session.createFolder(name: name) }
    }

    func renameFolder(_ folder: VaultFolder, to rawName: String) async -> Bool {
        guard let id = folder.id, let name = validFolderName(rawName, excluding: id), let session else { return false }
        return await runFolderChange { try await session.renameFolder(id: id, name: name) }
    }

    func deleteFolder(_ folder: VaultFolder) async {
        guard let id = folder.id, let session else { return }
        if await runFolderChange({ try await session.deleteFolder(id: id) }, toast: "toast.folderDeleted") {
            if case .folder(let current) = folderFilter, current == id { folderFilter = .all }
        }
    }

    private func validFolderName(_ raw: String, excluding id: String?) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { folderError = t("folders.nameRequired"); return nil }
        if folders.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            folderError = t("folders.exists"); return nil
        }
        folderError = nil
        return name
    }

    private func runFolderChange(_ work: () async throws -> Void, toast: String = "toast.folderSaved") async -> Bool {
        do {
            try await work()
            folderError = nil
            noteActivity()
            await loadVault()
            showToast?(t(toast))
            return true
        } catch {
            folderError = describe(error)
            return false
        }
    }

    // MARK: About and updates

    enum UpdateStatus: Equatable {
        case idle, checking, upToDate, noRelease, failed
        case available(UpdateCheck.Release)
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func openAbout() {
        showAbout = true
        guard !isDemo, let account = settings.activeAccount else { return }
        serverVersion = nil
        Task { serverVersion = await api(for: account).serverVersion() }
    }

    /// Plain-text summary for the About "Copy" button.
    var aboutSummary: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        var lines = ["VaultBar \(appVersion) (\(build))"]
        if let url = settings.server?.url { lines.append("Server: \(url)" + (serverVersion.map { " (\($0))" } ?? "")) }
        return lines.joined(separator: "\n")
    }

    func checkForUpdates() async {
        updateStatus = .checking
        do {
            if let release = try await UpdateCheck.fetchLatest() {
                updateStatus = UpdateCheck.isNewer(release.version, than: appVersion) ? .available(release) : .upToDate
            } else {
                updateStatus = .noRelease
            }
        } catch {
            updateStatus = .failed
        }
    }

    func requestDelete(_ e: VaultEntry) { pendingDeleteID = e.id }
    func cancelDelete() { pendingDeleteID = nil }

    var pendingDeleteEntry: VaultEntry? { pendingDeleteID.flatMap { id in entries.first { $0.id == id } } }

    func confirmDelete() async {
        guard let id = pendingDeleteID, let session else { return }
        pendingDeleteID = nil
        do {
            try await session.delete(id: id)
            if detailEntryID == id { detailEntryID = nil }
            noteActivity()
            await loadVault()
            showToast?(t("toast.deleted"))
            Task { await sync(silent: true) }
        } catch {
            showToast?(t("toast.actionFailed", (error as? VaultError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// Two-letter avatar for the header, from the active account's e-mail.
    var accountInitials: String {
        Account.initials(forEmail: activeAccountRow?.email ?? settings.accountEmail ?? "")
    }

    // MARK: Auto-lock

    private func autoLockTick() {
        guard phase == .unlocked else { return }
        let minutes = settings.autoLockMinutes
        guard minutes > 0, Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 else { return }
        Task { await lock() }
    }

    private func installLockObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.lock() }
            })
        }
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.lock() }
        })
    }

    // MARK: Time formatting

    func syncedText(now: Date = Date()) -> String {
        guard let lastSync else { return t("footer.neverSynced") }
        let secs = Int(now.timeIntervalSince(lastSync))
        let rel: String
        if secs < 60 { rel = t("time.justNow") }
        else if secs < 3600 { rel = t("time.minutesAgo", secs / 60) }
        else { rel = t("time.hoursAgo", secs / 3600) }
        return t("footer.synced", rel)
    }
}
