import AppKit
import VaultKit

/// A menu item that runs a closure. NSMenuItem only knows target/action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

/// The ⋮ menu of an item (copy, open, edit, clone, delete) as a real NSMenu.
///
/// SwiftUI's `Menu` is a native pop-up button that forces the arrow cursor, so a plain
/// button opens this menu instead and can show the pointing hand like the other buttons.
@MainActor
enum ItemMenu {
    static func make(state: AppState, entry: VaultEntry, includeView: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, symbol: symbol, handler: run)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if includeView { add(t("menu.view"), "eye") { state.openDetail(entry) } }
        add(t("menu.edit"), "pencil") { state.beginEdit(entry) }
        menu.addItem(.separator())
        for option in copyOptions(state: state, entry: entry) { add(option.title, option.symbol, option.run) }
        if entry.type == .login, let url = entry.uris.lazy.compactMap(openableURL).first {
            add(t("menu.open"), "arrow.up.right.square") { NSWorkspace.shared.open(url) }
        }
        menu.addItem(.separator())
        add(t("menu.clone"), "doc.on.doc", enabled: entry.item.organizationId == nil) { Task { await state.clone(entry) } }
        add(t("menu.delete"), "trash") { state.requestDelete(entry) }
        return menu
    }

    struct CopyOption {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    /// Everything the copy button can copy for this item (username, password, code; card number, security code).
    static func copyOptions(state: AppState, entry: VaultEntry) -> [CopyOption] {
        switch entry.type {
        case .login:
            var list: [CopyOption] = []
            if entry.username != nil { list.append(.init(title: t("menu.copyUser"), symbol: "person") { state.copyUsername(entry) }) }
            if entry.password != nil { list.append(.init(title: t("menu.copyPassword"), symbol: "key") { state.copyPassword(entry) }) }
            if entry.totp != nil { list.append(.init(title: t("menu.copyCode"), symbol: "clock") { state.copyCode(entry) }) }
            return list
        case .card:
            var list: [CopyOption] = []
            if entry.item.card?.number != nil {
                list.append(.init(title: t("menu.copyNumber"), symbol: "creditcard") { state.copyValue(entry.item.card?.number, missingKey: "toast.noUsername") })
            }
            if entry.item.card?.code != nil {
                list.append(.init(title: t("menu.copySecurity"), symbol: "lock") { state.copyValue(entry.item.card?.code, missingKey: "toast.noUsername") })
            }
            return list
        case .identity, .secureNote:
            return []
        }
    }

    /// The copy button: one choice copies right away, several open a small menu (like the extension).
    static func copyButtonPressed(state: AppState, entry: VaultEntry) {
        let options = copyOptions(state: state, entry: entry)
        if options.count == 1 { options[0].run(); return }
        guard !options.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options { menu.addItem(ClosureMenuItem(title: option.title, symbol: option.symbol, handler: option.run)) }
        popUp(menu)
    }

    /// The "Scan QR code" choices: from the screen, an image file or the clipboard.
    static func popUpQRChoices(state: AppState) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, symbol, source) in [(t("qr.screen"), "viewfinder", AppState.QRSource.screen),
                                        (t("qr.file"), "photo", .file),
                                        (t("qr.clipboard"), "doc.on.clipboard", .clipboard)] {
            menu.addItem(ClosureMenuItem(title: title, symbol: symbol) { Task { await state.scanAuthenticatorQR(from: source) } })
        }
        popUp(menu)
    }

    /// Opens the menu at the mouse position in the popover's window.
    static func popUp(_ menu: NSMenu) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView else { return }
        menu.popUp(positioning: nil, at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: view)
    }
}
