import Foundation

public struct Endpoints: Sendable {
    public let identity: URL
    public let api: URL

    public init(server: ServerChoice) {
        switch server {
        case .bitwardenUS:
            identity = URL(string: "https://identity.bitwarden.com")!
            api = URL(string: "https://api.bitwarden.com")!
        case .bitwardenEU:
            identity = URL(string: "https://identity.bitwarden.eu")!
            api = URL(string: "https://api.bitwarden.eu")!
        case .selfHosted(let base):
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            identity = URL(string: trimmed + "/identity")!
            api = URL(string: trimmed + "/api")!
        }
    }
}

/// Bitwarden's servers refuse requests without `Bitwarden-Client-Version` ("to prevent encryption errors"):
/// the server uses it to decide which crypto features a client understands. This is the feature level
/// VaultBar implements (AES-CBC + HMAC EncStrings, per-item keys, RSA organization keys), not an app version.
public enum ClientIdentity {
    public static let name = "desktop"
    public static let version = "2025.1.0"
}

public struct DeviceInfo: Sendable {
    public let identifier: String
    public let name: String
    /// Bitwarden device type: 7 = macOS desktop.
    public let type: Int
    public init(identifier: String, name: String = "VaultBar", type: Int = 7) {
        self.identifier = identifier; self.name = name; self.type = type
    }
}

public struct TokenGrant: Sendable {
    public enum Kind: Sendable {
        case password(email: String, authHash: String)
        case apiKey(clientID: String, clientSecret: String)
        case refresh(String)
    }
    public var kind: Kind
    public var twoFactor: (provider: TwoFactorProvider, code: String, remember: Bool)?
    public var newDeviceOTP: String?
    public init(_ kind: Kind, twoFactor: (provider: TwoFactorProvider, code: String, remember: Bool)? = nil, newDeviceOTP: String? = nil) {
        self.kind = kind; self.twoFactor = twoFactor; self.newDeviceOTP = newDeviceOTP
    }
}

public struct TokenResponse: @unchecked Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: Int
    public var key: String?
    public var privateKey: String?
    public var kdf: KDFConfig?
    public var kdfSalt: String?
    public var raw: [String: Any]
}

/// HTTP calls to a Bitwarden-compatible server (cloud US/EU, self-hosted, Vaultwarden).
public struct BitwardenAPI: @unchecked Sendable {
    public let endpoints: Endpoints
    public let device: DeviceInfo
    private let session: URLSession

    public init(server: ServerChoice, device: DeviceInfo, session: URLSession? = nil) {
        endpoints = Endpoints(server: server)
        self.device = device
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.urlCache = nil
            c.timeoutIntervalForRequest = 30
            c.httpCookieStorage = nil
            self.session = URLSession(configuration: c)
        }
    }

    // MARK: Plumbing

    static func addClientHeaders(_ req: inout URLRequest) {
        req.setValue(ClientIdentity.name, forHTTPHeaderField: "Bitwarden-Client-Name")
        req.setValue(ClientIdentity.version, forHTTPHeaderField: "Bitwarden-Client-Version")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw VaultError.network(error.localizedDescription)
        }
    }

    private func jsonRequest(_ method: String, _ url: URL, body: [String: Any]? = nil, bearer: String? = nil) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.addClientHeaders(&req)
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Best human-readable message out of an error body.
    static func message(from data: Data) -> String? {
        guard let obj = try? JSONUtil.parseObject(data) else { return nil }
        if let model = obj["errorModel"] as? [String: Any], let m = JSONUtil.string(model, "message") { return m }
        return JSONUtil.string(obj, "message") ?? JSONUtil.string(obj, "error_description") ?? JSONUtil.string(obj, "error")
    }

    // MARK: Identity

    /// `GET /config`: the server software version (nil when the server does not publish one).
    public func serverVersion() async -> String? {
        guard let req = try? jsonRequest("GET", endpoints.api.appendingPathComponent("config")),
              let (data, status) = try? await perform(req), (200..<300).contains(status),
              let obj = try? JSONUtil.parseObject(data) else { return nil }
        return (obj["version"] as? String)?.nonEmpty
    }

    public func prelogin(email: String) async throws -> (kdf: KDFConfig, salt: String?) {
        let req = try jsonRequest("POST", endpoints.identity.appendingPathComponent("accounts/prelogin"), body: ["email": email])
        let (data, status) = try await perform(req)
        guard (200..<300).contains(status) else { throw VaultError.server(Self.message(from: data) ?? "HTTP \(status)") }
        let obj = try JSONUtil.parseObject(data)
        let type = JSONUtil.int(obj, "kdf") ?? 0
        let kdf = KDFConfig(type: type, iterations: JSONUtil.int(obj, "kdfIterations") ?? 600_000,
                            memory: JSONUtil.int(obj, "kdfMemory"), parallelism: JSONUtil.int(obj, "kdfParallelism"))
        return (kdf, JSONUtil.string(obj, "salt"))
    }

    public func token(_ grant: TokenGrant) async throws -> TokenResponse {
        var fields: [(String, String)] = [
            ("scope", "api offline_access"),
            ("deviceType", String(device.type)),
            ("deviceName", device.name),
            ("deviceIdentifier", device.identifier),
        ]
        switch grant.kind {
        case .password(let email, let hash):
            fields += [("grant_type", "password"), ("username", email), ("password", hash), ("client_id", "desktop")]
        case .apiKey(let id, let secret):
            fields = fields.filter { $0.0 != "scope" } + [("scope", "api"), ("grant_type", "client_credentials"), ("client_id", id), ("client_secret", secret)]
        case .refresh(let token):
            fields = [("grant_type", "refresh_token"), ("client_id", "desktop"), ("refresh_token", token)]
        }
        if let tf = grant.twoFactor {
            fields += [("twoFactorToken", tf.code), ("twoFactorProvider", String(tf.provider.rawValue)), ("twoFactorRemember", tf.remember ? "1" : "0")]
        }
        if let otp = grant.newDeviceOTP { fields.append(("newDeviceOtp", otp)) }

        var req = URLRequest(url: endpoints.identity.appendingPathComponent("connect/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.addClientHeaders(&req)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, status) = try await perform(req)
        if (200..<300).contains(status) {
            let obj = try JSONUtil.parseObject(data)
            guard let access = JSONUtil.string(obj, "access_token") else { throw VaultError.badResponse }
            return Self.tokenResponse(access: access, obj: obj)
        }
        throw Self.classifyTokenError(data: data, status: status)
    }

    static func tokenResponse(access: String, obj: [String: Any]) -> TokenResponse {
        var kdf: KDFConfig?
        var key = JSONUtil.string(obj, "key")
        var salt: String?
        if let opts = obj["userDecryptionOptions"] as? [String: Any], let unlock = opts["masterPasswordUnlock"] as? [String: Any] {
            key = key ?? JSONUtil.string(unlock, "masterKeyEncryptedUserKey") ?? JSONUtil.string(unlock, "masterKeyWrappedUserKey")
            salt = JSONUtil.string(unlock, "salt")
            if let k = unlock["kdf"] as? [String: Any], let type = JSONUtil.int(k, "kdfType") {
                kdf = KDFConfig(type: type, iterations: JSONUtil.int(k, "iterations") ?? 600_000, memory: JSONUtil.int(k, "memory"), parallelism: JSONUtil.int(k, "parallelism"))
            }
        }
        if kdf == nil, let type = JSONUtil.int(obj, "kdf") {
            kdf = KDFConfig(type: type, iterations: JSONUtil.int(obj, "kdfIterations") ?? 600_000, memory: JSONUtil.int(obj, "kdfMemory"), parallelism: JSONUtil.int(obj, "kdfParallelism"))
        }
        return TokenResponse(accessToken: access, refreshToken: JSONUtil.string(obj, "refresh_token"),
                             expiresIn: JSONUtil.int(obj, "expires_in") ?? 3600, key: key,
                             privateKey: JSONUtil.string(obj, "privateKey"), kdf: kdf, kdfSalt: salt, raw: obj)
    }

    /// Maps the identity server's 400/401 bodies to the cases the UI handles.
    static func classifyTokenError(data: Data, status: Int) -> VaultError {
        guard let obj = try? JSONUtil.parseObject(data) else { return .server("HTTP \(status)") }
        let description = (JSONUtil.string(obj, "error_description") ?? "").lowercased()
        let message = (message(from: data) ?? "").lowercased()
        let combined = description + " " + message

        if obj["hCaptcha_SiteKey"] != nil || obj["captchaSiteKey"] != nil || combined.contains("captcha") { return .captchaRequired }
        if let raw = obj["twoFactorProviders"] as? [Any] {
            let providers = raw.compactMap { v -> TwoFactorProvider? in
                if let i = v as? Int { return TwoFactorProvider(rawValue: i) }
                if let s = v as? String, let i = Int(s) { return TwoFactorProvider(rawValue: i) }
                return nil
            }
            var hint: String?
            if let details = obj["twoFactorProviders2"] as? [String: Any], let email = details["1"] as? [String: Any] {
                hint = (email["email"] ?? email["Email"]) as? String
            }
            return .twoFactor(TwoFactorChallenge(providers: providers, emailHint: hint))
        }
        if combined.contains("new device verification") { return .newDeviceVerification }
        if ["two-step token is invalid", "invalid two factor", "two factor token", "invalid totp", "invalid code", "code is invalid",
            "invalid verification code", "invalid otp", "invalid yubikey"].contains(where: combined.contains) { return .invalidTwoFactorCode }
        if combined.contains("invalid_username_or_password") || combined.contains("username or password is incorrect") { return .invalidPassword }
        if description == "invalid_grant" || combined.contains("invalid_grant") { return status == 400 ? .invalidPassword : .server(combined) }
        return .server(Self.message(from: data) ?? "HTTP \(status)")
    }

    // MARK: API

    /// Asks the server to e-mail a login code (the e-mail two-step provider).
    public func sendEmailLoginCode(email: String, authHash: String) async throws {
        let body: [String: Any] = ["email": email, "masterPasswordHash": authHash, "deviceIdentifier": device.identifier]
        let req = try jsonRequest("POST", endpoints.api.appendingPathComponent("two-factor/send-email-login"), body: body)
        let (data, status) = try await perform(req)
        guard (200..<300).contains(status) else { throw VaultError.server(Self.message(from: data) ?? "HTTP \(status)") }
    }

    public func sync(accessToken: String) async throws -> Data {
        var comps = URLComponents(url: endpoints.api.appendingPathComponent("sync"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "excludeDomains", value: "true")]
        let req = try jsonRequest("GET", comps.url!, bearer: accessToken)
        let (data, status) = try await perform(req)
        if status == 401 { throw VaultError.notLoggedIn }
        guard (200..<300).contains(status) else { throw VaultError.server(Self.message(from: data) ?? "HTTP \(status)") }
        return data
    }

    /// Authenticated JSON call returning the response object (`{}` for an empty body).
    public func authorized(_ method: String, _ path: String, body: [String: Any]?, accessToken: String) async throws -> [String: Any] {
        let req = try jsonRequest(method, endpoints.api.appendingPathComponent(path), body: body, bearer: accessToken)
        let (data, status) = try await perform(req)
        if status == 401 { throw VaultError.notLoggedIn }
        guard (200..<300).contains(status) else { throw VaultError.server(Self.message(from: data) ?? "HTTP \(status)") }
        return data.isEmpty ? [:] : ((try? JSONUtil.parseObject(data)) ?? [:])
    }
}
