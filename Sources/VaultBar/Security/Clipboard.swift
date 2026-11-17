import AppKit

/// Copies secrets so clipboard managers skip them, and clears them again
/// after a delay, but only while the pasteboard still holds our value.
@MainActor
enum Clipboard {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private static var pendingClear: Task<Void, Never>?
    private static var ourChangeCount: Int?

    static func copy(_ value: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, concealed, transient], owner: nil)
        pb.setString(value, forType: .string)
        pb.setData(Data(), forType: concealed)
        pb.setData(Data(), forType: transient)
        ourChangeCount = pb.changeCount

        pendingClear?.cancel()
        guard seconds > 0 else { return }
        pendingClear = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            clearIfOurs()
        }
    }

    /// Clears the clipboard only if nothing else has been copied since.
    static func clearIfOurs() {
        pendingClear?.cancel()
        pendingClear = nil
        let pb = NSPasteboard.general
        if let ours = ourChangeCount, pb.changeCount == ours { pb.clearContents() }
        ourChangeCount = nil
    }
}
