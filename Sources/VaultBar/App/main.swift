import AppKit

// Plain AppKit entry point. `--demo` runs against a fake vault (screenshots,
// development); nothing real is read or written in that mode.
let args = CommandLine.arguments
let snapshotDir: URL? = args.firstIndex(of: "--snapshot-dir").flatMap { i in
    args.indices.contains(i + 1) ? URL(fileURLWithPath: args[i + 1]) : nil
}
let selfTest = args.contains("--selftest")
let demo = args.contains("--demo") || snapshotDir != nil || selfTest

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(demo: demo, snapshotDir: snapshotDir, selfTest: selfTest)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
