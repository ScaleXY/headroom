import Foundation

/// Agent-written text, made safe to store and show: control characters go (line breaks and tabs
/// become spaces), and it's cut to a length that fits a row or an opened row.
public enum TaskText {
    /// Task, run and plan-item titles.
    public static let titleLimit = 120
    /// Notes, evidence, failure and skip reasons, questions.
    public static let noteLimit = 400

    /// Nil when nothing is left once cleaned.
    public static func clean(_ s: String?, limit: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        var out = String.UnicodeScalarView()
        var dirty = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0A, 0x0D, 0x09, 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
                out.append(" "); dirty = true
            // Bidirectional overrides and isolates can make text read differently from what it says.
            case 0x202A...0x202E, 0x2066...0x2069:
                dirty = true
            default:
                if u.properties.generalCategory == .control { dirty = true } else { out.append(u) }
            }
        }
        var t = dirty ? String(out) : s
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard t.count > limit else { return t }
        return String(t.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func title(_ s: String?) -> String? { clean(s, limit: titleLimit) }
    public static func note(_ s: String?) -> String? { clean(s, limit: noteLimit) }

    /// Answers offered with a question: each one a title, at most ten.
    public static func options(_ list: [String]?) -> [String] {
        (list ?? []).compactMap(title).prefix(10).map(\.self)
    }
}
