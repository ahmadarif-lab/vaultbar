import AppKit
import SwiftUI

/// A small floating confirmation under the menu bar icon (or over the open popover's
/// bottom edge). It lives in its own non-activating panel so it survives the popover closing.
@MainActor
final class ToastPanel {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, below button: NSStatusBarButton?, inside popoverWindow: NSWindow? = nil) {
        hideTask?.cancel()
        let hosting = NSHostingView(rootView: ToastView(text: text))
        let size = hosting.fittingSize
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            p.ignoresMouseEvents = true
            self.panel = p
            return p
        }()
        panel.contentView = hosting
        panel.setContentSize(size)

        var origin = NSPoint(x: 100, y: 100)
        if let button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 8)
            if let screen = window.screen {
                origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
            }
        }
        if let popoverWindow {
            // The popover stays open: float the toast just above its tab bar instead of over the header.
            origin = NSPoint(x: popoverWindow.frame.midX - size.width / 2, y: popoverWindow.frame.minY + 64)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }
}

private struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text(text).foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.stroke))
        .padding(10) // room for the shadow
    }
}
