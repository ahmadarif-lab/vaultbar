import CryptoKit
import Foundation

public enum TOTPAlgorithm: String, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

/// A parsed `login.totp` value. Computes RFC 6238 codes locally, so the app
/// never needs `bw get totp` (which is gated on a paid plan).
public struct TOTP: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case standard
        /// Steam Guard: SHA1, 30 s, five characters from Steam's own alphabet.
        case steam
    }

    public let secret: Data
    public let algorithm: TOTPAlgorithm
    public let digits: Int
    public let period: Int
    public let kind: Kind
    public let issuer: String?
    /// The account part of an `otpauth://` label ("Issuer:alice@x" -> "alice@x").
    public let account: String?

    public init(secret: Data, algorithm: TOTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30, kind: Kind = .standard, issuer: String? = nil, account: String? = nil) {
        self.secret = secret
        self.account = account
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.kind = kind
        self.issuer = issuer
    }

    private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

    // MARK: Parsing

    /// Accepts a bare base32 secret, an `otpauth://totp/...` URI or `steam://<secret>`.
    public init?(parsing raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()

        if lower.hasPrefix("steam://") {
            let secretPart = String(value.dropFirst("steam://".count))
            guard let secret = Base32.decode(secretPart) else { return nil }
            self.init(secret: secret, algorithm: .sha1, digits: 5, period: 30, kind: .steam, issuer: "Steam")
            return
        }

        if lower.hasPrefix("otpauth://") {
            guard let comps = URLComponents(string: value), comps.host?.lowercased() == "totp" else { return nil }
            let query = Dictionary(
                (comps.queryItems ?? []).compactMap { item in item.value.map { (item.name.lowercased(), $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            guard let secretValue = query["secret"], let secret = Base32.decode(secretValue) else { return nil }
            let algo = query["algorithm"].flatMap { TOTPAlgorithm(rawValue: $0.uppercased()) } ?? .sha1
            if query["algorithm"] != nil, TOTPAlgorithm(rawValue: query["algorithm"]!.uppercased()) == nil { return nil }
            let digits = query["digits"].flatMap(Int.init) ?? 6
            let period = query["period"].flatMap(Int.init) ?? 30
            guard (6...8).contains(digits), period > 0 else { return nil }
            var issuer = query["issuer"]
            // Label form: /Issuer:account (or just /account)
            let label = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var account: String? = label.isEmpty ? nil : label
            if let colon = label.firstIndex(of: ":") {
                if issuer == nil { issuer = String(label[..<colon]) }
                let rest = label[label.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                account = rest.isEmpty ? nil : rest
            }
            self.init(secret: secret, algorithm: algo, digits: digits, period: period, kind: .standard, issuer: issuer, account: account)
            return
        }

        guard let secret = Base32.decode(value) else { return nil }
        self.init(secret: secret)
    }

    // MARK: Codes

    /// The raw counter-based HOTP truncation (RFC 4226 §5.3).
    private func truncated(counter: UInt64) -> UInt32 {
        var be = counter.bigEndian
        let message = Data(bytes: &be, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        return (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
    }

    private func counter(at date: Date) -> UInt64 {
        UInt64(max(0, floor(date.timeIntervalSince1970 / Double(period))))
    }

    /// The code valid at `date`, without grouping.
    public func code(at date: Date = Date()) -> String {
        code(forCounter: counter(at: date))
    }

    func code(forCounter counter: UInt64) -> String {
        var value = truncated(counter: counter)
        switch kind {
        case .steam:
            var out = ""
            for _ in 0..<digits {
                out.append(Self.steamAlphabet[Int(value % UInt32(Self.steamAlphabet.count))])
                value /= UInt32(Self.steamAlphabet.count)
            }
            return out
        case .standard:
            var modulus: UInt32 = 1
            for _ in 0..<digits { modulus *= 10 }
            let number = value % modulus
            let text = String(number)
            return String(repeating: "0", count: max(0, digits - text.count)) + text
        }
    }

    /// The code after the current one, shown during the last seconds of a period.
    public func nextCode(at date: Date = Date()) -> String {
        code(forCounter: counter(at: date) + 1)
    }

    /// Seconds left until the current code rolls over (fractional).
    public func remaining(at date: Date = Date()) -> Double {
        let p = Double(period)
        return p - date.timeIntervalSince1970.truncatingRemainder(dividingBy: p)
    }

    /// 0...1, how much of the period is left (drives the countdown ring).
    public func fractionRemaining(at date: Date = Date()) -> Double {
        remaining(at: date) / Double(period)
    }

    /// `123 456` for 6 digits, `1234 5678` for 8, plain for Steam.
    public static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }

    public func displayCode(at date: Date = Date()) -> String {
        Self.grouped(code(at: date))
    }
}
