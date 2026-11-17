import AppKit
import Observation
import VaultKit

@MainActor @Observable
final class AppState {
    enum Phase { case checking, cliMissing, needsSetup, locked, unlocked }
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

    var lastSync: Date?
    var isSyncing = false
    var isUnlocking = false
    var lockMessage: String?
    /// Bumped every time the popover opens so the search field refocuses.
    var focusToken = 0

    @ObservationIgnored private(set) var cli: BWCLI?
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
        let cli = BWCLI(executable: exe)
        self.cli = cli
        do {
            let status = try await cli.status()
            if let email = status.userEmail { settings.accountEmail = email }
            switch status.state {
            case .unauthenticated:
                phase = .needsSetup
                openSetup?()
            case .locked, .unlocked:
                phase = .locked
                lockChanged?(true)
            }
        } catch {
            // Treat an unreadable CLI state as "needs setup": logging in repairs it.
            phase = .needsSetup
            openSetup?()
        }
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
                BiometricUnlock.remove()
                settings.touchIDEnabled = false
            }
        } catch {
            lockMessage = (error as? VaultError)?.errorDescription ?? t("error.generic")
        }
    }

    /// Used by the setup flow, which already holds a session key from `bw login`.
    func finishLogin(sessionKey: String) async throws {
        guard let cli else { throw VaultError.cliMissing }
        let s = BWSession(cli: cli)
        try await s.start(sessionKey: sessionKey)
        bw = s
        session = s
        await enterUnlocked()
    }

    private func enterUnlocked() async {
        await loadVault()
        phase = .unlocked
        lastActivity = Date()
        lockMessage = nil
        lockChanged?(false)
        Task { await sync(silent: true) } // PRD 5.5: sync on unlock
    }

    func unlockWithBiometrics() async {
        guard !isDemo, settings.touchIDEnabled, BiometricUnlock.isAvailable, phase == .locked, !isUnlocking else { return }
        do {
            let password = try await BiometricUnlock.retrieve(reason: t("lock.touchIDReason"))
            await unlock(password: password, fromBiometric: true)
        } catch BiometricUnlock.Failure.cancelled {
            return
        } catch BiometricUnlock.Failure.invalidated {
            settings.touchIDEnabled = false
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
        Clipboard.clearIfOurs()
        lockChanged?(true)
        if announce { showToast?(t("toast.locked")) }
        await session?.lock()
        if !isDemo { session = nil; bw = nil }
    }

    func lockNow() { Task { await lock(announce: true) } }

    func shutdown() {
        bw?.stopServeNow()
        Clipboard.clearIfOurs()
    }

    // MARK: Account

    func logout() async {
        entries = []
        await session?.lock()
        bw?.stopServeNow()
        try? await cli?.logout()
        BiometricUnlock.remove()
        settings.clearAccount()
        session = nil
        bw = nil
        query = ""
        detailEntryID = nil
        phase = .needsSetup
        lockChanged?(true)
        openSetup?()
    }

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
        for e in base where e.totp != nil { out.append(Row(id: "authenticator-\(e.id)", section: .authenticator, entry: e)) }
        for e in base { out.append(Row(id: "all-\(e.id)", section: .all, entry: e)) }
        return out
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
