import XCTest
@testable import VaultKit

final class TOTPTests: XCTestCase {
    // RFC 6238 Appendix B: 8-digit codes, secrets are the ASCII strings below
    // repeated to the HMAC's block-ish length.
    private let sha1Key = Data("12345678901234567890".utf8)
    private let sha256Key = Data("12345678901234567890123456789012".utf8)
    private let sha512Key = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private let vectors: [(time: TimeInterval, sha1: String, sha256: String, sha512: String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1111111109, "07081804", "68084774", "25091201"),
        (1111111111, "14050471", "67062674", "99943326"),
        (1234567890, "89005924", "91819424", "93441116"),
        (2000000000, "69279037", "90698825", "38618901"),
        (20000000000, "65353130", "77737706", "47863826"),
    ]

    func testRFC6238Vectors() {
        let a = TOTP(secret: sha1Key, algorithm: .sha1, digits: 8)
        let b = TOTP(secret: sha256Key, algorithm: .sha256, digits: 8)
        let c = TOTP(secret: sha512Key, algorithm: .sha512, digits: 8)
        for v in vectors {
            let date = Date(timeIntervalSince1970: v.time)
            XCTAssertEqual(a.code(at: date), v.sha1, "SHA1 @ \(v.time)")
            XCTAssertEqual(b.code(at: date), v.sha256, "SHA256 @ \(v.time)")
            XCTAssertEqual(c.code(at: date), v.sha512, "SHA512 @ \(v.time)")
        }
    }

    func testSixDigitIsTailOfEightDigit() {
        // Same truncated value, different modulus.
        let t = TOTP(secret: sha1Key, digits: 6)
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 59)), "287082")
    }

    func testLeadingZerosKept() {
        let t = TOTP(secret: sha1Key, digits: 8)
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 1111111109)), "07081804")
    }

    func testBase32Variants() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" // "12345678901234567890"
        for form in [secret, secret.lowercased(), "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ====", "gezd-gnbv-gy3t-qojq-gezd-gnbv-gy3t-qojq"] {
            let t = TOTP(parsing: form)
            XCTAssertEqual(t?.secret, sha1Key, form)
        }
        XCTAssertNil(TOTP(parsing: "not base32!"))
        XCTAssertNil(TOTP(parsing: ""))
        XCTAssertNil(TOTP(parsing: "   "))
    }

    func testOtpauthURI() {
        let uri = "otpauth://totp/Example:alice@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example&algorithm=SHA256&digits=8&period=60"
        let t = TOTP(parsing: uri)
        XCTAssertEqual(t?.algorithm, .sha256)
        XCTAssertEqual(t?.digits, 8)
        XCTAssertEqual(t?.period, 60)
        XCTAssertEqual(t?.issuer, "Example")
        XCTAssertEqual(t?.secret, sha1Key)
    }

    func testOtpauthDefaultsAndLabelIssuer() {
        let t = TOTP(parsing: "otpauth://totp/Acme%20Co:bob?secret=GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(t?.algorithm, .sha1)
        XCTAssertEqual(t?.digits, 6)
        XCTAssertEqual(t?.period, 30)
        XCTAssertEqual(t?.issuer, "Acme Co")
    }

    func testOtpauthRejectsBadInput() {
        XCTAssertNil(TOTP(parsing: "otpauth://hotp/x?secret=GEZDGNBVGY3TQOJQ"))
        XCTAssertNil(TOTP(parsing: "otpauth://totp/x"))
        XCTAssertNil(TOTP(parsing: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ&digits=12"))
        XCTAssertNil(TOTP(parsing: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ&algorithm=MD5"))
    }

    func testSteam() {
        let t = TOTP(parsing: "steam://GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(t?.kind, .steam)
        let code = t!.code(at: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(code.count, 5)
        let allowed = Set("23456789BCDFGHJKMNPQRTVWXY")
        XCTAssertTrue(code.allSatisfy { allowed.contains($0) })
        // RFC 4226 test vector, counter 1: truncated value 0x41397eea = 1094287082
        // (its 6-digit code is 287082). Steam re-encodes the same value in base 26.
        XCTAssertEqual(code, steamExpected(1094287082))
    }

    private func steamExpected(_ v: UInt32) -> String {
        let alphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
        var n = v
        var s = ""
        for _ in 0..<5 { s.append(alphabet[Int(n % 26)]); n /= 26 }
        return s
    }

    func testCountdownMath() {
        let t = TOTP(secret: sha1Key)
        XCTAssertEqual(t.remaining(at: Date(timeIntervalSince1970: 60)), 30, accuracy: 0.001)
        XCTAssertEqual(t.remaining(at: Date(timeIntervalSince1970: 89)), 1, accuracy: 0.001)
        XCTAssertEqual(t.fractionRemaining(at: Date(timeIntervalSince1970: 75)), 0.5, accuracy: 0.001)
    }

    func testNextCodeIsNextPeriod() {
        let t = TOTP(secret: sha1Key)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(t.nextCode(at: now), t.code(at: Date(timeIntervalSince1970: 1030)))
    }

    func testGrouping() {
        XCTAssertEqual(TOTP.grouped("123456"), "123 456")
        XCTAssertEqual(TOTP.grouped("12345678"), "1234 5678")
        XCTAssertEqual(TOTP.grouped("ABCDE"), "ABCDE")
    }
}
