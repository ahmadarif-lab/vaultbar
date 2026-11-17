import Foundation

public struct PasswordOptions: Codable, Equatable, Sendable {
    public var length = 16
    public var uppercase = true
    public var lowercase = true
    public var numbers = true
    public var special = true
    public var minNumbers = 1
    public var minSpecial = 1
    public var avoidAmbiguous = false
    public init() {}
}

public struct PassphraseOptions: Codable, Equatable, Sendable {
    public var words = 4
    public var separator = "-"
    public var capitalize = true
    public var includeNumber = false
    public init() {}
}

public enum PasswordStrength: Int, Sendable, Comparable {
    case weak, fair, good, strong
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Local generator. Uses the system CSPRNG (`SystemRandomNumberGenerator`),
/// unbiased index selection and a Fisher-Yates shuffle; nothing is stored.
public enum PasswordGenerator {
    public static let lengthRange = 5...128
    public static let wordsRange = 3...20

    // Same pools as the Bitwarden clients; "ambiguous" drops I, O, l, 0, 1.
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    static let symbols = Array("!@#$%^&*")
    static let ambiguous = Set("IOl01")

    static func pools(_ o: PasswordOptions) -> [(chars: [Character], minimum: Int)] {
        func clean(_ c: [Character]) -> [Character] { o.avoidAmbiguous ? c.filter { !ambiguous.contains($0) } : c }
        var out: [(chars: [Character], minimum: Int)] = []
        if o.uppercase { out.append((clean(upper), 1)) }
        if o.lowercase { out.append((clean(lower), 1)) }
        if o.numbers { out.append((clean(digits), max(1, o.minNumbers))) }
        if o.special { out.append((symbols, max(1, o.minSpecial))) }
        if out.isEmpty { out.append((clean(lower), 1)) } // never an empty alphabet
        return out
    }

    public static func password(_ o: PasswordOptions, using rng: inout some RandomNumberGenerator) -> String {
        let length = min(max(o.length, lengthRange.lowerBound), lengthRange.upperBound)
        var pools = pools(o)
        // Minimums must fit; shrink the last ones first if the length is tiny.
        while pools.reduce(0, { $0 + $1.minimum }) > length {
            if let i = pools.lastIndex(where: { $0.minimum > 1 }) { pools[i].minimum -= 1 } else { pools.removeLast() }
        }
        var chars: [Character] = []
        for pool in pools {
            for _ in 0..<pool.minimum { chars.append(pool.chars.randomElement(using: &rng)!) }
        }
        let all = pools.flatMap(\.chars)
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    public static func password(_ o: PasswordOptions) -> String {
        var rng = SystemRandomNumberGenerator()
        return password(o, using: &rng)
    }

    public static func passphrase(_ o: PassphraseOptions, using rng: inout some RandomNumberGenerator) -> String {
        let count = min(max(o.words, wordsRange.lowerBound), wordsRange.upperBound)
        var words = (0..<count).map { _ in EFFWordlist.words.randomElement(using: &rng)! }
        if o.capitalize { words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if o.includeNumber, !words.isEmpty {
            let i = Int.random(in: 0..<words.count, using: &rng)
            words[i] += String(Int.random(in: 0...9, using: &rng))
        }
        return words.joined(separator: o.separator)
    }

    public static func passphrase(_ o: PassphraseOptions) -> String {
        var rng = SystemRandomNumberGenerator()
        return passphrase(o, using: &rng)
    }

    // MARK: Strength (entropy estimate for a uniformly random result)

    public static func entropyBits(_ o: PasswordOptions) -> Double {
        let size = Set(pools(o).flatMap(\.chars)).count
        let length = min(max(o.length, lengthRange.lowerBound), lengthRange.upperBound)
        return Double(length) * log2(Double(size))
    }

    public static func entropyBits(_ o: PassphraseOptions) -> Double {
        let count = min(max(o.words, wordsRange.lowerBound), wordsRange.upperBound)
        var bits = Double(count) * log2(Double(EFFWordlist.words.count))
        if o.includeNumber { bits += log2(Double(count * 10)) }
        return bits
    }

    public static func strength(bits: Double) -> PasswordStrength {
        switch bits {
        case ..<50: return .weak
        case ..<75: return .fair
        case ..<100: return .good
        default: return .strong
        }
    }

    /// How to colour one character of a generated password.
    public enum CharClass: Sendable { case letter, digit, symbol }
    public static func charClass(_ c: Character) -> CharClass {
        if c.isNumber { return .digit }
        if c.isLetter { return .letter }
        return .symbol
    }
}
