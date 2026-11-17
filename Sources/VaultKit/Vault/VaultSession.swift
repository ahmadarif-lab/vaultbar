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
}
