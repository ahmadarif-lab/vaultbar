import AppKit
import SwiftUI

/// `--snapshot-dir <dir>`: renders the real views, fed with the fake demo
/// vault, to PNGs for the README. Never touches a real vault.
@MainActor
enum Snapshot {
    static func run(state: AppState, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        settings.language = .en

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            state.query = ""
            state.detailEntryID = nil
            await shot(PopoverView(state: state), size: pop, dark: dark, name: "list\(suffix)", dir: dir)

            state.query = "git"
            await shot(PopoverView(state: state), size: pop, dark: dark, name: "search\(suffix)", dir: dir)

            state.query = ""
            if let github = state.entries.first(where: { $0.id == "d01" }) { state.openDetail(github) }
            await shot(PopoverView(state: state), size: pop, dark: dark, name: "detail\(suffix)", dir: dir)
            state.closeDetail()

            await state.lock()
            await shot(PopoverView(state: state), size: pop, dark: dark, name: "locked\(suffix)", dir: dir)
            await state.unlock(password: "demo")
        }

        settings.language = .id
        await shot(PopoverView(state: state), size: pop, dark: false, name: "list-id", dir: dir)
        settings.language = .en

        await shot(SettingsView(state: state), size: CGSize(width: 460, height: 520), dark: false, name: "settings", dir: dir, framed: false)
        let model = SetupModel(state: state)
        await shot(SetupView(model: model), size: CGSize(width: 420, height: 460), dark: false, name: "setup", dir: dir, framed: false)

        print("Snapshots written to \(dir.path)")
    }

    private static let pop = CGSize(width: PopoverMetrics.width, height: PopoverMetrics.height)

    private static func shot<V: View>(_ view: V, size: CGSize, dark: Bool, name: String, dir: URL, framed: Bool = true) async {
        let content: AnyView = framed
            ? AnyView(view.clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8).padding(32))
            : AnyView(view)
        let total = framed ? CGSize(width: size.width + 64, height: size.height + 64) : size
        let host = NSHostingView(rootView: content.frame(width: total.width, height: total.height).background(framed ? AnyView(backdrop(dark)) : AnyView(EmptyView())))
        host.frame = NSRect(origin: .zero, size: total)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000)) // off-screen but still rendered
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }

    private static func backdrop(_ dark: Bool) -> some View {
        LinearGradient(colors: dark ? [Color(nsColor: NSColor(hex: 0x2A2D45)), Color(nsColor: NSColor(hex: 0x14151F))]
                                    : [Color(nsColor: NSColor(hex: 0xC9D2FF)), Color(nsColor: NSColor(hex: 0xEFE6FF))],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
