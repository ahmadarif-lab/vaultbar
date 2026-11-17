import Foundation

public enum VaultError: Error, LocalizedError, Equatable {
    case cliMissing
    case invalidPassword
    case twoFactorRequired
    case notLoggedIn
    case serverNotReady
    case commandFailed(String)
    case http(Int)
    case badResponse
    case organizationItem

    public var errorDescription: String? {
        switch self {
        case .cliMissing: return "The bw command line tool was not found."
        case .invalidPassword: return "Wrong master password."
        case .twoFactorRequired: return "A two-step login code is required."
        case .notLoggedIn: return "Not logged in."
        case .serverNotReady: return "The local vault service did not start."
        case .commandFailed(let message): return message
        case .http(let code): return "The local vault service returned HTTP \(code)."
        case .badResponse: return "Unexpected response from the local vault service."
        case .organizationItem: return "Organization items can't be cloned here."
        }
    }
}

/// What the app needs from a vault source. `BWSession` is the real one (the
/// official `bw` CLI), `DemoSession` serves fake data for screenshots and tests.
public protocol VaultSession: AnyObject, Sendable {
    func unlock(password: String) async throws
    func lock() async
    func sync() async throws
    func snapshot() async throws -> VaultSnapshot
    /// Creates the item (draft.id == nil) or updates it.
    func save(_ draft: ItemDraft) async throws
    /// Copies a personal item; the copy's name gets `nameSuffix`.
    func clone(id: String, nameSuffix: String) async throws
    /// Moves the item to the trash (recoverable from the web vault).
    func delete(id: String) async throws
}
