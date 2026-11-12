import Foundation

/// Task ids are slash-separated paths (`api/tests`): the parent is the path minus its last
/// component. Components are `[A-Za-z0-9._-]`; a leading `~` marks a task Headroom made up for an
/// agent nobody declared, so agents never collide with it.
public enum TaskPath {
    public static let maxLength = 200

    public static func components(_ path: String) -> [String] { path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }

    public static func parent(_ path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    public static func last(_ path: String) -> String { components(path).last ?? path }

    public static func depth(_ path: String) -> Int { components(path).count - 1 }

    /// `api/tests/unit` → `["api", "api/tests"]`, outermost first.
    public static func ancestors(_ path: String) -> [String] {
        let parts = components(path)
        return (1..<max(1, parts.count)).map { parts[..<$0].joined(separator: "/") }
    }

    public static func isValid(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= maxLength else { return false }
        return components(path).allSatisfy { part in
            let body = part.hasPrefix("~") ? part.dropFirst() : Substring(part)
            return !body.isEmpty && body.unicodeScalars.allSatisfy(TaskRunID.allowed.contains)
        }
    }

    /// `~` plus the attempt key made path-safe: the id of the implicit task for an untagged agent.
    public static func implicit(forAttempt key: String) -> String { "~" + TaskRunID.clean(key, limit: maxLength - 1) }

    public static func isImplicit(_ path: String) -> Bool { last(path).hasPrefix("~") }
}

/// Run ids: whatever the harness calls the session, cut down to `[A-Za-z0-9._-]` and 64 characters
/// so they are safe as file names and inside tags.
public enum TaskRunID {
    public static let maxLength = 64
    static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Nil when nothing usable is left (empty, or only dots, which would name `.` or `..`).
    public static func sanitize(_ raw: String) -> String? {
        let s = clean(raw, limit: maxLength)
        return s.isEmpty || s.allSatisfy({ $0 == "." }) ? nil : s
    }

    static func clean(_ raw: String, limit: Int) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }).prefix(limit))
    }
}

/// A full reference `RUN:PATH`. Run ids never contain `:`, so the first colon splits it.
public struct TaskRef: Hashable, Sendable, CustomStringConvertible {
    public var run: String
    public var path: String

    public init(run: String, path: String) { self.run = run; self.path = path }

    /// `RUN:PATH`; nil when either half is invalid or there is no colon.
    public init?(_ s: String) {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let run = String(s[..<colon]), path = String(s[s.index(after: colon)...])
        guard TaskRunID.sanitize(run) == run, TaskPath.isValid(path) else { return nil }
        self.init(run: run, path: path)
    }

    public var description: String { "\(run):\(path)" }

    /// What an orchestrator puts in a subagent's description or prompt so the observer can bind
    /// that agent to this task.
    public var tag: String { "[hr:\(run):\(path)]" }

    /// The first well-formed `[hr:RUN:PATH]` in `text`, skipping malformed ones.
    public static func firstTag(in text: String) -> TaskRef? {
        var rest = text[...]
        while let open = rest.range(of: "[hr:") {
            let after = rest[open.upperBound...]
            if let close = after.firstIndex(of: "]"), let ref = TaskRef(String(after[..<close])) { return ref }
            rest = after
        }
        return nil
    }
}
