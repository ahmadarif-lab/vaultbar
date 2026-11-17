import AppKit
import Observation
import VaultKit

@MainActor @Observable
final class AppState {
    enum Phase { case checking, cliMissing, needsSetup, locked, unlocked }
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
    var isSaving = false
    var pendingDeleteID: String?

    let generator = GeneratorModel()

    /// True while the Settings tab is waiting for the user to press a new global hotkey.
    var isRecordingHotkey = false { didSet { settings.onHotkeyChanged?() } }

    var lastSync: Date?

    // Accounts screen / add-account flow
    var showAccounts = false
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

    @ObservationIgnored private(set) var cli: BWCLI?
    @ObservationIgnored private(set) var bwExecutable: URL?
    @ObservationIgnored private var session: VaultSession?
    @ObservationIgnored private var bw: BWSession?
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
        BWServe.killStaleServer()
        await recheckCLI()
    }

    func recheckCLI() async {
        guard let exe = BWCLI.locate() else {
            phase = .cliMissing
            return
        }
        bwExecutable = exe
        guard let account = settings.activeAccount else {
            cli = nil
            phase = .needsSetup // nobody logged in yet
            openSetup?()
            return
        }
        let cli = BWCLI(executable: exe, dataDirectory: account.dataDirectory)
        self.cli = cli
        do {
            let status = try await cli.status()
            if status.state == .unauthenticated {
                // The account's CLI data is gone (logged out elsewhere): forget it.
                forget(account)
                await recheckCLI()
            } else {
                phase = .locked
                lockChanged?(true)
            }
        } catch {
            phase = .locked // CLI hiccup: let unlock report the real error
            lockChanged?(true)
        }
    }

    /// Removes an account from the list (and its Touch ID item and data folder).
    private func forget(_ account: Account) {
        BiometricUnlock.remove(slot: account.biometricSlot)
        if account.id != Account.legacyID { try? FileManager.default.removeItem(at: account.dataDirectory.deletingLastPathComponent()) }
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
                guard let cli else { phase = .cliMissing; return }
                let s = BWSession(cli: cli)
                try await s.unlock(password: password)
                bw = s
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

    /// Used by the setup flow, which already holds a session key from `bw login`.
    /// Makes `account` the active one; any other account that was open is locked first.
    func completeLogin(account: Account, sessionKey: String) async throws {
        guard let exe = bwExecutable else { throw VaultError.cliMissing }
        let newCLI = BWCLI(executable: exe, dataDirectory: account.dataDirectory)
        let s = BWSession(cli: newCLI)
        try await s.start(sessionKey: sessionKey) // may throw: only then is the account recorded
        if phase == .unlocked { await lock() }
        if !settings.accounts.contains(where: { $0.id == account.id }) { settings.accounts.append(account) }
        settings.activeAccountID = account.id
        cli = newCLI
        bw = s
        session = s
        addingAccount = false
        showAccounts = false
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
        showAccounts = false
        addingAccount = false
        confirmLogoutAccount = false
        Clipboard.clearIfOurs()
        lockChanged?(true)
        if announce { showToast?(t("toast.locked")) }
        await session?.lock()
        if !isDemo { session = nil; bw = nil }
    }

    func lockNow() { Task { await lock(announce: true) } }

    func shutdown() {
        if isDemo { BiometricUnlock.remove(slot: BiometricUnlock.demoSlot) } // leave no demo item in the Keychain
        bw?.stopServeNow()
        Clipboard.clearIfOurs()
    }

    // MARK: Account

    /// Logs the active account out and forgets it; falls back to another account or the setup screen.
    func logout() async {
        guard let account = settings.activeAccount else { return }
        entries = []
        await session?.lock()
        bw?.stopServeNow()
        try? await cli?.logout()
        session = nil
        bw = nil
        query = ""
        detailEntryID = nil
        showAccounts = false
        confirmLogoutAccount = false
        tab = .vault
        forget(account)
        if settings.activeAccount != nil {
            await recheckCLI() // next account, locked
        } else {
            cli = nil
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
        showAccounts = false
        if isDemo {
            demoActiveAccount = id
            demoTouchID = false
            BiometricUnlock.remove(slot: BiometricUnlock.demoSlot)
        } else {
            guard let account = settings.accounts.first(where: { $0.id == id }), let exe = bwExecutable else { return }
            settings.activeAccountID = id
            cli = BWCLI(executable: exe, dataDirectory: account.dataDirectory)
        }
        phase = .locked
        lockMessage = nil
        lockChanged?(true)
        focusToken += 1
        await unlockWithBiometrics() // the prompt appears right away when this account uses Touch ID
    }

    func beginAddAccount() {
        if isDemo { leaveDemo(); return }
        showAccounts = false
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
        closePopover?()
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

    /// Verifies the master password with `bw`, then stores it behind Touch ID. Returns an error message or nil.
    func enableTouchID(password: String) async -> String? {
        guard let cli, !password.isEmpty else { return t("error.generic") }
        do {
            _ = try await cli.unlock(password: password) // proves the password before it is stored
            try BiometricUnlock.store(password: password, slot: biometricSlot)
            settings.touchIDEnabled = true
            return nil
        } catch VaultError.invalidPassword {
            return t("lock.wrongPassword")
        } catch {
            return t("error.generic")
        }
    }

    // MARK: Add / edit / clone / delete

    func beginAdd() {
        var folderId: String?
        if case .folder(let id) = folderFilter { folderId = id }
        editor = ItemDraft(type: typeFilter ?? .login, folderId: folderId)
        editorError = nil
        noteActivity()
    }

    func beginEdit(_ e: VaultEntry) {
        editor = ItemDraft(item: e.item)
        editorError = nil
        noteActivity()
    }

    func cancelEditor() { editor = nil; editorError = nil }

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
            noteActivity()
            await loadVault()
            showToast?(t("toast.saved"))
            Task { await sync(silent: true) }
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
