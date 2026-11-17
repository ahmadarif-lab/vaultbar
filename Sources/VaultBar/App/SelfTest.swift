import AppKit
import CoreImage
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

        // Folders: add, reject duplicates, rename, delete
        let folderCount = state.folders.count
        let folderAdded = await state.addFolder("Selftest folder")
        check(folderAdded && state.folders.count == folderCount + 1, "a folder can be added")
        let duplicate = await state.addFolder("selftest FOLDER")
        check(!duplicate && state.folderError != nil && state.folders.count == folderCount + 1, "a duplicate folder name is rejected")
        if let created = state.folders.first(where: { $0.name == "Selftest folder" }) {
            let renamedOK = await state.renameFolder(created, to: "Selftest renamed")
            check(renamedOK && state.folders.contains { $0.name == "Selftest renamed" }, "a folder can be renamed")
            if let renamedFolder = state.folders.first(where: { $0.name == "Selftest renamed" }) { await state.deleteFolder(renamedFolder) }
        }
        check(state.folders.count == folderCount, "a folder can be deleted")

        // Theme: forced dark/light, then back to the system
        state.settings.appearance = .dark
        check(NSApp.appearance?.name == .darkAqua, "theme: Dark forces the dark appearance")
        state.settings.appearance = .light
        check(NSApp.appearance?.name == .aqua, "theme: Light forces the light appearance")
        state.settings.appearance = .system
        check(NSApp.appearance == nil, "theme: System follows macOS")

        // Lock when closed
        state.settings.lockOnClose = true
        bar.close()
        await wait(0.8)
        check(state.phase == .locked && state.entries.isEmpty, "closing the popover locks the vault when 'lock when closed' is on")
        state.settings.lockOnClose = false
        await state.unlock(password: "demo")
        bar.show()
        await wait(0.8)
        check(state.phase == .unlocked && bar.isShown, "unlock again after a lock-on-close")

        // Tabs, generator, copy keeping the popover open
        state.tab = .generator
        let first = state.generator.value
        state.generator.regenerate()
        check(!first.isEmpty && first != state.generator.value, "generator produces a new value each time")
        state.tab = .authenticator
        check(state.rows.allSatisfy { $0.entry.totp != nil } && !state.rows.isEmpty, "2FA tab lists only items with a key")
        state.copyValue("selftest-copy", missingKey: "toast.copied")
        await wait(1.2)
        check(bar.isShown, "popover stays open after a normal copy")
        state.copyKeepingOpen("selftest")
        await wait(1.2)
        check(bar.isShown, "popover stays open after a keep-open copy + toast")
        check(NSPasteboard.general.string(forType: .string) == "selftest", "keep-open copy reached the clipboard")

        // Scan a 2FA QR code from an image on the clipboard
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data("otpauth://totp/QRCorp:scan@example.test?secret=JBSWY3DPEHPK3PXP&issuer=QRCorp".utf8), forKey: "inputMessage")
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) {
                let rep = NSCIImageRep(ciImage: output)
                let picture = NSImage(size: rep.size)
                picture.addRepresentation(rep)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([picture])
                state.beginAddAuthenticator()
                await state.scanAuthenticatorQR(from: .clipboard)
                check(state.editor?.totp.hasPrefix("otpauth://totp/QRCorp") == true && state.editor?.name == "QRCorp"
                      && state.editor?.username == "scan@example.test", "a QR code on the clipboard fills the key, name and username")
                state.cancelEditor()
            }
        }

        // "Add" on the 2FA tab: pasting an otpauth link names the item and fills the username
        state.beginAddAuthenticator()
        check(state.editor?.type == .login && state.editorFocusesKey, "2FA Add opens a login with the key field focused")
        state.editor?.totp = "otpauth://totp/Acme:bob@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Acme"
        state.authenticatorKeyChanged()
        check(state.editor?.name == "Acme" && state.editor?.username == "bob@example.test", "an otpauth link fills name and username")
        await state.saveEditor()
        state.tab = .authenticator
        check(state.rows.contains { $0.entry.name == "Acme" }, "the new code appears in the 2FA tab")
        if let acme = state.entries.first(where: { $0.name == "Acme" }) { state.requestDelete(acme); await state.confirmDelete() }
        state.tab = .vault

        // Import a Bitwarden .json (written to a temp file), twice, then export
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vaultbar-selftest-\(UUID().uuidString).json")
        let sample = #"{"encrypted":false,"folders":[{"id":"f","name":"Imported"}],"items":[{"id":"i1","type":1,"name":"Imported login","folderId":"f","login":{"username":"imp","password":"pw","uris":[{"uri":"https://imp.test"}]}},{"id":"i2","type":2,"name":"Imported note","notes":"x","secureNote":{"type":0}},{"id":"i3","type":1,"name":"Gone","deletedDate":"2026-01-01T00:00:00Z","login":{}}]}"#
        try? sample.write(to: tmp, atomically: true, encoding: .utf8)
        let before = state.entries.count
        await state.importFile(at: tmp)
        check(state.importReport?.added == 2 && state.importReport?.trashed == 1 && state.entries.count == before + 2, "import adds the file's items and skips the trash")
        check(state.folders.contains { $0.name == "Imported" } && state.entries.first { $0.name == "Imported login" }?.folderName == "Imported", "import creates the folder and files the item in it")
        await state.importFile(at: tmp)
        check(state.importReport?.added == 0 && state.importReport?.duplicates == 2 && state.entries.count == before + 2, "importing the same file again adds nothing")
        try? "{\"encrypted\":true}".write(to: tmp, atomically: true, encoding: .utf8)
        await state.importFile(at: tmp)
        check(state.importError == t("data.importEncrypted"), "an encrypted export is explained, not imported")
        try? "nope".write(to: tmp, atomically: true, encoding: .utf8)
        await state.importFile(at: tmp)
        check(state.importError != nil, "a foreign file is refused")
        try? FileManager.default.removeItem(at: tmp)
        if let exported = try? state.exportJSON(), let plan = try? BitwardenFile.parse(exported.data) {
            check(exported.count == plan.entries.count && plan.entries.contains { $0.draft.name == "Imported login" && $0.folderName == "Imported" },
                  "export contains the imported item with its folder")
        } else { check(false, "export builds") }
        // leave the demo vault as it was
        for e in state.entries where e.name.hasPrefix("Imported") { state.requestDelete(e); await state.confirmDelete() }

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

    /// `--selftest-live` with `VB_LIVE=/path/to/creds.json`: the whole app flow against a real server
    /// (Vaultwarden): the same SetupModel the UI uses, then CRUD, lock/unlock and logout.
    static func runLive(state: AppState, bar: StatusBarController) async -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS  \(what)" : "FAIL  \(what)")
            if !ok { failures += 1 }
        }
        guard let path = ProcessInfo.processInfo.environment["VB_LIVE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let email = creds["email"], let password = creds["password"], let server = creds["server"] else {
            print("FAIL  VB_LIVE credentials file missing"); return false
        }

        check(state.phase == .needsSetup, "fresh app starts at the setup screen")
        let model = SetupModel(state: state)
        model.kind = .selfHosted; model.selfURL = server
        model.email = "not an email"
        model.continueFromEmail()
        check(model.step == .email && model.error != nil, "an invalid email is refused on the first step")
        model.email = email
        model.continueFromEmail()
        check(model.step == .password && model.serverLabel == URL(string: server)?.host, "email step moves to the password step")
        model.password = "definitely wrong"
        await model.submitLogin()
        check(model.step == .password && model.error == t("lock.wrongPassword"), "wrong password is reported in the password step")
        model.password = password
        await model.submitLogin()
        check(model.step == .finish && model.error == nil, "correct login reaches the finish step")
        model.enableTouchID = false; model.enableLoginItem = false
        await model.finish()
        check(state.phase == .unlocked && state.settings.activeAccount?.email == email, "finish unlocks and records the account")
        check(state.settings.activeAccount?.server == .selfHosted(server), "the account remembers its server")

        // CRUD through the same AppState calls the UI makes
        state.beginAdd()
        state.editor?.name = "Live item"; state.editor?.username = "live@example.test"; state.editor?.password = "pw-live"
        state.editor?.totp = "JBSWY3DPEHPK3PXP"; state.editor?.uris = ["https://live.example.test"]
        await state.saveEditor()
        let created = state.entries.first { $0.name == "Live item" }
        check(created != nil && state.editor == nil, "item saved on the server")
        check(created?.totp != nil, "its authenticator key shows in the 2FA tab")
        if let created {
            state.beginEdit(created); state.editor?.name = "Live item v2"; state.editor?.password = "pw-live-2"
            await state.saveEditor()
            check(state.entries.first { $0.id == created.id }?.name == "Live item v2", "edit saved")
            let v2 = state.entries.first { $0.id == created.id }!
            await state.clone(v2)
            let clone = state.entries.first { $0.name == "Live item v2" + t("clone.suffix") }
            check(clone != nil, "clone created")
            if let clone { state.requestDelete(clone); await state.confirmDelete() }
            check(!state.entries.contains { $0.name.hasSuffix(t("clone.suffix")) }, "clone deleted (trash)")
        }

        // Lock, wrong password, unlock again from the cache
        await state.lock()
        check(state.phase == .locked && state.entries.isEmpty, "lock wipes the decrypted items")
        await state.unlock(password: "nope")
        check(state.phase == .locked && state.lockMessage == t("lock.wrongPassword"), "wrong master password is refused")
        await state.unlock(password: password)
        check(state.phase == .unlocked && state.entries.contains { $0.name == "Live item v2" }, "unlock restores the vault")
        await state.sync()
        check(state.entries.contains { $0.name == "Live item v2" }, "sync keeps the vault consistent")

        // Logout forgets everything local
        let dir = state.settings.activeAccount!.dataDirectory
        await state.logout()
        check(state.phase == .needsSetup && state.settings.accounts.isEmpty, "logout returns to setup")
        check(!FileManager.default.fileExists(atPath: dir.path), "logout deletes the cached vault")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }
}
