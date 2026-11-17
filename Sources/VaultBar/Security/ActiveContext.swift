import AppKit
import ApplicationServices
import VaultKit

/// Finds out what was in front when the popover opened, for "Suggested" items: the app, the browser's active tab
/// address (asked of the browser with a one-line AppleScript) and the focused window's title. It stays in memory.
@MainActor
enum ActiveContext {
    /// Scriptable browsers and how to ask each for the address of the page in front.
    private static let urlScripts: [String: String] = [
        "com.apple.Safari": "get URL of front document",
        "com.apple.SafariTechnologyPreview": "get URL of front document",
        "com.google.Chrome": "get URL of active tab of front window",
        "com.google.Chrome.beta": "get URL of active tab of front window",
        "com.brave.Browser": "get URL of active tab of front window",
        "com.microsoft.edgemac": "get URL of active tab of front window",
        "company.thebrowser.Browser": "get URL of active tab of front window",
        "com.vivaldi.Vivaldi": "get URL of active tab of front window",
        "com.operasoftware.Opera": "get URL of active tab of front window",
        "org.chromium.Chromium": "get URL of active tab of front window",
    ]

    /// The frontmost app other than VaultBar, or nil when VaultBar itself is in front.
    static func frontApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    static func capture(_ app: NSRunningApplication, includeBrowserURL: Bool) async -> SuggestionContext {
        let bundleID = app.bundleIdentifier
        var context = SuggestionContext(appName: app.localizedName ?? bundleID ?? "", bundleID: bundleID)
        context.windowTitle = windowTitle(of: app)
        if includeBrowserURL, let bundleID, let command = urlScripts[bundleID] {
            context.url = await runAppleScript("tell application id \"\(bundleID)\" to \(command)")
        }
        return context
    }

    /// Focused window title via Accessibility. Only when the permission is already granted; never prompts.
    private static func windowTitle(of app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return (title as? String)?.nonEmptyTrimmed
    }

    /// Runs `osascript` in a child process (so a slow or unresponsive browser cannot freeze the popover) with a short timeout.
    /// macOS asks the user once, per browser, whether VaultBar may control it.
    private static func runAppleScript(_ script: String) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do { try process.run() } catch { done.resume(returning: nil); return }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer) // long enough to answer the permission prompt
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: process.terminationStatus == 0 ? text?.nonEmptyTrimmed : nil)
            }
        }
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
