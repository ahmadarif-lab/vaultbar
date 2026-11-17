import Foundation

/// After a save, the item is fetched back from the server and compared with what the user asked for.
/// Only field *names* are reported, never values.
public enum SaveVerifier {
    public static func differences(draft: ItemDraft, server: VaultItem) -> [String] {
        func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [String] = []
        if trimmed(draft.name) != trimmed(server.name) { out.append("name") }
        if trimmed(draft.notes) != trimmed(server.notes) { out.append("notes") }
        if draft.favorite != (server.favorite ?? false) { out.append("favorite") }
        if draft.folderId != server.folderId { out.append("folder") }
        if draft.type == .login {
            if trimmed(draft.username) != trimmed(server.login?.username) { out.append("username") }
            if draft.password != (server.login?.password ?? "") { out.append("password") }
            if trimmed(draft.totp) != trimmed(server.authenticatorKey) { out.append("authenticator key") }
            let wanted = draft.uris.map(trimmed).filter { !$0.isEmpty }
            let got = (server.login?.uris ?? []).compactMap(\.uri).map(trimmed).filter { !$0.isEmpty }
            if wanted != got { out.append("website") }
        }
        return out
    }
}
