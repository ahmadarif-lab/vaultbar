import XCTest
@testable import VaultKit

/// Deterministic RNG so the tests are repeatable (production uses the system CSPRNG).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class GeneratorTests: XCTestCase {
    func testWordlistIsTheFullEFFList() {
        XCTAssertEqual(EFFWordlist.words.count, 7776)
        XCTAssertEqual(Set(EFFWordlist.words).count, 7776)
        XCTAssertEqual(EFFWordlist.words.first, "abacus")
        XCTAssertEqual(EFFWordlist.words.last, "zoom")
    }

    func testLengthAndAlphabet() {
        var rng = SeededRNG(state: 1)
        var o = PasswordOptions()
        o.length = 40
        o.special = false
        let p = PasswordGenerator.password(o, using: &rng)
        XCTAssertEqual(p.count, 40)
        XCTAssertTrue(p.allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testEveryEnabledSetAppearsAndMinimumsHold() {
        for seed in 0..<200 {
            var rng = SeededRNG(state: UInt64(seed))
            var o = PasswordOptions()
            o.length = 12; o.minNumbers = 3; o.minSpecial = 2
            let p = Array(PasswordGenerator.password(o, using: &rng))
            XCTAssertEqual(p.count, 12)
            XCTAssertTrue(p.contains { $0.isUppercase })
            XCTAssertTrue(p.contains { $0.isLowercase })
            XCTAssertGreaterThanOrEqual(p.filter { $0.isNumber }.count, 3)
            XCTAssertGreaterThanOrEqual(p.filter { "!@#$%^&*".contains($0) }.count, 2)
        }
    }

    func testAvoidAmbiguous() {
        var o = PasswordOptions()
        o.length = 128; o.avoidAmbiguous = true
        for seed in 0..<50 {
            var rng = SeededRNG(state: UInt64(seed))
            let p = PasswordGenerator.password(o, using: &rng)
            XCTAssertFalse(p.contains { "IOl01".contains($0) })
        }
    }

    func testNoSetSelectedFallsBackToLowercaseAndTinyLengthIsClamped() {
        var o = PasswordOptions()
        o.uppercase = false; o.lowercase = false; o.numbers = false; o.special = false; o.length = 3
        let p = PasswordGenerator.password(o)
        XCTAssertEqual(p.count, 5)
        XCTAssertTrue(p.allSatisfy { $0.isLowercase })
    }

    func testMinimumsShrinkWhenLengthIsTiny() {
        var o = PasswordOptions()
        o.length = 5; o.minNumbers = 9; o.minSpecial = 9
        XCTAssertEqual(PasswordGenerator.password(o).count, 5)
    }

    func testRandomnessIsNotConstant() {
        let o = PasswordOptions()
        XCTAssertEqual(Set((0..<50).map { _ in PasswordGenerator.password(o) }).count, 50)
    }

    func testPassphrase() {
        var rng = SeededRNG(state: 7)
        var o = PassphraseOptions()
        o.words = 5; o.separator = "."; o.capitalize = true; o.includeNumber = true
        let parts = PasswordGenerator.passphrase(o, using: &rng).split(separator: ".")
        XCTAssertEqual(parts.count, 5)
        XCTAssertTrue(parts.allSatisfy { $0.first!.isUppercase })
        XCTAssertEqual(parts.filter { $0.last!.isNumber }.count, 1)
        o.capitalize = false; o.includeNumber = false
        let plain = PasswordGenerator.passphrase(o, using: &rng).split(separator: ".").map(String.init)
        XCTAssertTrue(plain.allSatisfy { EFFWordlist.words.contains($0) })
    }

    func testEntropyAndStrength() {
        var o = PasswordOptions(); o.length = 16
        XCTAssertGreaterThan(PasswordGenerator.entropyBits(o), 90) // 16 * log2(70)
        o.length = 6; o.uppercase = false; o.special = false; o.numbers = false
        XCTAssertEqual(PasswordGenerator.strength(bits: PasswordGenerator.entropyBits(o)), .weak)
        XCTAssertEqual(PasswordGenerator.entropyBits(PassphraseOptions()), 4 * log2(7776), accuracy: 0.001)
        XCTAssertEqual(PasswordGenerator.strength(bits: 200), .strong)
    }
}
