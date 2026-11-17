import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum CryptoError: Error, Equatable {
    case invalidFormat
    case macMismatch
    case unsupported(String)
    case failed(String)
}

/// Thin wrappers over CommonCrypto / CryptoKit for the primitives the Bitwarden
/// protocol uses. Nothing here is custom cryptography.
public enum Crypto {
    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "system RNG failed")
        return data
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { sl in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.bindMemory(to: Int8.self).baseAddress, password.count,
                        sl.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        outPtr.bindMemory(to: UInt8.self).baseAddress, length)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return out
    }

    /// HKDF-Expand only (no extract step): Bitwarden stretches the master key this way.
    public static func hkdfExpandSHA256(key: Data, info: String, length: Int = 32) -> Data {
        let expanded = HKDF<SHA256>.expand(pseudoRandomKey: SymmetricKey(data: key), info: Data(info.utf8), outputByteCount: length)
        return expanded.withUnsafeBytes { Data($0) }
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// AES-256-CBC with PKCS#7 padding.
    public static func aesCBC(encrypt: Bool, key: Data, iv: Data, data: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw CryptoError.invalidFormat }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), keyPtr.baseAddress, 32, ivPtr.baseAddress,
                                inPtr.baseAddress, data.count, outPtr.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.failed("AES status \(status)") }
        return out.prefix(moved)
    }
}

/// The 64-byte symmetric key Bitwarden uses everywhere: 32 bytes AES + 32 bytes HMAC.
public struct VaultKey: Sendable, Equatable {
    public let enc: Data
    public let mac: Data

    public init(enc: Data, mac: Data) { self.enc = enc; self.mac = mac }

    public init(bytes: Data) throws {
        guard bytes.count == 64 else { throw CryptoError.unsupported("user key of \(bytes.count) bytes") }
        enc = bytes.prefix(32)
        mac = bytes.suffix(32)
    }

    public static func random() -> VaultKey { VaultKey(enc: Crypto.randomBytes(32), mac: Crypto.randomBytes(32)) }

    public var bytes: Data { enc + mac }
}

public struct KDFConfig: Codable, Equatable, Sendable {
    /// 0 = PBKDF2-SHA256, 1 = Argon2id.
    public var type: Int
    public var iterations: Int
    /// Argon2id only: memory in MiB and lanes.
    public var memory: Int?
    public var parallelism: Int?

    public init(type: Int = 0, iterations: Int = 600_000, memory: Int? = nil, parallelism: Int? = nil) {
        self.type = type; self.iterations = iterations; self.memory = memory; self.parallelism = parallelism
    }

    /// Reject parameters that are absurdly weak or large before spending time (or memory) on them.
    public func validate() throws {
        switch type {
        case 0:
            guard (5_000...2_000_000).contains(iterations) else { throw CryptoError.unsupported("PBKDF2 iterations \(iterations)") }
        case 1:
            guard (2...10).contains(iterations), (16...1024).contains(memory ?? 0), (1...16).contains(parallelism ?? 0)
            else { throw CryptoError.unsupported("Argon2id parameters") }
        default:
            throw CryptoError.unsupported("KDF type \(type)")
        }
    }
}

/// Master key derivation and the hashes the server sees.
public enum MasterKey {
    /// The 32-byte master key. The e-mail is the salt (trimmed, lower-cased).
    public static func derive(password: String, email: String, kdf: KDFConfig) throws -> Data {
        try kdf.validate()
        let salt = Data(email.trimmingCharacters(in: .whitespaces).lowercased().utf8)
        let pw = Data(password.utf8)
        switch kdf.type {
        case 0:
            return Crypto.pbkdf2SHA256(password: pw, salt: salt, iterations: kdf.iterations)
        default:
            return try Argon2.hash(password: pw, salt: Crypto.sha256(salt), iterations: kdf.iterations,
                                   memoryKiB: (kdf.memory ?? 64) * 1024, parallelism: kdf.parallelism ?? 4, length: 32, variant: .id)
        }
    }

    /// What the server authenticates with: one more PBKDF2 round over the master key, salted with the password.
    public static func authHash(masterKey: Data, password: String) -> String {
        Crypto.pbkdf2SHA256(password: masterKey, salt: Data(password.utf8), iterations: 1).base64EncodedString()
    }

    /// The master key stretched into an AES + HMAC pair (HKDF-Expand with "enc" and "mac").
    public static func stretch(_ masterKey: Data) -> VaultKey {
        VaultKey(enc: Crypto.hkdfExpandSHA256(key: masterKey, info: "enc"), mac: Crypto.hkdfExpandSHA256(key: masterKey, info: "mac"))
    }
}

/// A Bitwarden "EncString": `<type>.<iv>|<data>|<mac>` (symmetric) or `<type>.<data>` (RSA).
public struct EncString: Sendable, Equatable {
    public let type: Int
    public let iv: Data?
    public let data: Data
    public let mac: Data?

    public init?(_ string: String) {
        guard let dot = string.firstIndex(of: "."), let type = Int(string[..<dot]) else { return nil }
        let parts = string[string.index(after: dot)...].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func b64(_ s: String) -> Data? { Data(base64Encoded: s) }
        switch type {
        case 0, 2:
            guard parts.count >= (type == 2 ? 3 : 2), let iv = b64(parts[0]), let ct = b64(parts[1]) else { return nil }
            if type == 2 { guard let mac = b64(parts[2]) else { return nil }; self.mac = mac } else { self.mac = nil }
            self.iv = iv; self.data = ct
        case 3, 4:
            guard let d = b64(parts[0]) else { return nil }
            iv = nil; data = d; mac = nil
        default:
            return nil
        }
        self.type = type
    }

    public func decrypt(with key: VaultKey) throws -> Data {
        guard let iv else { throw CryptoError.unsupported("EncString type \(type) is not symmetric") }
        switch type {
        case 2:
            guard let mac else { throw CryptoError.invalidFormat }
            let expected = Crypto.hmacSHA256(key: key.mac, data: iv + data)
            guard Crypto.constantTimeEquals(expected, mac) else { throw CryptoError.macMismatch }
            return try Crypto.aesCBC(encrypt: false, key: key.enc, iv: iv, data: data)
        case 0:
            return try Crypto.aesCBC(encrypt: false, key: key.enc, iv: iv, data: data)
        default:
            throw CryptoError.unsupported("EncString type \(type)")
        }
    }

    /// Type 2 (AES-256-CBC + HMAC-SHA256) with a fresh random IV.
    public static func encrypt(_ plain: Data, with key: VaultKey) throws -> String {
        let iv = Crypto.randomBytes(16)
        let ct = try Crypto.aesCBC(encrypt: true, key: key.enc, iv: iv, data: plain)
        let mac = Crypto.hmacSHA256(key: key.mac, data: iv + ct)
        return "2.\(iv.base64EncodedString())|\(ct.base64EncodedString())|\(mac.base64EncodedString())"
    }

    public static func encrypt(_ string: String, with key: VaultKey) throws -> String {
        try encrypt(Data(string.utf8), with: key)
    }

    public static func decryptString(_ string: String, with key: VaultKey) throws -> String {
        guard let enc = EncString(string) else { throw CryptoError.invalidFormat }
        guard let s = String(data: try enc.decrypt(with: key), encoding: .utf8) else { throw CryptoError.invalidFormat }
        return s
    }
}

/// RSA-OAEP, used for the private key that unwraps organization keys.
public enum RSAKey {
    /// `der` is a PKCS#8 `PrivateKeyInfo` (what Bitwarden stores); Security.framework wants the inner PKCS#1.
    public static func privateKey(pkcs8 der: Data) throws -> SecKey {
        let pkcs1 = try unwrapPKCS8(der)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw CryptoError.failed("RSA key import: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }

    public static func decrypt(_ enc: EncString, with key: SecKey) throws -> Data {
        let algorithm: SecKeyAlgorithm = enc.type == 3 ? .rsaEncryptionOAEPSHA256 : .rsaEncryptionOAEPSHA1
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(key, algorithm, enc.data as CFData, &error) else {
            throw CryptoError.failed("RSA decrypt: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return out as Data
    }

    // Minimal DER walk: PrivateKeyInfo ::= SEQUENCE { INTEGER, SEQUENCE, OCTET STRING }
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var i = der.startIndex
        func readLength() throws -> Int {
            guard i < der.endIndex else { throw CryptoError.invalidFormat }
            let first = Int(der[i]); i += 1
            if first < 0x80 { return first }
            let n = first & 0x7F
            guard n > 0, n <= 4, i + n <= der.endIndex else { throw CryptoError.invalidFormat }
            var value = 0
            for _ in 0..<n { value = (value << 8) | Int(der[i]); i += 1 }
            return value
        }
        func expect(_ tag: UInt8) throws -> Int {
            guard i < der.endIndex, der[i] == tag else { throw CryptoError.invalidFormat }
            i += 1
            return try readLength()
        }
        _ = try expect(0x30)
        let versionLen = try expect(0x02); i += versionLen
        let algLen = try expect(0x30); i += algLen
        let octetLen = try expect(0x04)
        guard i + octetLen <= der.endIndex else { throw CryptoError.invalidFormat }
        return der.subdata(in: i..<(i + octetLen))
    }
}
