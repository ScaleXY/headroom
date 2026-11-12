import Foundation
import HeadroomKit

extension JSONScan {
    /// Calls `body` with each element of the array starting at `i`. False on malformed input.
    @discardableResult
    func forEachElement(_ i: Int, _ body: (ByteSpan) -> Bool) -> Bool {
        var i = skipSpace(i)
        guard i < count, p[i] == 0x5B else { return false }
        i = skipSpace(i + 1)
        if i < count, p[i] == 0x5D { return true }
        while i < count {
            guard let end = skipValue(i) else { return false }
            if !body(ByteSpan(start: i, end: end)) { return true }
            let j = skipSpace(end)
            guard j < count else { return false }
            if p[j] == 0x5D { return true }
            guard p[j] == 0x2C else { return false }
            i = skipSpace(j + 1)
        }
        return false
    }

    func contains(_ span: ByteSpan, _ needle: StaticString) -> Bool {
        span.count > 0 && memmem(p + span.start, span.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// Whether a string value is exactly `name` (no escapes).
    func string(_ span: ByteSpan, is name: StaticString) -> Bool {
        guard let raw = rawString(span), raw.count == name.utf8CodeUnitCount else { return false }
        return memcmp(raw.baseAddress!, name.utf8Start, raw.count) == 0
    }

    /// The first well-formed `[hr:RUN:PATH]` in a value's raw bytes. Tags are plain ASCII, so the
    /// (possibly huge, escaped) prompt around them is never decoded.
    func firstTag(_ span: ByteSpan) -> TaskRef? {
        let needle: StaticString = "[hr:"
        var pos = span.start
        while pos < span.end, let hit = memmem(p + pos, span.end - pos, needle.utf8Start, needle.utf8CodeUnitCount) {
            let at = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - p
            let bodyStart = at + needle.utf8CodeUnitCount
            let limit = min(span.end, bodyStart + TaskRunID.maxLength + TaskPath.maxLength + 2)
            if let close = memchr(p + bodyStart, 0x5D, max(0, limit - bodyStart)) {
                let end = UnsafePointer<UInt8>(close.assumingMemoryBound(to: UInt8.self)) - p
                if let ref = TaskRef(String(decoding: UnsafeBufferPointer(start: p + bodyStart, count: end - bodyStart), as: UTF8.self)) { return ref }
            }
            pos = bodyStart
        }
        return nil
    }

    /// Bytes between `open` and `close` inside `span`, for the harness's own XML-ish notices.
    func between(_ span: ByteSpan, _ open: StaticString, _ close: StaticString, limit: Int = 400) -> String? {
        guard let a = memmem(p + span.start, span.count, open.utf8Start, open.utf8CodeUnitCount) else { return nil }
        let start = UnsafePointer<UInt8>(a.assumingMemoryBound(to: UInt8.self)) - p + open.utf8CodeUnitCount
        let room = min(span.end - start, limit)
        guard room > 0, let b = memmem(p + start, room, close.utf8Start, close.utf8CodeUnitCount) else { return nil }
        let end = UnsafePointer<UInt8>(b.assumingMemoryBound(to: UInt8.self)) - p
        return String(decoding: UnsafeBufferPointer(start: p + start, count: end - start), as: UTF8.self)
    }
}

/// Matches a T3 Code delegate to the session it started without storing the brief: the start of
/// the brief, whitespace collapsed, hashed. T3 Code puts a sentence of its own in front ("Act as
/// the … sub-agent for this task."), so a child's first message is hashed from every word start
/// near its beginning.
public enum Fingerprint {
    /// Bytes of the normalized brief that are compared.
    static let length = 160
    /// Briefs shorter than this never bind: too likely to repeat.
    static let minimum = 24
    /// How far into the child's first message the brief may start.
    static let reach = 320

    static func normalized(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(text.utf8.count, reach + length + 8))
        var space = false
        for b in text.utf8 {
            if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 {
                space = !out.isEmpty
                continue
            }
            if space { out.append(0x20); space = false }
            out.append(b)
            if out.count >= reach + length { break }
        }
        return out
    }

    /// FNV-1a, 64 bits: stable across launches, unlike `Hasher`.
    static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    /// The delegate's side; nil for a brief too short to tell apart.
    static func brief(_ task: String) -> UInt64? {
        let n = normalized(task)
        guard n.count >= minimum else { return nil }
        return hash(n[0..<min(length, n.count)])
    }

    /// The child's side: one hash per word start within `reach`.
    static func candidates(_ firstMessage: String) -> [UInt64] {
        let n = normalized(firstMessage)
        guard n.count >= minimum else { return [] }
        var out: [UInt64] = []
        var i = 0
        while i < min(n.count, reach) {
            if i == 0 || n[i - 1] == 0x20 { out.append(hash(n[i..<min(i + length, n.count)])) }
            i += 1
        }
        return out
    }
}

// MARK: - Claude Code

/// What the task observer needs from one Claude Code transcript line. Everything else (tool
/// inputs and outputs, what anyone typed) is skipped unread or read and dropped.
enum ClaudeTranscript {
    enum Tool: String, Codable, Sendable { case agent, delegate, workflow, taskStatus }

    struct Spawn {
        var id: String
        var tool: Tool
        var title: String?
        var agentType: String?
        var model: String?
        var provider: String?
        var tag: TaskRef?
        var brief: UInt64?
        var statusTaskID: String?
    }

    struct Result {
        var toolUseID: String
        var isError: Bool
        /// The text of the result, only for tools whose result is JSON we read.
        var text: String?
    }

    /// `toolUseResult` fields.
    struct ResultMeta {
        var agentID: String?
        var status: String?
        var model: String?
        var runID: String?
        var workflowName: String?
    }

    struct Line {
        var assistant = false
        var at: Double?
        var sessionID: String?
        var cwd: String?
        var messageKey: String?
        var model: String?
        var tokens: Int64 = 0
        var endTurn = false
        /// A workflow agent handing back its result: its last act.
        var returnsOutput = false
        var spawns: [Spawn] = []
        var results: [Result] = []
        var resultMeta: ResultMeta?
        /// `<task-notification>`: a background agent or workflow ended.
        var notice: (toolUseID: String, status: String)?
        /// T3 Code: "Delegated task ID (title) [status]:", or nil status for "asked a question".
        var delegateNotice: (taskID: String, status: String?)?
        /// The first message's text, only when asked for (to match a delegate).
        var text: String?
    }

    /// Every `"tool_use_id":"…"` value in a line, read off the bytes.
    static func resultIDs(_ p: UnsafePointer<UInt8>, _ n: Int) -> [String] {
        let needle: StaticString = "\"tool_use_id\":\""
        var out: [String] = []
        var pos = 0
        while pos < n, let hit = memmem(p + pos, n - pos, needle.utf8Start, needle.utf8CodeUnitCount) {
            let start = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - p + needle.utf8CodeUnitCount
            guard let q = memchr(p + start, 0x22, min(n - start, 200)) else { break }
            let end = UnsafePointer<UInt8>(q.assumingMemoryBound(to: UInt8.self)) - p
            out.append(String(decoding: UnsafeBufferPointer(start: p + start, count: end - start), as: UTF8.self))
            pos = end
        }
        return out
    }

    static func tool(_ raw: UnsafeBufferPointer<UInt8>) -> Tool? {
        func eq(_ s: StaticString) -> Bool { raw.count == s.utf8CodeUnitCount && memcmp(raw.baseAddress!, s.utf8Start, raw.count) == 0 }
        if eq("Agent") || eq("Task") { return .agent }
        if eq("mcp__t3-code__delegate_task") { return .delegate }
        if eq("Workflow") { return .workflow }
        if eq("mcp__t3-code__task_status") { return .taskStatus }
        return nil
    }

    /// `wanted` says whether a tool result belongs to a spawn being tracked and whether its
    /// text is needed; `wantText` asks for the text of a first user message.
    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, wanted: (String) -> (tracked: Bool, text: Bool), wantText: Bool) -> Line? {
        let assistant = Bytes.contains(p, n, "\"type\":\"assistant\"")
        if !assistant {
            guard Bytes.contains(p, n, "\"type\":\"user\"") else { return nil }
            let notice = Bytes.contains(p, n, "task-notification") || Bytes.contains(p, n, "\"content\":\"Delegated task ")
            // Tool results (often megabytes of output) are walked only when one is for a tracked spawn.
            guard wantText || notice || resultIDs(p, n).contains(where: { wanted($0).tracked }) else { return nil }
        }
        let spawning = assistant && (Bytes.contains(p, n, "\"name\":\"Agent\"") || Bytes.contains(p, n, "\"name\":\"Task\"")
            || Bytes.contains(p, n, "\"name\":\"mcp__t3-code__") || Bytes.contains(p, n, "\"name\":\"Workflow\"")
            || Bytes.contains(p, n, "\"name\":\"StructuredOutput\""))
        let s = JSONScan(p, n)
        var line = Line()
        var type: ByteSpan?
        var message: ByteSpan?
        var requestID: String?
        var resultSpan: ByteSpan?
        var isMeta = false
        let ok = s.forEachMember(0) { k, v in
            if s.key(k, is: "type") { type = v }
            else if s.key(k, is: "message") { message = v }
            else if s.key(k, is: "timestamp") { line.at = s.rawString(v).flatMap(FastTimestamp.parse) }
            else if s.key(k, is: "sessionId") { line.sessionID = s.string(v) }
            else if s.key(k, is: "cwd") { line.cwd = s.string(v) }
            else if s.key(k, is: "requestId") { requestID = s.string(v) }
            else if s.key(k, is: "toolUseResult") { resultSpan = v }
            else if s.key(k, is: "isMeta") { isMeta = s.bool(v) == true }
            return true
        }
        guard ok, let type, let message else { return nil }
        if s.string(type, is: "assistant") { line.assistant = true } else if !s.string(type, is: "user") { return nil }

        var content: ByteSpan?
        var messageID: String?
        var usage: ByteSpan?
        s.forEachMember(message.start) { k, v in
            if s.key(k, is: "content") { content = v }
            else if s.key(k, is: "id") { messageID = s.string(v) }
            else if s.key(k, is: "model") { line.model = s.string(v) }
            else if s.key(k, is: "usage") { usage = v }
            else if s.key(k, is: "stop_reason") { line.endTurn = s.string(v, is: "end_turn") }
            return true
        }
        if line.assistant {
            if let messageID { line.messageKey = requestID.map { messageID + ":" + $0 } ?? messageID }
            if let usage, let u = ClaudeLogParser.parseUsage(s, usage) { line.tokens = u.tokens.fresh }
            if spawning, let content { spawns(s, content, into: &line) }
            return line
        }
        guard let content else { return line }
        if p[s.skipSpace(content.start)] == 0x22 {
            // A plain message: a notice from the harness, or what someone typed.
            if s.contains(content, "<task-notification>"), let id = s.between(content, "<tool-use-id>", "</tool-use-id>"),
               let status = s.between(content, "<status>", "</status>") {
                line.notice = (id, status)
            } else if let raw = s.rawString(content), raw.count > 15, memcmp(raw.baseAddress!, "Delegated task ", 15) == 0 {
                line.delegateNotice = delegateNotice(raw)
            } else if wantText, !isMeta {
                line.text = s.string(content)
            }
            return line
        }
        var resultIDs: [String] = []
        s.forEachElement(content.start) { el in
            var kind: ByteSpan?, id: String?, isError = false, body: ByteSpan?, text: ByteSpan?
            s.forEachMember(el.start) { k, v in
                if s.key(k, is: "type") { kind = v }
                else if s.key(k, is: "tool_use_id") { id = s.string(v) }
                else if s.key(k, is: "is_error") { isError = s.bool(v) == true }
                else if s.key(k, is: "content") { body = v }
                else if s.key(k, is: "text") { text = v }
                return true
            }
            guard let kind else { return true }
            if s.string(kind, is: "tool_result"), let id {
                let w = wanted(id)
                guard w.tracked else { return true }
                resultIDs.append(id)
                line.results.append(Result(toolUseID: id, isError: isError, text: w.text ? body.flatMap { resultText(s, $0) } : nil))
            } else if s.string(kind, is: "text"), wantText, !isMeta, line.text == nil, let text {
                line.text = s.string(text)
            }
            return true
        }
        if !resultIDs.isEmpty, let resultSpan, p[s.skipSpace(resultSpan.start)] == 0x7B {
            var m = ResultMeta()
            s.forEachMember(resultSpan.start) { k, v in
                if s.key(k, is: "agentId") { m.agentID = s.string(v) }
                else if s.key(k, is: "status") { m.status = s.string(v) }
                else if s.key(k, is: "resolvedModel") { m.model = s.string(v) }
                else if s.key(k, is: "runId") { m.runID = s.string(v) }
                else if s.key(k, is: "workflowName") { m.workflowName = s.string(v) }
                return true
            }
            line.resultMeta = m
        }
        return line
    }

    static func spawns(_ s: JSONScan, _ content: ByteSpan, into line: inout Line) {
        s.forEachElement(content.start) { el in
            var kind: ByteSpan?, id: String?, tool: Tool?, input: ByteSpan?, returns = false
            s.forEachMember(el.start) { k, v in
                if s.key(k, is: "type") { kind = v }
                else if s.key(k, is: "id") { id = s.string(v) }
                else if s.key(k, is: "name") {
                    if let raw = s.rawString(v) { tool = Self.tool(raw); returns = raw.count == 16 && memcmp(raw.baseAddress!, "StructuredOutput", 16) == 0 }
                }
                else if s.key(k, is: "input") { input = v }
                return true
            }
            guard let kind, s.string(kind, is: "tool_use") else { return true }
            if returns { line.returnsOutput = true }
            guard let id, let tool, let input else { return true }
            var sp = Spawn(id: id, tool: tool)
            var tags: [ByteSpan] = []
            s.forEachMember(input.start) { k, v in
                switch tool {
                case .agent:
                    if s.key(k, is: "description") { sp.title = s.string(v); tags.insert(v, at: 0) }
                    else if s.key(k, is: "subagent_type") { sp.agentType = s.string(v) }
                    else if s.key(k, is: "model") { sp.model = s.string(v) }
                    else if s.key(k, is: "prompt") { tags.append(v) }
                case .delegate:
                    if s.key(k, is: "title") { sp.title = s.string(v); tags.insert(v, at: 0) }
                    else if s.key(k, is: "role") { sp.agentType = s.string(v) }
                    else if s.key(k, is: "task") { tags.append(v); sp.brief = s.string(v).flatMap(Fingerprint.brief) }
                    else if s.key(k, is: "target") {
                        s.forEachMember(v.start) { k2, v2 in
                            if s.key(k2, is: "model") { sp.model = s.string(v2) }
                            else if s.key(k2, is: "providerInstanceId") { sp.provider = providerName(s.string(v2)) }
                            return true
                        }
                    }
                case .workflow:
                    break
                case .taskStatus:
                    if s.key(k, is: "taskId") { sp.statusTaskID = s.string(v) }
                }
                return true
            }
            sp.tag = tags.lazy.compactMap { s.firstTag($0) }.first
            line.spawns.append(sp)
            return true
        }
    }

    /// The text of a tool result: a string, or the first text block.
    static func resultText(_ s: JSONScan, _ body: ByteSpan) -> String? {
        if s.p[s.skipSpace(body.start)] == 0x22 { return s.string(body) }
        var out: String?
        s.forEachElement(body.start) { el in
            s.forEachMember(el.start) { k, v in
                if s.key(k, is: "text") { out = s.string(v) }
                return out == nil
            }
            return out == nil
        }
        return out
    }

    /// "Delegated task ID (title) [status]:" on the first line, or "Delegated task ID asked a question …".
    static func delegateNotice(_ raw: UnsafeBufferPointer<UInt8>) -> (String, String?)? {
        let bytes = Array(raw.prefix(2000))
        var end = bytes.count
        // The first line ends at an escaped newline.
        for i in 0..<max(0, bytes.count - 1) where bytes[i] == 0x5C && bytes[i + 1] == 0x6E { end = i; break }
        let first = bytes[15..<end]
        guard let space = first.firstIndex(of: 0x20) else { return nil }
        let id = String(decoding: first[first.startIndex..<space], as: UTF8.self)
        let rest = String(decoding: first[space...], as: UTF8.self)
        if rest.hasPrefix(" asked a question") { return (id, nil) }
        guard let close = rest.range(of: "]:", options: .backwards), let open = rest[..<close.lowerBound].lastIndex(of: "[") else { return nil }
        return (id, String(rest[rest.index(after: open)..<close.lowerBound]))
    }

    /// Only the harness family, never the instance id (which can name the account).
    static func providerName(_ instance: String?) -> String? {
        guard let i = instance?.lowercased() else { return nil }
        if i.contains("codex") || i.contains("openai") { return "codex" }
        if i.contains("claude") || i.contains("anthropic") { return "claude" }
        return nil
    }
}

// MARK: - Codex

/// What the task observer needs from one Codex rollout line.
enum CodexTranscript {
    enum Event {
        case meta(id: String, cwd: String?, at: Double?)
        case model(String)
        case started, completed, aborted
        case tokens(Int64)
        case text(String)
    }

    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, wantText: Bool) -> (at: Double?, event: Event)? {
        let head = min(n, 220)
        enum Kind { case meta, context, event, item }
        let kind: Kind
        if Bytes.contains(p, head, "\"type\":\"event_msg\"") {
            guard Bytes.contains(p, head, "\"type\":\"token_count\"") || Bytes.contains(p, head, "\"type\":\"task_started\"")
                || Bytes.contains(p, head, "\"type\":\"task_complete\"") || Bytes.contains(p, head, "\"type\":\"turn_aborted\"") else { return nil }
            kind = .event
        } else if Bytes.contains(p, head, "\"type\":\"session_meta\"") {
            kind = .meta
        } else if Bytes.contains(p, head, "\"type\":\"turn_context\"") {
            kind = .context
        } else if wantText, Bytes.contains(p, head, "\"type\":\"response_item\""), Bytes.contains(p, min(n, 400), "\"role\":\"user\""),
                  Bytes.contains(p, n, "\"user.text\"") {
            kind = .item
        } else {
            return nil
        }
        let s = JSONScan(p, n)
        var at: Double?
        var payload: ByteSpan?
        s.forEachMember(0) { k, v in
            if s.key(k, is: "timestamp") { at = s.rawString(v).flatMap(FastTimestamp.parse) }
            else if s.key(k, is: "payload") { payload = v }
            return true
        }
        guard let payload else { return nil }
        switch kind {
        case .meta:
            var id: String?, cwd: String?, started: Double?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "id") { id = s.string(v) }
                else if s.key(k, is: "cwd") { cwd = s.string(v) }
                else if s.key(k, is: "timestamp") { started = s.rawString(v).flatMap(FastTimestamp.parse) }
                return true
            }
            return id.map { (at, .meta(id: $0, cwd: cwd, at: started ?? at)) }
        case .context:
            var model: String?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "model") { model = s.string(v) }
                return true
            }
            return model.map { (at, .model($0)) }
        case .event:
            var type: ByteSpan?, info: ByteSpan?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "type") { type = v }
                else if s.key(k, is: "info") { info = s.isNull(v) ? nil : v }
                return true
            }
            guard let type else { return nil }
            if s.string(type, is: "task_started") { return (at, .started) }
            if s.string(type, is: "task_complete") { return (at, .completed) }
            if s.string(type, is: "turn_aborted") { return (at, .aborted) }
            guard let info else { return nil }
            var total: [Int64]?
            s.forEachMember(info.start) { k, v in
                if s.key(k, is: "total_token_usage") { total = CodexLogParser.codexTotals(s, v) }
                return true
            }
            // input − cached + output: the tokens that weren't cache reads.
            return total.map { (at, .tokens(max(0, $0[0] - $0[1]) + $0[2])) }
        case .item:
            var text: String?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "content") {
                    s.forEachElement(v.start) { el in
                        s.forEachMember(el.start) { k2, v2 in
                            if s.key(k2, is: "text") { text = s.string(v2) }
                            return text == nil
                        }
                        return text == nil
                    }
                }
                return true
            }
            return text.map { (at, .text($0)) }
        }
    }
}
