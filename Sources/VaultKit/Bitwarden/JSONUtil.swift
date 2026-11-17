import Foundation

/// Bitwarden servers differ in key casing (`ciphers` vs `Ciphers`); everything is
/// normalised to lower camelCase on the way in, and the server accepts that on the way out.
public enum JSONUtil {
    public static func normalize(_ any: Any) -> Any {
        if let dict = any as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                var key = k
                if let first = key.first, first.isUppercase { key = first.lowercased() + key.dropFirst() }
                out[key] = normalize(v)
            }
            return out
        }
        if let array = any as? [Any] { return array.map(normalize) }
        return any
    }

    public static func parseObject(_ data: Data) throws -> [String: Any] {
        guard let raw = try? JSONSerialization.jsonObject(with: data), let obj = normalize(raw) as? [String: Any] else { throw VaultError.badResponse }
        return obj
    }

    public static func string(_ d: [String: Any], _ key: String) -> String? {
        if let s = d[key] as? String, !s.isEmpty { return s }
        return nil
    }

    public static func int(_ d: [String: Any], _ key: String) -> Int? {
        if let i = d[key] as? Int { return i }
        if let s = d[key] as? String { return Int(s) }
        return nil
    }
}
