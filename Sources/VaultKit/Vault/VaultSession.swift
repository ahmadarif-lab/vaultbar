import Foundation

public enum TwoFactorProvider: Int, Sendable, CaseIterable {
    case authenticator = 0, email = 1, duo = 2, yubikey = 3, u2f = 4, remember = 5, organizationDuo = 6, webAuthn = 7
    /// Providers VaultBar can complete: they all come down to typing a code.
    public var isSupported: Bool { self == .authenticator || self == .email || self == .yubikey }
}

/// The server wants a second factor before it hands out a token.
public struct TwoFactorChallenge: Equatable, Sendable {
    public var providers: [TwoFactorProvider]
    /// Masked address the e-mail code was (or will be) sent to.
    public var emailHint: String?
    public var supported: [TwoFactorProvider] { providers.filter(\.isSupported) }
    public init(providers: [TwoFactorProvider], emailHint: String? = nil) { self.providers = providers; self.emailHint = emailHint }
}

public enum VaultError: Error, LocalizedError, Equatable {
    case twoFactor(TwoFactorChallenge)
    case invalidTwoFactorCode
    case newDeviceVerification
    case captchaRequired
    case network(String)
    case server(String)
    case unsupported(String)
    /// The server answered OK but its copy of the item differs from what was sent (field names, never values).
    case serverIgnored([String])
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
        case .twoFactor: return "A two-step login code is required."
        case .invalidTwoFactorCode: return "That verification code is not valid."
        case .newDeviceVerification: return "Enter the verification code sent to your e-mail to approve this device."
        case .captchaRequired: return "The server asked for a captcha. Log in with an API key instead."
        case .network(let m): return "Network error: \(m)"
        case .server(let m): return m
        case .serverIgnored(let fields): return "The server accepted the save but did not apply: \(fields.joined(separator: ", ")). Other changes were saved."
        case .unsupported(let m): return "Not supported yet: \(m)"
        case .organizationItem: return "Organization items can't be cloned here."
        }
    }
}

/// What the app needs from a vault source. `NativeSession` is the real one (the
/// Bitwarden API), `DemoSession` serves fake data for screenshots and tests.
public protocol VaultSession: AnyObject, Sendable {
    /// True when the last save kept the authenticator key in a hidden field because the server drops `login.totp`.
    var lastSaveUsedKeyField: Bool { get }
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
    /// Adds already de-duplicated items (and any missing folders) in bulk.
    func importEntries(_ request: ImportRequest) async throws
}


public extension VaultSession {
    var lastSaveUsedKeyField: Bool { false }
}
