import AppKit
import VaultKit

/// `--selftest`: drives the real AppState and popover (demo vault) through
/// add / edit / clone / delete and checks the popover stays open while it
/// should. Prints PASS/FAIL lines and exits non-zero on failure. No keystrokes.
@MainActor
enum SelfTest {
    static func run(state: AppState, bar: StatusBarController) async -> Bool {
        // `VB_SELFTEST_RELAUNCH=1`: only exercise "leave demo" (the app restarts itself in normal mode).
        if ProcessInfo.processInfo.environment["VB_SELFTEST_RELAUNCH"] != nil {
            state.leaveDemo()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS  \(what)" : "FAIL  \(what)")
            if !ok { failures += 1 }
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

        await wait(1.0) // let the status item get its window first
        bar.show()
        await wait(0.8)
        check(bar.isShown, "popover opens")
        let start = state.entries.count

        // Add
        state.beginAdd()
        check(state.editor?.isNew == true, "beginAdd opens an empty draft")
        await state.saveEditor()
        check(state.editor != nil && state.editorError != nil, "saving an empty name is refused with a message")
        state.editor?.name = "Self Test Item"
        state.editor?.username = "tester"
        state.editor?.password = "pw-123"
        state.editor?.uris = ["https://selftest.example"]
        state.editor?.totp = "JBSWY3DPEHPK3PXP"
        await state.saveEditor()
        check(state.editor == nil, "editor closes after a successful save")
        check(state.entries.count == start + 1, "item count +1 after add")
        let added = state.entries.first { $0.name == "Self Test Item" }
        check(added?.totp != nil, "new item's authenticator key parses (shows in 2FA tab)")
        await wait(1.2)
        check(bar.isShown, "popover stays open after save + toast")

        // Edit
        if let added {
            state.beginEdit(added)
            state.editor?.name = "Self Test Renamed"
            state.editor?.favorite = true
            await state.saveEditor()
        }
        let renamed = state.entries.first { $0.name == "Self Test Renamed" }
        check(renamed != nil && renamed?.isFavorite == true, "edit persists name and favorite")
        check(renamed?.username == "tester" && renamed?.password == "pw-123", "edit keeps untouched fields")

        // Clone
        if let renamed { await state.clone(renamed) }
        let clone = state.entries.first { $0.name == "Self Test Renamed - Clone" }
        check(clone != nil, "clone creates a copy with the suffix")
        check(clone?.id != renamed?.id, "clone has a new id")

        // Clone of an organization item is refused
        if let org = state.entries.first(where: { $0.item.organizationId != nil }) {
            let before = state.entries.count
            await state.clone(org)
            check(state.entries.count == before, "organization items cannot be cloned")
        }

        // Delete (with confirmation)
        if let clone {
            state.requestDelete(clone)
            check(state.pendingDeleteEntry?.id == clone.id, "delete asks for confirmation first")
            await state.confirmDelete()
            check(!state.entries.contains { $0.id == clone.id }, "confirmed delete removes the item")
        }
        if let renamed {
            state.requestDelete(renamed)
            state.cancelDelete()
            check(state.entries.contains { $0.id == renamed.id }, "cancelled delete keeps the item")
            state.requestDelete(renamed)
            await state.confirmDelete()
        }
        check(state.entries.count == start, "back to the original item count")

        // Tabs, generator, copy keeping the popover open
        state.tab = .generator
        let first = state.generator.value
        state.generator.regenerate()
        check(!first.isEmpty && first != state.generator.value, "generator produces a new value each time")
        state.tab = .authenticator
        check(state.rows.allSatisfy { $0.entry.totp != nil } && !state.rows.isEmpty, "2FA tab lists only items with a key")
        state.copyKeepingOpen("selftest")
        await wait(1.2)
        check(bar.isShown, "popover stays open after a keep-open copy + toast")
        check(NSPasteboard.general.string(forType: .string) == "selftest", "keep-open copy reached the clipboard")

        // Settings live in the popover: no separate window may ever open
        func titledWindowVisible() -> Bool { NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) } }
        state.openSettingsTab()
        await wait(0.8)
        check(state.tab == .settings && bar.isShown && !titledWindowVisible(), "Settings opens as a tab, no extra window")

        // Hotkey recording through the same key path the popover uses
        let savedKey = state.settings.hotkeyKeyCode, savedMods = state.settings.hotkeyModifiers, savedOn = state.settings.hotkeyEnabled
        state.isRecordingHotkey = true
        state.recordHotkey(keyCode: 11, flags: [.shift]) // no ⌘/⌥/⌃: ignored
        check(state.isRecordingHotkey && state.settings.hotkeyKeyCode == savedKey, "hotkey without a modifier is ignored")
        state.recordHotkey(keyCode: 11, flags: [.command, .shift])
        check(!state.isRecordingHotkey && state.settings.hotkeyKeyCode == 11 && state.settings.hotkeyModifiers == (256 | 512), "hotkey recorded (⌘⇧B)")
        state.isRecordingHotkey = true
        state.recordHotkey(keyCode: 53, flags: [])
        check(!state.isRecordingHotkey && state.settings.hotkeyKeyCode == 11, "esc cancels recording")
        state.settings.hotkeyKeyCode = savedKey; state.settings.hotkeyModifiers = savedMods; state.settings.hotkeyEnabled = savedOn

        state.settings.language = .id
        check(t("tab.settings") == "Pengaturan", "language switches at runtime")
        state.settings.language = .en

        // Touch ID storage: store -> present -> remove per slot, without a biometric prompt
        if BiometricUnlock.isAvailable {
            let demo = BiometricUnlock.demoSlot, other = "acct-selftest"
            check((try? BiometricUnlock.store(password: "demo", slot: demo)) != nil, "Touch ID: password stored in the Keychain")
            check(BiometricUnlock.hasStoredPassword(slot: demo), "Touch ID: stored item is found")
            check(!BiometricUnlock.hasStoredPassword(slot: other), "Touch ID: another slot (account) does not see it")
            BiometricUnlock.remove(slot: demo)
            check(!BiometricUnlock.hasStoredPassword(slot: demo), "Touch ID: item removed")
            _ = await state.setTouchIDEnabled(true)
            check(state.touchIDActive, "Touch ID: demo toggle makes the lock screen offer it")
            _ = await state.setTouchIDEnabled(false)
            check(!state.touchIDActive, "Touch ID: switching off hides it again")
        } else {
            print("SKIP  Touch ID checks (no biometrics on this Mac)")
        }

        // Accounts (demo has two fake ones)
        check(state.accountRows.count == 2 && state.activeAccountRow?.id == "demo-1", "account screen lists the active account and one more")
        state.showAccounts = true
        check(state.showAccounts, "account screen opens")
        await state.switchAccount(to: "demo-2")
        check(state.activeAccountRow?.id == "demo-2" && state.phase == .locked && !state.showAccounts && state.entries.isEmpty,
              "switching account locks the old one and activates the other")
        await state.unlock(password: "demo")
        check(state.phase == .unlocked && !state.entries.isEmpty, "the new account unlocks")
        await state.switchAccount(to: "demo-1")
        await state.unlock(password: "demo")
        check(state.activeAccountRow?.id == "demo-1" && state.phase == .unlocked, "switching back works")
        check(state.accountInitials == "DU", "header initials follow the active account")

        // Every tab icon must exist as an SF Symbol (a missing name renders as nothing)
        for tab in AppState.Tab.allCases {
            let names = TabBar.symbols(tab)
            for name in [names.normal, names.selected] {
                check(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "SF Symbol exists: \(name)")
            }
        }

        // Lock wipes everything
        state.tab = .vault
        await state.lock()
        check(state.entries.isEmpty && state.editor == nil && state.generator.value.isEmpty, "lock wipes items, editor and generated value")
        check(state.phase == .locked, "phase is locked")

        Clipboard.clearIfOurs()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }
}
