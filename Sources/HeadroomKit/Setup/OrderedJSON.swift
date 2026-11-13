import Foundation

/// A JSON value that keeps object keys in file order and numbers as written, so a settings file
/// Headroom edits changes only where Headroom edits it. Written the way Claude Code and Codex
/// write their own files: two-space indentation, `"key": value`.
public enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The number's text as it appeared.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON
        public init(_ key: String, _ value: OrderedJSON) { self.key = key; self.value = value }
    }

    public struct ParseError: Error, Sendable {
        public var message: String
        public var offset: Int
    }

    public var members: [Member]? { if case .object(let m) = self { m } else { nil } }
    public var elements: [OrderedJSON]? { if case .array(let a) = self { a } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }

    /// An object's value for `key` (the first, if repeated). Setting nil removes every `key`;
    /// setting a value replaces the first in place or appends at the end.
    public subscript(key: String) -> OrderedJSON? {
        get { members?.first { $0.key == key }?.value }
        set {
            guard var m = members else { return }
            if let newValue {
                if let i = m.firstIndex(where: { $0.key == key }) { m[i].value = newValue } else { m.append(Member(key, newValue)) }
            } else {
                m.removeAll { $0.key == key }
            }
            self = .object(m)
        }
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws(ParseError) -> OrderedJSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw ParseError(message: "unexpected text after the JSON value", offset: p.i) }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        func fail(_ message: String) -> ParseError { ParseError(message: message, offset: i) }

        mutating func value(depth: Int) throws(ParseError) -> OrderedJSON {
            guard depth < 512 else { throw fail("nested too deeply") }
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var members: [Member] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                    let key = try string()
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                    i += 1
                    skipSpace()
                    members.append(Member(key, try value(depth: depth + 1)))
                    skipSpace()
                    guard i < bytes.count else { throw fail("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    throw fail("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw fail("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw fail("expected ',' or ']'")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default:
                return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws(ParseError) {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("unexpected character") }
            i += w.count
        }

        mutating func number() throws(ParseError) -> String {
            let start = i
            func digits() -> Int { let s = i; while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }; return i - s }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw fail("unexpected character") }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") { i += 1; guard digits() > 0 else { throw fail("bad number") } }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw fail("bad number") }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func hex4() throws(ParseError) -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw fail("bad \\u escape") }
            i += 4
            return v
        }

        /// At the opening quote.
        mutating func string() throws(ParseError) -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw fail("control character in a string") }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw fail("unterminated string") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var v = try hex4()
                    if (0xD800..<0xDC00).contains(v), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) { v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00) } else { i = save }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(v).map(Character.init) ?? "\u{FFFD}").utf8))
                default: throw fail("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: Writing

    /// Two-space indentation, as `JSON.stringify(value, null, 2)` writes it.
    public func serialized() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    func write(into out: inout String, indent: Int) {
        let pad = String(repeating: " ", count: indent + 2)
        switch self {
        case .object(let m):
            guard !m.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (n, member) in m.enumerated() {
                out += pad + Self.quote(member.key) + ": "
                member.value.write(into: &out, indent: indent + 2)
                out += n == m.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        case .array(let a):
            guard !a.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (n, v) in a.enumerated() {
                out += pad
                v.write(into: &out, indent: indent + 2)
                out += n == a.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .string(let s): out += Self.quote(s)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
