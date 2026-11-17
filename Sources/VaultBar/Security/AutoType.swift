import AppKit
import ApplicationServices
import VaultKit

/// "Auto-type": sends keystrokes to whatever has focus, like a keyboard. Works in any app and any browser
/// (no extension needed); nothing goes through the clipboard. Needs the Accessibility permission.
@MainActor
enum AutoType {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "VaultBar would like to control this computer" prompt.
    static func promptForAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Waits until another app is in front (the popover has closed and focus went back), then types.
    /// Returns false when there was no app to type into.
    static func typeIntoFrontApp(_ steps: [AutoTypeStep]) async -> Bool {
        let me = Bundle.main.bundleIdentifier
        var waited = 0
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier == me, waited < 30 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != me else { return false }
        try? await Task.sleep(nanoseconds: 150_000_000) // let the target window take focus
        await releaseModifiers()
        await perform(steps)
        return true
    }

    /// A hotkey such as ⌘↩ may still be held; typing into it would turn letters into shortcuts.
    private static func releaseModifiers() async {
        var waited = 0
        while !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, waited < 40 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            waited += 1
        }
    }

    private static func perform(_ steps: [AutoTypeStep]) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for step in steps {
            switch step {
            case .text(let text):
                for chunk in AutoTypePlan.chunks(of: text) {
                    postText(chunk, source: source)
                    try? await Task.sleep(nanoseconds: 8_000_000)
                }
            case .tab:
                try? await Task.sleep(nanoseconds: 60_000_000)
                postKey(48, source: source)
                try? await Task.sleep(nanoseconds: 90_000_000) // let the next field take focus
            case .enter:
                try? await Task.sleep(nanoseconds: 120_000_000)
                postKey(36, source: source)
            }
        }
    }

    private static func postText(_ text: String, source: CGEventSource?) {
        let units = Array(text.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postKey(_ code: CGKeyCode, source: CGEventSource?) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
}
