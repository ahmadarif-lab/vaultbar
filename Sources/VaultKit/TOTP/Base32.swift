import Foundation

/// RFC 4648 base32 decoding, tolerant of the formats people paste in:
/// lower case, spaces, dashes and missing or present `=` padding.
public enum Base32 {
    private static let alphabet: [UInt8: UInt8] = {
        var map: [UInt8: UInt8] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8.enumerated() {
            map[c] = UInt8(i)
        }
        return map
    }()

    public static func decode(_ string: String) -> Data? {
        var bits: UInt32 = 0
        var bitCount = 0
        var out = Data()
        var sawChar = false
        for scalar in string.unicodeScalars {
            guard scalar.isASCII else { return nil }
            var byte = UInt8(scalar.value)
            if byte == 0x20 || byte == 0x2D || byte == 0x3D || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue // space, dash, '=', tab, newlines
            }
            if byte >= 0x61 && byte <= 0x7A { byte -= 0x20 } // a-z -> A-Z
            guard let value = alphabet[byte] else { return nil }
            sawChar = true
            bits = (bits << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                out.append(UInt8((bits >> UInt32(bitCount)) & 0xFF))
            }
        }
        return sawChar && !out.isEmpty ? out : nil
    }
}
