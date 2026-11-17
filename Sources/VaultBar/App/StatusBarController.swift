import AppKit
import SwiftUI
import VaultKit

/// Status item + popover. An NSPopover rather than SwiftUI's MenuBarExtra so
/// the global hotkey can open it, search focus is reliable and key handling
/// (arrows, return, ⌘C, ⌘T) goes through one local monitor.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let toast = ToastPanel()
    private var keyMonitor: Any?

    init(state: AppState) {
        self.state = state
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height)
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state))

        if let button = statusItem.button {
            button.image = MenuBarIcon.image(locked: state.phase != .unlocked)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        state.showToast = { [weak self] text in
            guard let self else { return }
            let window = self.popover.isShown ? self.popover.contentViewController?.view.window : nil
            self.toast.show(text, below: self.statusItem.button, inside: window)
        }
        state.closePopover = { [weak self] in self?.close() }
        state.lockChanged = { [weak self] locked in self?.statusItem.button?.image = MenuBarIcon.image(locked: locked) }
    }

    // MARK: Toggle

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle() {
        popover.isShown ? close() : show()
    }

    func show(retries: Int = 10) {
        guard !popover.isShown else { return }
        // Right after launch the status item has no window yet; try again shortly.
        guard let button = statusItem.button, button.window != nil else {
            if retries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.show(retries: retries - 1) } }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        state.noteActivity()
        state.focusToken += 1
        installKeyMonitor()
        if state.phase == .locked { Task { await state.unlockWithBiometrics() } }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        // Hand focus back to the app the user was in, so ⌘V lands there. But never hide
        // the app while Settings or Setup is open: hide() would take that window with it.
        let otherWindowOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if !otherWindowOpen && !state.keepAppActive { NSApp.hide(nil) }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let lockItem = NSMenuItem(title: t("menu.lock"), action: #selector(lockFromMenu), keyEquivalent: "")
        lockItem.target = self
        lockItem.isEnabled = state.phase == .unlocked
        menu.addItem(lockItem)
        let settings = NSMenuItem(title: t("menu.settings"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = state.phase == .unlocked
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // otherwise left clicks would open the menu too
    }

    @objc private func lockFromMenu() { state.lockNow() }
    @objc private func openSettingsFromMenu() { state.openSettingsTab() }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Pull plain values out first: NSEvent itself is not Sendable.
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let consumed = MainActor.assumeIsolated { self.popover.isShown && self.handle(keyCode: keyCode, flags: flags, key: key) }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was consumed.
    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String) -> Bool {
        let unlocked = state.phase == .unlocked

        // Recording a new global hotkey takes every key, including esc (cancel).
        if unlocked, state.isRecordingHotkey {
            state.recordHotkey(keyCode: keyCode, flags: flags)
            return true
        }

        if keyCode == 53 { // esc
            if state.addingAccount { state.cancelAddAccount() }
            else if state.showAccounts { state.showAccounts = false; state.confirmLogoutAccount = false }
            else if unlocked, state.showAbout { state.showAbout = false }
            else if unlocked, state.showFolders { state.showFolders = false; state.folderError = nil }
            else if unlocked, state.editor != nil { state.cancelEditor() }
            else if unlocked, state.pendingDeleteID != nil { state.cancelDelete() }
            else if unlocked, state.tab == .vault, state.detailEntryID != nil { state.closeDetail() }
            else if unlocked, !state.query.isEmpty { state.query = "" }
            else { close() }
            return true
        }
        guard unlocked else { return false }
        state.noteActivity()

        if state.showAccounts || state.addingAccount { return false }

        // While editing (or confirming a delete) every other key belongs to the form; ⌘S saves.
        if state.editor != nil, flags == .command, key == "s" { Task { await state.saveEditor() }; return true }
        if state.editor != nil || state.pendingDeleteID != nil { return false }

        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        let cursorAtEnd = editor.map { $0.selectedRange.length == 0 && $0.selectedRange.location >= ($0.string as NSString).length } ?? true
        let listTab = state.tab == .vault || state.tab == .authenticator

        if flags == .command {
            switch key {
            case "1": state.tab = .vault; return true
            case "2": state.tab = .generator; return true
            case "3": state.tab = .authenticator; return true
            case "4": state.tab = .settings; return true
            case "n": if state.tab == .vault { state.beginAdd() }; return true
            case "e": if state.tab == .vault, let e = state.targetEntry { state.beginEdit(e) }; return true
            case "r": if state.tab == .generator { state.generator.regenerate() }; return true
            case "c":
                if let editor, editor.selectedRange.length > 0 { return false } // let real text copy work
                if state.tab == .generator { state.copyValue(state.generator.value, missingKey: "toast.copied") }
                else if listTab, let e = state.targetEntry { state.copyUsername(e) }
                return true
            case "t":
                if listTab, let e = state.targetEntry { state.copyCode(e) }
                return true
            case "l":
                state.lockNow(); return true
            case ",":
                state.openSettingsTab(); return true
            default: return false
            }
        }
        guard flags.isEmpty else { return false }

        switch keyCode {
        case 125 where listTab && state.detailEntryID == nil: state.moveSelection(1); return true  // down
        case 126 where listTab && state.detailEntryID == nil: state.moveSelection(-1); return true // up
        case 36, 76: // return
            switch state.tab {
            case .generator: state.copyValue(state.generator.value, missingKey: "toast.copied")
            case .authenticator: if let e = state.targetEntry { state.copyCode(e) }
            case .vault: if let e = state.targetEntry { state.copyPassword(e) }
            case .settings: return false
            }
            return true
        case 124 where state.tab == .vault && state.detailEntryID == nil && cursorAtEnd: // right
            if let e = state.selectedEntry { state.openDetail(e); return true }
            return false
        case 123 where state.tab == .vault && state.detailEntryID != nil: // left
            state.closeDetail(); return true
        default: return false
        }
    }
}
