import Foundation
import Security
@testable import VaultKit

/// Registers throwaway accounts on a real Vaultwarden (set VW_URL, e.g. http://127.0.0.1:18222),
/// using this project's own crypto to build the account keys, like a client would.
struct VaultwardenFixture {
    let base: URL

    static var current: VaultwardenFixture? {
        ProcessInfo.processInfo.environment["VW_URL"].flatMap(URL.init(string:)).map { VaultwardenFixture(base: $0) }
    }

    var server: ServerChoice { .selfHosted(base.absoluteString) }

    private func post(_ path: String, _ body: [String: Any], bearer: String? = nil, method: String = "POST") async throws -> (Data, Int) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func spki(fromPKCS1 pkcs1: Data) -> Data {
        let alg = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bits = Data([0x03]) + TestDER.len(pkcs1.count + 1) + Data([0x00]) + pkcs1
        let body = alg + bits
        return Data([0x30]) + TestDER.len(body.count) + body
    }

    @discardableResult
    func register(email: String, password: String, kdf: KDFConfig = KDFConfig(type: 0, iterations: 600_000)) async throws -> Data {
        let (tokenData, s1) = try await post("identity/accounts/register/send-verification-email",
                                             ["email": email, "name": "Test", "receiveMarketingEmails": false])
        guard s1 == 200 else { throw NSError(domain: "fixture", code: s1, userInfo: [NSLocalizedDescriptionKey: String(decoding: tokenData, as: UTF8.self)]) }
        let token = String(decoding: tokenData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))

        let master = try MasterKey.derive(password: password, email: email, kdf: kdf)
        let stretched = MasterKey.stretch(master)
        let userKey = VaultKey.random()
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &err)!
        let pkcs1 = SecKeyCopyExternalRepresentation(priv, &err)! as Data
        let pub = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(priv)!, &err)! as Data

        var body: [String: Any] = [
            "email": email, "emailVerificationToken": token,
            "masterPasswordHash": MasterKey.authHash(masterKey: master, password: password),
            "masterPasswordHint": NSNull(),
            "userSymmetricKey": try EncString.encrypt(userKey.bytes, with: stretched),
            "userAsymmetricKeys": ["publicKey": Self.spki(fromPKCS1: pub).base64EncodedString(),
                                   "encryptedPrivateKey": try EncString.encrypt(TestDER.wrapPKCS8(pkcs1), with: userKey)],
            "kdf": kdf.type, "kdfIterations": kdf.iterations,
        ]
        if let m = kdf.memory { body["kdfMemory"] = m }
        if let p = kdf.parallelism { body["kdfParallelism"] = p }
        let (data, s2) = try await post("identity/accounts/register/finish", body)
        guard (200..<300).contains(s2) else { throw NSError(domain: "fixture", code: s2, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
        return userKey.bytes
    }

    /// Enables the authenticator-app second factor; returns the base32 secret.
    func enableAuthenticator(accessToken: String, authHash: String) async throws -> String {
        let (data, s) = try await post("api/two-factor/get-authenticator", ["masterPasswordHash": authHash], bearer: accessToken)
        guard s == 200, let obj = try? JSONUtil.parseObject(data),
              let key = (obj["authenticator"] as? [String: Any])?["key"] as? String ?? obj["key"] as? String else {
            throw NSError(domain: "fixture", code: s, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        let code = TOTP(parsing: key)!.code()
        var body: [String: Any] = ["masterPasswordHash": authHash, "key": key, "token": code]
        if let uvt = obj["userVerificationToken"] { body["userVerificationToken"] = uvt }
        let (d2, s2) = try await post("api/two-factor/authenticator", body, bearer: accessToken, method: "PUT")
        guard (200..<300).contains(s2) else { throw NSError(domain: "fixture", code: s2, userInfo: [NSLocalizedDescriptionKey: String(decoding: d2, as: UTF8.self)]) }
        return key
    }

    func apiKey(accessToken: String, authHash: String) async throws -> String {
        let (data, s) = try await post("api/accounts/api-key", ["masterPasswordHash": authHash], bearer: accessToken)
        guard s == 200, let obj = try? JSONUtil.parseObject(data), let key = obj["apiKey"] as? String else {
            throw NSError(domain: "fixture", code: s, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return key
    }
}
