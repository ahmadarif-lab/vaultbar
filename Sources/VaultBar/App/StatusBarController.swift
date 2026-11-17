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

        state.showToast = { [weak self] text in self?.toast.show(text, below: self?.statusItem.button) }
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

    func toggle() {
        popover.isShown ? close() : show()
    }

    func show() {
        guard let button = statusItem.button, !popover.isShown else { return }
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
        // Hand focus back to the app the user was in, so ⌘V lands there.
        NSApp.hide(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let lockItem = NSMenuItem(title: t("menu.lock"), action: #selector(lockFromMenu), keyEquivalent: "")
        lockItem.target = self
        lockItem.isEnabled = state.phase == .unlocked
        menu.addItem(lockItem)
        let settings = NSMenuItem(title: t("menu.settings"), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // otherwise left clicks would open the menu too
    }

    @objc private func lockFromMenu() { state.lockNow() }

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
        if keyCode == 53 { // esc
            if state.phase == .unlocked, state.detailEntryID != nil { state.closeDetail() }
            else if state.phase == .unlocked, !state.query.isEmpty { state.query = "" }
            else { close() }
            return true
        }
        guard state.phase == .unlocked else { return false }
        state.noteActivity()

        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        let cursorAtEnd = editor.map { $0.selectedRange.length == 0 && $0.selectedRange.location >= ($0.string as NSString).length } ?? true

        if flags == .command {
            switch key {
            case "c":
                if let editor, editor.selectedRange.length > 0 { return false } // let real text copy work
                if let e = state.targetEntry { state.copyUsername(e) }
                return true
            case "t":
                if let e = state.targetEntry { state.copyCode(e) }
                return true
            case "l":
                state.lockNow(); return true
            case ",":
                NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil); return true
            default: return false
            }
        }
        guard flags.isEmpty else { return false }

        switch keyCode {
        case 125 where state.detailEntryID == nil: state.moveSelection(1); return true  // down
        case 126 where state.detailEntryID == nil: state.moveSelection(-1); return true // up
        case 36, 76: // return
            if let e = state.targetEntry { state.copyPassword(e) }
            return true
        case 124 where state.detailEntryID == nil && cursorAtEnd: // right
            if let e = state.selectedEntry { state.openDetail(e); return true }
            return false
        case 123 where state.detailEntryID != nil: // left
            state.closeDetail(); return true
        default: return false
        }
    }
}
