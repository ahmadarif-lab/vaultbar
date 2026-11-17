import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    private var statusBar: StatusBarController?
    private let hotkey = GlobalHotkey()

    private let snapshotDir: URL?

    private let selfTest: Bool

    init(demo: Bool, snapshotDir: URL? = nil, selfTest: Bool = false) {
        state = AppState(demo: demo)
        self.snapshotDir = snapshotDir
        self.selfTest = selfTest
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherCopyIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = Self.mainMenu()

        let bar = StatusBarController(state: state)
        statusBar = bar
        state.openSetup = { [weak bar] in bar?.show() }
        state.requestShowPopover = { [weak bar] in bar?.show() }

        hotkey.onPress = { [weak bar] in bar?.toggle() }
        AppSettings.shared.onHotkeyChanged = { [weak self] in self?.applyHotkey() }
        applyHotkey()

        Task {
            await state.bootstrap()
            if selfTest {
                let ok = await SelfTest.run(state: state, bar: bar)
                exit(ok ? 0 : 1)
            }
            if let dir = snapshotDir {
                await Snapshot.run(state: state, into: dir)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    /// Opening VaultBar again (Finder, Spotlight) opens the popover: the way in
    /// when the menu bar is crowded and the icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.show()
        return false
    }

    private func applyHotkey() {
        let s = AppSettings.shared
        if s.hotkeyEnabled && !state.isRecordingHotkey { hotkey.register(keyCode: s.hotkeyKeyCode, modifiers: s.hotkeyModifiers) } else { hotkey.unregister() }
    }

    // MARK: Menu and single instance

    /// An accessory app has no menu bar, but AppKit still resolves ⌘C/⌘V/⌘A
    /// through the main menu: without an Edit menu, pasting into the password
    /// fields does nothing. (There are no separate windows: everything, including
    /// setup and settings, lives in the popover.)
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit VaultBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    private func anotherCopyIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier }
            .contains { other in
                guard let a = other.launchDate, let b = me.launchDate else { return false }
                return a < b
            }
    }
}
