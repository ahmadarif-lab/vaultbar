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
            func popover(_ name: String) async {
                await shot(PopoverView(state: state), size: pop, dark: dark, name: "\(name)\(suffix)", dir: dir)
            }
            state.tab = .vault
            state.query = ""
            state.detailEntryID = nil
            await popover("list")

            state.query = "git"
            await popover("search")

            state.query = ""
            if let github = state.entries.first(where: { $0.id == "d01" }) { state.openDetail(github) }
            await popover("detail")
            state.closeDetail()

            state.tab = .generator
            await popover("generator")

            state.tab = .authenticator
            await popover("twofa")

            state.tab = .settings
            await popover("settings-tab")

            state.tab = .vault
            state.showAccounts = true
            await popover("accounts")
            state.showAccounts = false

            state.tab = .settings
            state.showAbout = true
            await popover("about")
            state.showAbout = false
            state.showFolders = true
            await popover("folders")
            state.showFolders = false
            state.tab = .vault

            if let github = state.entries.first(where: { $0.id == "d01" }) { state.beginEdit(github) }
            await popover("editor")
            state.cancelEditor()

            if let router = state.entries.first(where: { $0.id == "d09" }) { state.requestDelete(router) }
            await popover("delete")
            state.cancelDelete()

            await state.lock()
            await popover("locked")
            await state.unlock(password: "demo")
        }

        settings.language = .id
        state.tab = .vault
        await shot(PopoverView(state: state), size: pop, dark: false, name: "list-id", dir: dir)
        settings.language = .en

        await shot(ZStack { Theme.background; NeedsSetupView(state: state) }.frame(width: PopoverMetrics.width, height: PopoverMetrics.height),
                   size: pop, dark: false, name: "setup", dir: dir)

        await hero(state: state, into: dir)

        print("Snapshots written to \(dir.path)")
    }

    // MARK: Hero

    /// `hero.png`: the README banner, 2000x1100. Real popovers (dark, demo data) on a gradient with the name and tagline.
    private static func hero(state: AppState, into dir: URL) async {
        state.query = ""
        state.detailEntryID = nil
        state.tab = .vault
        let vault = await raster(PopoverView(state: state), size: pop, dark: true)
        state.tab = .authenticator
        let twofa = await raster(PopoverView(state: state), size: pop, dark: true)
        state.tab = .generator
        let generator = await raster(PopoverView(state: state), size: pop, dark: true)
        state.tab = .vault
        guard let vault, let twofa, let generator else { return }

        let renderer = ImageRenderer(content: HeroView(vault: vault, twofa: twofa, generator: generator, icon: NSApp.applicationIconImage))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("hero.png"))
    }

    /// The view alone (no backdrop, no frame) as an image.
    private static func raster<V: View>(_ view: V, size: CGSize, dark: Bool) async -> NSImage? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
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

private struct HeroView: View {
    let vault: NSImage
    let twofa: NSImage
    let generator: NSImage
    let icon: NSImage

    private let scale: CGFloat = 0.74

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x4F6BFF)), Color(nsColor: NSColor(hex: 0x5B3FD9)), Color(nsColor: NSColor(hex: 0x8A4FE0))],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(nsColor: NSColor(hex: 0x22D3A8)).opacity(0.75), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(nsColor: NSColor(hex: 0x7FA2FF)).opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 360)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 18) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    Text("VaultBar").font(.system(size: 66, weight: .bold)).foregroundStyle(.white)
                }
                Text("Your password vault, one click away in the menu bar.")
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(.white).padding(.top, 20)
                    .frame(width: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Text("Search, copy and 2FA codes. No browser, no CLI.")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(.white.opacity(0.78)).padding(.top, 6)
                    .frame(width: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    pill("Bitwarden · Vaultwarden")
                    pill("Touch ID")
                    pill("Live 2FA codes")
                }
                .padding(.top, 24)
            }
            .padding(.leading, 56).padding(.top, 44)

            popover(vault).offset(x: 490, y: 34)
            popover(twofa).offset(x: 714, y: 104)
            popover(generator).offset(x: 70, y: 352)
        }
        .frame(width: 1000, height: 550, alignment: .topLeading)
        .clipped()
    }

    private func popover(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().interpolation(.high)
            .frame(width: image.size.width * scale, height: image.size.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.38), radius: 22, y: 10)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 13).frame(height: 34)
            .background(Capsule().fill(.white.opacity(0.16)))
            .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 1))
    }
}
