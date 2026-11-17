import Foundation

/// The login handshake, step by step, so the UI can show a verification step when the
/// server asks for one (two-step code, or new-device e-mail code) instead of failing.
public final class NativeLogin: @unchecked Sendable {
    public enum Outcome {
        case success(NativeSession)
        case twoFactor(TwoFactorChallenge)
        case newDevice
    }

    private let account: Account
    private let api: BitwardenAPI
    private let secrets: SecretStore
    private var masterKey: Data?
    private var authHash: String?
    private var kdf: KDFConfig?
    private var salt: String?
    private var baseGrant: TokenGrant.Kind?
    private var twoFactor: (provider: TwoFactorProvider, code: String, remember: Bool)?

    public init(account: Account, api: BitwardenAPI, secrets: SecretStore) {
        self.account = account
        self.api = api
        self.secrets = secrets
    }

    /// First step. With `apiKey` set, the client id/secret authenticate (cloud accounts that hit a
    /// captcha need this); the master password is still required to decrypt the vault.
    public func start(password: String, apiKey: (id: String, secret: String)? = nil) async throws -> Outcome {
        let email = account.email.trimmingCharacters(in: .whitespaces).lowercased()
        let pre = try await api.prelogin(email: email)
        try pre.kdf.validate()
        kdf = pre.kdf
        salt = pre.salt
        // Heavy KDF work off the caller's thread.
        let derived: (Data, String) = try await Task.detached(priority: .userInitiated) {
            let master = try MasterKey.derive(password: password, email: pre.salt ?? email, kdf: pre.kdf)
            return (master, MasterKey.authHash(masterKey: master, password: password))
        }.value
        masterKey = derived.0
        authHash = derived.1
        if let apiKey { baseGrant = .apiKey(clientID: apiKey.id, clientSecret: apiKey.secret) }
        else { baseGrant = .password(email: email, authHash: derived.1) }
        twoFactor = nil
        return try await requestToken(newDeviceOTP: nil)
    }

    public func submitTwoFactor(provider: TwoFactorProvider, code: String, remember: Bool = false) async throws -> Outcome {
        twoFactor = (provider, code.trimmingCharacters(in: .whitespaces), remember)
        return try await requestToken(newDeviceOTP: nil)
    }

    public func submitNewDeviceCode(_ code: String) async throws -> Outcome {
        try await requestToken(newDeviceOTP: code.trimmingCharacters(in: .whitespaces))
    }

    public func sendEmailCode() async throws {
        guard let authHash else { throw VaultError.notLoggedIn }
        try await api.sendEmailLoginCode(email: account.email.trimmingCharacters(in: .whitespaces).lowercased(), authHash: authHash)
    }

    private func requestToken(newDeviceOTP: String?) async throws -> Outcome {
        guard let baseGrant else { throw VaultError.notLoggedIn }
        do {
            let response = try await api.token(TokenGrant(baseGrant, twoFactor: twoFactor, newDeviceOTP: newDeviceOTP))
            return .success(try await complete(response))
        } catch VaultError.twoFactor(let challenge) {
            return .twoFactor(challenge)
        } catch VaultError.newDeviceVerification {
            return .newDevice
        }
    }

    private func complete(_ r: TokenResponse) async throws -> NativeSession {
        guard let masterKey, let wrappedString = r.key, let wrapped = EncString(wrappedString) else { throw VaultError.badResponse }
        let userKeyBytes: Data
        do { userKeyBytes = try wrapped.decrypt(with: MasterKey.stretch(masterKey)) }
        catch CryptoError.macMismatch { throw VaultError.invalidPassword }
        let userKey = try VaultKey(bytes: userKeyBytes)

        let storage = AccountStorage(directory: account.dataDirectory)
        let record = AccountRecord(kdf: kdf ?? KDFConfig(), kdfSalt: salt, encryptedUserKey: wrappedString, encryptedPrivateKey: r.privateKey)
        do {
            try storage.saveRecord(record)
            let session = NativeSession(account: account, secrets: secrets, api: api, storage: storage)
            session.adopt(userKey: userKey, sync: nil)
            session.setTokens(access: r.accessToken, expiresIn: r.expiresIn, refresh: r.refreshToken)
            try await session.sync() // first download; also proves the token works
            wipeSecrets()
            return session
        } catch {
            storage.wipe() // never leave a half-created account behind
            secrets.remove(account.refreshTokenKey)
            throw error
        }
    }

    private func wipeSecrets() { masterKey = nil; authHash = nil }
}
