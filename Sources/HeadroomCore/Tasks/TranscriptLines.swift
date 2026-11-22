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
        /// `TaskCreate`: the new item's id (`task.id`).
        var taskID: String?
    }

    struct Line {
        var assistant = false
        var at: Double?
        var sessionID: String?
        var cwd: String?
        var branch: String?
        /// Which app wrote it: `cli`, `claude-desktop`, `sdk-ts`, …
        var entrypoint: String?
        /// A tool result or progress line read only for its time: the session is still at work.
        var activityOnly = false
        /// "[Request interrupted by user]" (or "… for tool use"): the person stopped the turn.
        var interrupted = false
        /// The harness's usage-limit message ("You've hit your session limit · resets 3pm").
        var limit: String?
        /// Questions to a person and plan-list changes.
        var calls: [HarnessCall] = []
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

    static let interruptText: StaticString = "[Request interrupted by user"

    /// Whether a string value starts with Claude Code's interrupt marker.
    static func isInterrupt(_ s: JSONScan, _ v: ByteSpan) -> Bool {
        guard let raw = s.rawString(v), raw.count >= interruptText.utf8CodeUnitCount else { return false }
        return memcmp(raw.baseAddress!, interruptText.utf8Start, interruptText.utf8CodeUnitCount) == 0
    }

    /// A line's time, read off the bytes: the first `"timestamp":"…"`. Claude Code writes it right
    /// after `message`, whose strings can't hold an unescaped match.
    static func lineTime(_ p: UnsafePointer<UInt8>, _ n: Int) -> Double? {
        let needle: StaticString = "\"timestamp\":\""
        guard let hit = memmem(p, n, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        let start = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - p + needle.utf8CodeUnitCount
        guard let q = memchr(p + start, 0x22, min(n - start, 40)) else { return nil }
        let end = UnsafePointer<UInt8>(q.assumingMemoryBound(to: UInt8.self)) - p
        return FastTimestamp.parse(UnsafeBufferPointer(start: p + start, count: end - start))
    }

    /// A tool result or progress line: the session is at work. Its time is read (`lineTime`) only
    /// when no later line of the batch says more.
    static var activityOnly: Line {
        var line = Line()
        line.activityOnly = true
        return line
    }

    /// Also used on user lines skipped by the activity parser, such as untracked tool results.
    static func runMetadata(_ p: UnsafePointer<UInt8>, _ n: Int) -> (ai: String?, custom: String?, branch: String?)? {
        let head = min(n, 220)
        guard Bytes.contains(p, head, "\"type\":\"ai-title\"") || Bytes.contains(p, head, "\"type\":\"custom-title\"")
            || Bytes.contains(p, head, "\"aiTitle\"") || Bytes.contains(p, head, "\"customTitle\"")
            // Every line carries the branch after its message: a short one says it as well as a
            // multi-megabyte tool result, without scanning the result byte by byte.
            || (n <= 64 * 1024 && Bytes.contains(p, n, "\"gitBranch\"")) else { return nil }
        let s = JSONScan(p, n)
        var type: ByteSpan?, ai: String?, custom: String?, branch: String?
        guard s.forEachMember(0, { k, v in
            if s.key(k, is: "type") { type = v }
            else if v.count <= 8192 {
                if s.key(k, is: "aiTitle") { ai = TaskText.title(s.string(v)) }
                else if s.key(k, is: "customTitle") { custom = TaskText.title(s.string(v)) }
                else if s.key(k, is: "gitBranch") { branch = TaskText.clean(s.string(v), limit: 400) }
            }
            return true
        }), let type else { return nil }
        if let ai, s.string(type, is: "ai-title") { return (ai, nil, nil) }
        if let custom, s.string(type, is: "custom-title") { return (nil, custom, nil) }
        if let branch, s.string(type, is: "user") || s.string(type, is: "assistant") { return (nil, nil, branch) }
        return nil
    }

    /// Which tool calls an assistant line makes, from its `"name":"…"` keys: one pass over the bytes.
    static func toolNames(_ p: UnsafePointer<UInt8>, _ n: Int) -> (spawning: Bool, calling: Bool) {
        let needle: StaticString = "\"name\":\""
        var spawning = false, calling = false
        var pos = 0
        while pos < n, let hit = memmem(p + pos, n - pos, needle.utf8Start, needle.utf8CodeUnitCount) {
            let start = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - p + needle.utf8CodeUnitCount
            guard let q = memchr(p + start, 0x22, min(n - start, 80)) else { pos = start; continue }
            let end = UnsafePointer<UInt8>(q.assumingMemoryBound(to: UInt8.self)) - p
            let raw = UnsafeBufferPointer(start: p + start, count: end - start)
            if tool(raw) != nil || (raw.count == 16 && memcmp(raw.baseAddress!, "StructuredOutput", 16) == 0) { spawning = true }
            else if HarnessCall.isWatched(raw) { calling = true }
            pos = end
        }
        return (spawning, calling)
    }

    /// `wanted` says whether a tool result belongs to a spawn or call being tracked and whether
    /// its text is needed; `wantText` asks for the text of a first user message.
    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, wanted: (String) -> (tracked: Bool, text: Bool), wantText: Bool, readBranch: Bool) -> Line? {
        let assistant = Bytes.contains(p, n, "\"type\":\"assistant\"")
        var interruptHint = false
        if !assistant {
            guard Bytes.contains(p, n, "\"type\":\"user\"") else {
                // Older Claude Code wrote a foreground agent's and a long command's progress as
                // lines of their own; the type sits near the start.
                return Bytes.contains(p, min(n, 600), "\"type\":\"progress\"") ? activityOnly : nil
            }
            let notice = Bytes.contains(p, n, "task-notification") || Bytes.contains(p, n, "\"content\":\"Delegated task ")
            // The marker is a short line of its own; tool output is never looked into for it.
            interruptHint = n < 16_384 && Bytes.contains(p, n, interruptText)
            // Tool results (often megabytes of output) are walked only when one is for a tracked
            // spawn or call; any other result only says the session is still at work.
            let ids = resultIDs(p, n)
            guard wantText || notice || interruptHint || ids.contains(where: { wanted($0).tracked }) else {
                return ids.isEmpty ? nil : activityOnly
            }
        }
        let (spawning, calling) = assistant ? toolNames(p, n) : (false, false)
        // The harness's own error lines are small.
        let limitHint = assistant && n < 16_384 && (Bytes.contains(p, n, "\"isApiErrorMessage\":true") || Bytes.contains(p, n, "\"error\":\"rate_limit\"")
            || (Bytes.contains(p, n, "\"model\":\"<synthetic>\"") && Bytes.contains(p, n, "limit")))
        let s = JSONScan(p, n)
        var line = Line()
        var type: ByteSpan?
        var message: ByteSpan?
        var requestID: String?
        var resultSpan: ByteSpan?
        var isMeta = false
        var apiError = false
        var rateLimited = false
        let ok = s.forEachMember(0) { k, v in
            if s.key(k, is: "type") { type = v }
            else if s.key(k, is: "message") { message = v }
            else if s.key(k, is: "timestamp") { line.at = s.rawString(v).flatMap(FastTimestamp.parse) }
            else if s.key(k, is: "sessionId") { line.sessionID = s.string(v) }
            else if s.key(k, is: "cwd") { line.cwd = s.string(v) }
            else if readBranch, s.key(k, is: "gitBranch"), v.count <= 8192 { line.branch = TaskText.clean(s.string(v), limit: 400) }
            else if s.key(k, is: "entrypoint") { line.entrypoint = s.string(v) }
            else if s.key(k, is: "requestId") { requestID = s.string(v) }
            else if s.key(k, is: "toolUseResult") { resultSpan = v }
            else if s.key(k, is: "isMeta") { isMeta = s.bool(v) == true }
            else if s.key(k, is: "isApiErrorMessage") { apiError = s.bool(v) == true }
            else if s.key(k, is: "error") { rateLimited = s.string(v, is: "rate_limit") }
            return true
        }
        guard ok, let type, let message else { return nil }
        if s.string(type, is: "assistant") { line.assistant = true } else if !s.string(type, is: "user") {
            return s.string(type, is: "progress") ? activityOnly : nil
        }

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
            if spawning || calling, let content { spawns(s, content, into: &line) }
            if limitHint, let content, let text = firstText(s, content) {
                let lower = text.lowercased()
                if rateLimited || (apiError || line.model == "<synthetic>") && lower.contains("limit")
                    && (lower.contains("limit reached") || lower.contains("hit your")) {
                    line.limit = HarnessText.limitNote(text)
                }
            }
            return line
        }
        guard let content else { return line }
        if p[s.skipSpace(content.start)] == 0x22 {
            // A plain message: a notice from the harness, or what someone typed.
            if interruptHint, isInterrupt(s, content) {
                line.interrupted = true
            } else if s.contains(content, "<task-notification>"), let id = s.between(content, "<tool-use-id>", "</tool-use-id>"),
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
            } else if s.string(kind, is: "text"), let text {
                if interruptHint, isInterrupt(s, text) { line.interrupted = true }
                else if wantText, !isMeta, line.text == nil { line.text = s.string(text) }
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
                else if s.key(k, is: "task"), s.p[s.skipSpace(v.start)] == 0x7B {
                    s.forEachMember(v.start) { k2, v2 in
                        if s.key(k2, is: "id") { m.taskID = s.string(v2) ?? s.int(v2).map(String.init) }
                        return m.taskID == nil
                    }
                }
                return true
            }
            line.resultMeta = m
        }
        return line
    }

    /// The first text block of an assistant message's content.
    static func firstText(_ s: JSONScan, _ content: ByteSpan) -> String? {
        var out: String?
        s.forEachElement(content.start) { el in
            var kind: ByteSpan?, text: ByteSpan?
            s.forEachMember(el.start) { k, v in
                if s.key(k, is: "type") { kind = v } else if s.key(k, is: "text") { text = v }
                return true
            }
            if let kind, s.string(kind, is: "text"), let text { out = s.string(text) }
            return out == nil
        }
        return out
    }

    static func spawns(_ s: JSONScan, _ content: ByteSpan, into line: inout Line) {
        s.forEachElement(content.start) { el in
            var kind: ByteSpan?, id: String?, tool: Tool?, input: ByteSpan?, returns = false, name: String?
            s.forEachMember(el.start) { k, v in
                if s.key(k, is: "type") { kind = v }
                else if s.key(k, is: "id") { id = s.string(v) }
                else if s.key(k, is: "name") {
                    if let raw = s.rawString(v) {
                        tool = Self.tool(raw); returns = raw.count == 16 && memcmp(raw.baseAddress!, "StructuredOutput", 16) == 0
                        if tool == nil, HarnessCall.isWatched(raw) { name = String(decoding: raw, as: UTF8.self) }
                    }
                }
                else if s.key(k, is: "input") { input = v }
                return true
            }
            guard let kind, s.string(kind, is: "tool_use") else { return true }
            if returns { line.returnsOutput = true }
            if let name, let id {
                // The few harness tools read for questions and plans: small inputs, decoded whole.
                let object = input.flatMap { span in
                    try? JSONSerialization.jsonObject(with: Data(UnsafeBufferPointer(start: s.p + span.start, count: span.count)))
                } as? [String: Any]
                if let call = HarnessCall.read(name: name, id: id, input: object ?? [:]) { line.calls.append(call) }
                return true
            }
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

// MARK: - Questions and plans

/// A harness tool call read for what it says to a person or about the session's plan. Only these
/// inputs are decoded, and only the question, its answers and the plan's titles are kept.
enum HarnessCall: Equatable {
    /// A question waiting on a person. `async`: Codex's `request_user_input_async`, whose output
    /// comes back at once; the person's next message answers it.
    case ask(id: String, text: String, options: [String], async: Bool)
    /// The whole list: titles and statuses in order, with the harness's ids when it has them.
    case planList(tool: String, items: [PlanDraft])
    /// Claude Code `TaskCreate`: one new item, whose id comes back in the result.
    case planCreate(id: String, title: String)
    /// Claude Code `TaskUpdate`.
    case planUpdate(taskID: String, status: String?, title: String?)
    /// The Claude desktop app's plan tool without `items`: steps by position, 1-based.
    case planStep(advance: Bool, done: [Int], start: Int?)
    /// The desktop app's turn wrap-up, which checks off the list.
    case planFinish

    struct PlanDraft: Equatable {
        var id: String?
        var title: String
        var status: String?
    }

    static let watched: [StaticString] = ["AskUserQuestion", "ExitPlanMode", "TodoWrite", "TaskCreate", "TaskUpdate",
                                          "mcp__ccd_turn__update_plan", "mcp__ccd_turn__wrap_up"]

    static func isWatched(_ raw: UnsafeBufferPointer<UInt8>) -> Bool {
        watched.contains { raw.count == $0.utf8CodeUnitCount && memcmp(raw.baseAddress!, $0.utf8Start, raw.count) == 0 }
    }

    /// Plan tool names as `plan.mirror` gives them.
    static func toolLabel(_ name: String) -> String {
        switch name {
        case "TodoWrite": "todo"
        case "TaskCreate", "TaskUpdate": "tasks"
        case "update_plan": "codex-plan"
        default: "desktop-plan"
        }
    }

    static func read(name: String, id: String, input: [String: Any]) -> HarnessCall? {
        switch name {
        case "AskUserQuestion", "request_user_input", "request_user_input_async":
            guard let q = HarnessText.question(input) else { return nil }
            return .ask(id: id, text: q.text, options: q.options, async: name.hasSuffix("_async"))
        case "ExitPlanMode":
            let first = (input["plan"] as? String).flatMap(HarnessText.firstLine)
            return .ask(id: id, text: HarnessText.clip("Approve the plan?" + (first.map { " " + $0 } ?? ""), TaskQuestion.maxLength),
                        options: ["Approve", "Keep planning"], async: false)
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return nil }
            return .planList(tool: toolLabel(name), items: todos.compactMap { t in
                (t["content"] as? String).map { PlanDraft(id: (t["id"] as? String) ?? (t["id"] as? Int).map(String.init), title: $0, status: t["status"] as? String) }
            })
        case "update_plan":
            guard let plan = input["plan"] as? [[String: Any]] else { return nil }
            return .planList(tool: toolLabel(name), items: plan.compactMap { t in
                (t["step"] as? String).map { PlanDraft(title: $0, status: t["status"] as? String) }
            })
        case "TaskCreate":
            guard let subject = input["subject"] as? String else { return nil }
            return .planCreate(id: id, title: subject)
        case "TaskUpdate":
            guard let task = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init) else { return nil }
            return .planUpdate(taskID: task, status: input["status"] as? String, title: input["subject"] as? String)
        case "mcp__ccd_turn__update_plan":
            if let items = input["items"] as? [[String: Any]] {
                return .planList(tool: toolLabel(name), items: items.compactMap { t in
                    (t["content"] as? String).map { PlanDraft(title: $0, status: t["status"] as? String) }
                })
            }
            let done = (input["done"] as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } } ?? []
            let start = (input["start"] as? Int) ?? (input["start"] as? String).flatMap { Int($0) }
            let advance = input["advance"] as? Bool ?? false
            guard advance || !done.isEmpty || start != nil else { return nil }
            return .planStep(advance: advance, done: done, start: start)
        case "mcp__ccd_turn__wrap_up":
            return .planFinish
        default:
            return nil
        }
    }
}

/// Trimming for what the observer writes from harness tool inputs.
enum HarnessText {
    static let optionLimit = 6
    static let optionLength = 60
    static let titleLength = 120
    static let noteLength = 120

    /// Whitespace collapsed, cut to `limit` characters with an ellipsis.
    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The first line with text, without Markdown heading or list marks.
    static func firstLine(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let t = raw.drop { $0 == "#" || $0 == "*" || $0 == "-" || $0 == ">" || $0.isWhitespace }
            if !t.isEmpty { return clip(String(t), titleLength) }
        }
        return nil
    }

    /// The first question of `questions` (Claude Code `question`, Codex `question` or `title`),
    /// with "(+N more)" when there are others, and its answers' labels.
    static func question(_ input: [String: Any]) -> (text: String, options: [String])? {
        guard let qs = input["questions"] as? [[String: Any]], let first = qs.first,
              let raw = (first["question"] as? String) ?? (first["title"] as? String) ?? (first["header"] as? String),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let more = qs.count > 1 ? " (+\(qs.count - 1) more)" : ""
        let text = clip(raw, TaskQuestion.maxLength - more.count) + more
        let labels = (first["options"] as? [Any] ?? []).compactMap { o -> String? in
            let l = (o as? String) ?? (o as? [String: Any])?["label"] as? String
            return l.map { clip($0, optionLength) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return (text, Array(labels.prefix(optionLimit)))
    }

    /// The harness's limit message, without the reset epoch older Claude Code appended ("…|1760000000").
    static func limitNote(_ text: String) -> String {
        var t = Substring(text)
        if let bar = t.lastIndex(of: "|"), t[t.index(after: bar)...].allSatisfy(\.isNumber) { t = t[..<bar] }
        let note = clip(String(t), noteLength)
        return note.isEmpty ? "Usage limit reached" : note
    }

    /// A stable id for an item the harness gives none: its position and a hash of its title.
    static func positionalID(_ index: Int, _ title: String) -> String {
        let h = Fingerprint.hash(Array(title.utf8)[...])
        return "\(index + 1)-" + String(String(h, radix: 16).prefix(6))
    }
}

// MARK: - Codex

/// What the task observer needs from one Codex rollout line.
enum CodexTranscript {
    enum Event {
        case meta(id: String, cwd: String?, at: Double?, repo: String?, branch: String?)
        case model(String)
        case started
        /// The turn ended; `limited` when it ended on a usage limit.
        case completed(limited: Bool)
        /// `turn_aborted`; `interrupted` when the person stopped it.
        case aborted(interrupted: Bool)
        /// Running total; `limited` when the rate-limit snapshot says a limit was reached.
        case tokens(Int64, limited: Bool)
        case text(String)
        /// Any other line of a turn: a tool call, its output, reasoning.
        case activity
        /// A user message other than the first (answers an async question).
        case userMessage
        /// `update_plan` or `request_user_input`.
        case call(HarnessCall)
        /// The output of a call the observer waits on.
        case output(callID: String)
        /// An error event saying a usage limit was hit.
        case limit
    }

    /// A line's time, its first key in Codex's lines: read without walking the payload.
    static func activity(_ p: UnsafePointer<UInt8>, _ n: Int) -> Double? {
        let s = JSONScan(p, n)
        var at: Double?
        var first = true
        s.forEachMember(0) { k, v in
            if s.key(k, is: "timestamp") { at = s.rawString(v).flatMap(FastTimestamp.parse) }
            defer { first = false }
            return at == nil && first
        }
        return at
    }

    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, wantText: Bool, pendingCall: String? = nil) -> (at: Double?, event: Event)? {
        let head = min(n, 220)
        enum Kind { case meta, context, event, item, call, output, activity }
        let kind: Kind
        if Bytes.contains(p, head, "\"type\":\"event_msg\"") {
            if Bytes.contains(p, head, "\"type\":\"token_count\"") || Bytes.contains(p, head, "\"type\":\"task_started\"")
                || Bytes.contains(p, head, "\"type\":\"task_complete\"") || Bytes.contains(p, head, "\"type\":\"turn_aborted\"")
                || (Bytes.contains(p, head, "\"type\":\"error\"") && Bytes.contains(p, n, "usage_limit")) {
                kind = .event
            } else {
                kind = .activity
            }
        } else if Bytes.contains(p, head, "\"type\":\"session_meta\"") {
            kind = .meta
        } else if Bytes.contains(p, head, "\"type\":\"turn_context\"") {
            kind = .context
        } else if Bytes.contains(p, head, "\"type\":\"response_item\"") {
            if Bytes.contains(p, min(n, 400), "\"role\":\"user\"") {
                kind = wantText && Bytes.contains(p, n, "\"user.text\"") ? .item : .activity
                if kind == .activity {
                    // Codex's own context messages ride as user messages too; only typed ones answer.
                    guard let r = activity(p, n) else { return nil }
                    return Bytes.contains(p, n, "\"user.text\"") || !Bytes.contains(p, n, "content_item_kinds") ? (r, .userMessage) : (r, .activity)
                }
            } else if Bytes.contains(p, min(n, 600), "\"name\":\"update_plan\"") || Bytes.contains(p, min(n, 600), "\"name\":\"request_user_input") {
                // A call's name sits in the first few hundred bytes.
                kind = .call
            } else if let id = pendingCall, Bytes.contains(p, min(n, 400), "_output\""), memmem(p, min(n, 800), id, id.utf8.count) != nil {
                kind = .output
            } else {
                kind = .activity
            }
        } else {
            return nil
        }
        if kind == .activity { return activity(p, n).map { ($0, .activity) } }
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
        case .activity:
            return (at, .activity)
        case .call:
            var name: String?, callID: String?, args: String?, type: ByteSpan?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "type") { type = v }
                else if s.key(k, is: "name") { name = s.string(v) }
                else if s.key(k, is: "call_id") { callID = s.string(v) }
                else if s.key(k, is: "arguments") { args = s.string(v) }
                return true
            }
            guard let type, s.string(type, is: "function_call"), let name, let callID else { return (at, .activity) }
            let input = args.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            guard let call = HarnessCall.read(name: name, id: callID, input: input ?? [:]) else { return (at, .activity) }
            return (at, .call(call))
        case .output:
            var callID: String?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "call_id") { callID = s.string(v) }
                return callID == nil
            }
            return (at, callID.map { .output(callID: $0) } ?? .activity)
        case .meta:
            var id: String?, cwd: String?, started: Double?
            var repo: String?, branch: String?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "id") { id = s.string(v) }
                else if s.key(k, is: "cwd") { cwd = s.string(v) }
                else if s.key(k, is: "timestamp") { started = s.rawString(v).flatMap(FastTimestamp.parse) }
                else if s.key(k, is: "git") {
                    s.forEachMember(v.start) { k, v in
                        if v.count <= 8192 {
                            if s.key(k, is: "branch") { branch = TaskText.clean(s.string(v), limit: 400) }
                            else if s.key(k, is: "repository_url"), let url = s.string(v) { repo = TaskGit.slug(url) }
                        }
                        return true
                    }
                }
                return true
            }
            return id.map { (at, .meta(id: $0, cwd: cwd, at: started ?? at, repo: repo, branch: branch)) }
        case .context:
            var model: String?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "model") { model = s.string(v) }
                return true
            }
            return model.map { (at, .model($0)) }
        case .event:
            var type: ByteSpan?, info: ByteSpan?, reason: ByteSpan?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "type") { type = v }
                else if s.key(k, is: "info") { info = s.isNull(v) ? nil : v }
                else if s.key(k, is: "reason") { reason = v }
                return true
            }
            guard let type else { return nil }
            if s.string(type, is: "task_started") { return (at, .started) }
            // A turn that failed on a usage limit says so in its error (`usage_limit_exceeded`).
            if s.string(type, is: "task_complete") { return (at, .completed(limited: Bytes.contains(p, n, "usage_limit"))) }
            if s.string(type, is: "turn_aborted") { return (at, .aborted(interrupted: reason.map { s.string($0, is: "interrupted") } ?? false)) }
            if s.string(type, is: "error") { return (at, .limit) }
            // `rate_limits.rate_limit_reached_type` is null until a limit is hit.
            let limited = Bytes.contains(p, n, "\"rate_limit_reached_type\":\"")
            guard let info else { return limited ? (at, .limit) : (at, .activity) }
            var total: [Int64]?
            s.forEachMember(info.start) { k, v in
                if s.key(k, is: "total_token_usage") { total = CodexLogParser.codexTotals(s, v) }
                return true
            }
            // input − cached + output: the tokens that weren't cache reads. Wrapping: the totals are
            // whatever the line holds, and a damaged number must not trap.
            return total.map { (at, .tokens(max(0, $0[0] &- $0[1]) &+ $0[2], limited: limited)) } ?? (limited ? (at, .limit) : nil)
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
