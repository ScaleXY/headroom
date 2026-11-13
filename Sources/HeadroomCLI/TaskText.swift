import Foundation
import HeadroomKit

/// Agent-written text (titles, notes, evidence, reasons) is cleaned on the way in and again on
/// the way out: newlines and tabs become spaces, other control characters and bidi overrides go,
/// and it is capped, so one line stays one line and nothing reaches a terminal as an escape code.
enum TaskText {
    static let titleLimit = 120
    static let noteLimit = 400

    /// Nil when nothing is left.
    static func clean(_ s: String?, limit: Int) -> String? {
        guard let s else { return nil }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\n" || u == "\r" || u == "\t" { out.append(" "); continue }
            if u.properties.generalCategory == .control { continue }
            if (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value) { continue }
            out.append(u)
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : trimmed
    }

    static func title(_ s: String?) -> String? { clean(s, limit: titleLimit) }
    static func note(_ s: String?) -> String? { clean(s, limit: noteLimit) }

    /// Safe to print, whatever is stored (journals written before cleaning, or by hand).
    static func display(_ s: String, limit: Int = noteLimit) -> String { clean(s, limit: limit) ?? "" }
}

/// Edit distance, for "did you mean".
enum Fuzzy {
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        // Optimal string alignment: a swapped pair of letters counts as one edit.
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }

    /// Up to `limit` of `candidates` close to `word`, closest first: by the whole id, or by its
    /// last part (so `schema` finds `api/schema`).
    static func closest(_ word: String, in candidates: [String], limit: Int = 3) -> [String] {
        let scored = candidates.map { c -> (String, Int) in
            let whole = distance(word, c)
            let tail = distance(TaskPath.last(word), TaskPath.last(c))
            return (c, min(whole, tail + (TaskPath.last(word) == word ? 0 : 1)))
        }
        let near = scored.filter { $0.1 <= max(2, word.count / 3) }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        return near.prefix(limit).map(\.0)
    }
}
