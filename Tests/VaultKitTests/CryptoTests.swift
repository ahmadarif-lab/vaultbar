import XCTest
@testable import VaultKit

private func hex(_ s: String) -> Data {
    var d = Data(); var it = s.filter { !$0.isWhitespace }.makeIterator()
    while let a = it.next(), let b = it.next() { d.append(UInt8(String([a, b]), radix: 16)!) }
    return d
}
private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

final class CryptoTests: XCTestCase {
    func testBlake2bVectors() {
        XCTAssertEqual(hexString(Blake2b.hash(Data("abc".utf8), length: 64)),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        XCTAssertEqual(hexString(Blake2b.hash(Data(), length: 64)),
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
    }

    /// RFC 9106 section 5.3: Argon2id test vector (with secret and associated data).
    func testArgon2idRFC9106Vector() throws {
        let tag = try Argon2.hash(password: Data(repeating: 1, count: 32), salt: Data(repeating: 2, count: 16),
                                  iterations: 3, memoryKiB: 32, parallelism: 4, length: 32, variant: .id,
                                  secret: Data(repeating: 3, count: 8), associatedData: Data(repeating: 4, count: 12))
        XCTAssertEqual(hexString(tag), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    func testArgon2dAndIRFCVectors() throws {
        func run(_ v: Argon2.Variant) throws -> String {
            hexString(try Argon2.hash(password: Data(repeating: 1, count: 32), salt: Data(repeating: 2, count: 16),
                                      iterations: 3, memoryKiB: 32, parallelism: 4, length: 32, variant: v,
                                      secret: Data(repeating: 3, count: 8), associatedData: Data(repeating: 4, count: 12)))
        }
        XCTAssertEqual(try run(.d), "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb")
        XCTAssertEqual(try run(.i), "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8")
    }

    func testPBKDF2Vector() {
        // RFC 7914 §11: PBKDF2-HMAC-SHA-256("passwd", "salt", 1, 64) starts with 55ac046e56e3089f
        let out = Crypto.pbkdf2SHA256(password: Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 16)
        XCTAssertEqual(hexString(out), "55ac046e56e3089fec1691c22544b605")
    }

    func testHKDFExpandVector() {
        // RFC 5869 test case 1 (PRK given), L=42
        let prk = hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        let okm = HKDFReference.expand(prk: prk, info: hex("f0f1f2f3f4f5f6f7f8f9"), length: 42)
        XCTAssertEqual(hexString(okm), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        // And our wrapper (info as string) agrees with a manual HMAC-based expand.
        let key = Crypto.randomBytes(32)
        XCTAssertEqual(Crypto.hkdfExpandSHA256(key: key, info: "enc"), HKDFReference.expand(prk: key, info: Data("enc".utf8), length: 32))
    }

    func testAESCBCAgainstOpenSSLKnownAnswer() throws {
        // NIST SP 800-38A F.2.5 (AES-256-CBC), first block; PKCS7 adds one block we ignore.
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a")
        let ct = try Crypto.aesCBC(encrypt: true, key: key, iv: iv, data: plain)
        XCTAssertEqual(hexString(ct.prefix(16)), "f58c4c04d6e5f1ba779eabfb5f7bfbd6")
        XCTAssertEqual(try Crypto.aesCBC(encrypt: false, key: key, iv: iv, data: ct), plain)
    }

    func testMasterKeyChainPBKDF2() throws {
        let kdf = KDFConfig(type: 0, iterations: 5_000)
        let mk = try MasterKey.derive(password: "p4ssw0rd", email: "  User@Example.com ", kdf: kdf)
        XCTAssertEqual(mk, try MasterKey.derive(password: "p4ssw0rd", email: "user@example.com", kdf: kdf), "e-mail is trimmed and lower-cased")
        XCTAssertEqual(mk.count, 32)
        XCTAssertNotEqual(MasterKey.authHash(masterKey: mk, password: "p4ssw0rd"), mk.base64EncodedString())
        let stretched = MasterKey.stretch(mk)
        XCTAssertNotEqual(stretched.enc, stretched.mac)
    }

    func testKDFBoundsRejectDangerousParameters() {
        XCTAssertThrowsError(try KDFConfig(type: 0, iterations: 1).validate())
        XCTAssertThrowsError(try KDFConfig(type: 1, iterations: 3, memory: 4096, parallelism: 4).validate()) // 4 GiB
        XCTAssertThrowsError(try KDFConfig(type: 9, iterations: 3).validate())
        XCTAssertNoThrow(try KDFConfig(type: 1, iterations: 3, memory: 64, parallelism: 4).validate())
    }

    func testEncStringRoundTripAndTamperDetection() throws {
        let key = VaultKey.random()
        let s = try EncString.encrypt("héllo wörld", with: key)
        XCTAssertTrue(s.hasPrefix("2."))
        XCTAssertEqual(try EncString.decryptString(s, with: key), "héllo wörld")
        XCTAssertNotEqual(try EncString.encrypt("héllo wörld", with: key), s, "fresh IV each time")
        // flip one ciphertext byte
        var parts = String(s.dropFirst(2)).split(separator: "|").map(String.init)
        var ct = Data(base64Encoded: parts[1])!; ct[0] ^= 1; parts[1] = ct.base64EncodedString()
        XCTAssertThrowsError(try EncString.decryptString("2." + parts.joined(separator: "|"), with: key)) { XCTAssertEqual($0 as? CryptoError, .macMismatch) }
        XCTAssertThrowsError(try EncString.decryptString(s, with: VaultKey.random()))
        XCTAssertNil(EncString("garbage")); XCTAssertNil(EncString("9.a|b|c"))
    }

    func testRSAOAEPRoundTripThroughPKCS8() throws {
        var error: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error)!
        let pub = SecKeyCopyPublicKey(priv)!
        let pkcs1 = SecKeyCopyExternalRepresentation(priv, &error)! as Data
        let pkcs8 = TestDER.wrapPKCS8(pkcs1)
        let secret = Crypto.randomBytes(64)
        for (alg, type) in [(SecKeyAlgorithm.rsaEncryptionOAEPSHA1, 4), (.rsaEncryptionOAEPSHA256, 3)] {
            let ct = SecKeyCreateEncryptedData(pub, alg, secret as CFData, &error)! as Data
            let enc = try XCTUnwrap(EncString("\(type).\(ct.base64EncodedString())"))
            XCTAssertEqual(try RSAKey.decrypt(enc, with: RSAKey.privateKey(pkcs8: pkcs8)), secret)
        }
    }
}

/// Reference HKDF-Expand written independently of CryptoKit (RFC 5869 §2.3).
enum HKDFReference {
    static func expand(prk: Data, info: Data, length: Int) -> Data {
        var t = Data(), okm = Data(), counter: UInt8 = 1
        while okm.count < length {
            t = Crypto.hmacSHA256(key: prk, data: t + info + Data([counter]))
            okm += t; counter += 1
        }
        return okm.prefix(length)
    }
}

enum TestDER {
    static func len(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []; var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func wrapPKCS8(_ pkcs1: Data) -> Data {
        let alg = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let body = Data([0x02, 0x01, 0x00]) + alg + Data([0x04]) + len(pkcs1.count) + pkcs1
        return Data([0x30]) + len(body.count) + body
    }
}
