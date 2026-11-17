import Foundation

/// Small, dependency-free fuzzy matcher. Every whitespace-separated query
/// token has to match somewhere; a token matches a field as an exact
/// substring (best, more so at the start of the field or of a word) or, failing
/// that, as an in-order subsequence ("gthb" finds "GitHub").
public enum Fuzzy {
    /// Score of one already-folded token against one already-folded field.
    static func score(token: String, in field: String) -> Int? {
        guard !token.isEmpty, !field.isEmpty else { return nil }
        if let range = field.range(of: token) {
            let index = field.distance(from: field.startIndex, to: range.lowerBound)
            var score = 1000 - min(index, 200)
            if index == 0 {
                score += 300
            } else {
                let before = field[field.index(before: range.lowerBound)]
                if !before.isLetter && !before.isNumber { score += 150 }
            }
            if token.count == field.count { score += 200 }
            return score
        }
        // Subsequence: greedy left-to-right, penalise gaps.
        var gaps = 0
        var searchFrom = field.startIndex
        var last: String.Index?
        for ch in token {
            guard let found = field[searchFrom...].firstIndex(of: ch) else { return nil }
            if let last, field.index(after: last) != found { gaps += 1 }
            last = found
            searchFrom = field.index(after: found)
        }
        return max(1, 300 - gaps * 25 - field.count)
    }

    /// `fields` are (folded text, weight). `query` is folded here.
    public static func score(query: String, fields: [(String, Int)]) -> Int? {
        let tokens = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return 0 }
        var total = 0
        for token in tokens {
            var best: Int?
            for (text, weight) in fields {
                if let s = score(token: token, in: text) {
                    best = max(best ?? 0, s * weight)
                }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }
}
