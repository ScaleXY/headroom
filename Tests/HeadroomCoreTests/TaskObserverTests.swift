import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

/// Synthetic transcripts in the shapes Claude Code 2.1 and Codex 0.167 write.
enum Fx {
    /// Two hours ago, on the minute: transcripts' times sit just before their files' real mtimes.
    static let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 7200)
    static let cwd = "/Users/someone/code/demo"
    static func ts(_ s: Double) -> String { ISO8601DateFormatter.headroomMillis.string(from: t0.addingTimeInterval(s)) }

    static func json(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
    }

    static func quoted(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func assistant(_ s: Double, _ session: String, id: String, tokens: Int = 0, stop: String = "tool_use", _ content: [[String: Any]],
                          agent: String? = nil, extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["type": "assistant", "timestamp": ts(s), "sessionId": session, "cwd": cwd, "requestId": "req-" + id, "uuid": UUID().uuidString,
                                "message": ["id": id, "role": "assistant", "model": "claude-opus-5-5", "stop_reason": stop, "content": content,
                                            "usage": ["input_tokens": tokens, "output_tokens": tokens, "cache_read_input_tokens": 50_000, "cache_creation_input_tokens": 0]]]
        if let agent { o["agentId"] = agent; o["isSidechain"] = true }
        o.merge(extra) { _, new in new }
        return json(o)
    }

    static func text(_ t: String) -> [String: Any] { ["type": "text", "text": t] }

    static func agentCall(_ id: String, _ description: String, prompt: String) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": "Agent", "input": ["description": description, "prompt": prompt, "subagent_type": "general-purpose"]]
    }

    static func delegateCall(_ id: String, title: String, task: String, provider: String = "codex_someone_direct") -> [String: Any] {
        ["type": "tool_use", "id": id, "name": "mcp__t3-code__delegate_task",
         "input": ["title": title, "task": task, "role": "implementation", "mode": "full", "target": ["model": "gpt-6.1", "providerInstanceId": provider]]]
    }

    static func user(_ s: Double, _ session: String, _ content: Any, result: [String: Any]? = nil, agent: String? = nil, origin: [String: Any]? = nil) -> String {
        var o: [String: Any] = ["type": "user", "timestamp": ts(s), "sessionId": session, "cwd": cwd, "uuid": UUID().uuidString,
                                "message": ["role": "user", "content": content]]
        if let result { o["toolUseResult"] = result }
        if let agent { o["agentId"] = agent; o["isSidechain"] = true }
        if let origin { o["origin"] = origin }
        return json(o)
    }

    static func toolResult(_ id: String, _ text: Any, error: Bool = false) -> [[String: Any]] {
        [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]]
    }

    static func notification(_ s: Double, _ session: String, toolUseID: String, status: String) -> String {
        user(s, session, "<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>\(toolUseID)</tool-use-id>\n<status>\(status)</status>\n<summary>Agent \"x\" finished</summary>\n</task-notification>",
             origin: ["kind": "task-notification", "producer": "session-task"])
    }

    static func meta(description: String, toolUseID: String?, finished: Bool?) -> String {
        var o: [String: Any] = ["agentType": "general-purpose", "description": description, "spawnDepth": 1, "requestShape": "background"]
        if let toolUseID { o["toolUseId"] = toolUseID }
        if let finished { o["finished"] = finished }
        return json(o)
    }

    // Codex, keys in the order Codex writes them (the parser looks for the type near the start).
    static func codexMeta(_ s: Double, id: String) -> String {
        #"{"timestamp":"\#(ts(s))","ordinal":0,"type":"session_meta","payload":{"session_id":"\#(id)","id":"\#(id)","timestamp":"\#(ts(s))","cwd":"\#(cwd)","originator":"T3 Code","model_provider":"openai"}}"# + "\n"
    }

    static func codexEvent(_ s: Double, _ type: String, _ extra: String = "") -> String {
        #"{"timestamp":"\#(ts(s))","ordinal":1,"type":"event_msg","payload":{"type":"\#(type)"\#(extra)}}"# + "\n"
    }

    static func codexTokens(_ s: Double, input: Int, cached: Int, output: Int) -> String {
        codexEvent(s, "token_count", #","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}"#)
    }

    static func codexUser(_ s: Double, _ text: String, kind: String = "user.text") -> String {
        #"{"timestamp":"\#(ts(s))","ordinal":2,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":\#(quoted(text))}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["\#(kind)"]}}}"# + "\n"
    }
}

/// A transcript home plus a Headroom home, and an observer with a settable clock.
final class ObserverHome: @unchecked Sendable {
    let logs: TempHome
    let home: URL
    final class Clock: @unchecked Sendable { var now = Fx.t0.addingTimeInterval(3600) }
    let clock = Clock()

    init() throws {
        logs = try TempHome()
        home = logs.url.appendingPathComponent("headroom", isDirectory: true)
    }

    func observer() -> TaskObserver {
        let clock = self.clock
        return TaskObserver(roots: logs.roots, home: home, now: { clock.now })
    }

    func claude(_ rel: String) -> String { ".claude/projects/p/" + rel }
    func path(_ rel: String) -> String { logs.path(claude(rel)) }
    func write(_ rel: String, _ lines: [String]) throws { try logs.write(claude(rel), lines.joined()) }
    func append(_ rel: String, _ lines: [String]) throws { try logs.append(claude(rel), lines.joined()) }

    func events(_ run: String) -> [TaskEvent] { TaskJournal.read(run: run, home: home) }
    func runs() -> [String] { TaskJournal.runs(home: home) }
    func fold(_ run: String) -> TaskRun? { TaskFold.fold(events(run), now: clock.now).first }

    /// Every byte written under the Headroom home's task directory.
    func allBytes() -> String {
        let dir = TaskJournal.directory(.observed, home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.map { (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined()
    }
}

extension TaskRun {
    func node(_ id: String) -> TaskNode { nodes.first { $0.id == id }! }
}

extension Array where Element == TaskEvent {
    func ops(_ name: String) -> [TaskEvent] { filter { $0.op.name == name } }
    func attempt(_ key: String) -> TaskEvent.AttemptSpec? {
        lazy.compactMap { if case .attempt(let a) = $0.op, a.key == key { a } else { nil } }.last
    }
    func end(_ key: String) -> TaskAttemptOutcome? {
        lazy.compactMap { if case .attemptEnd(let k, let o) = $0.op, k == key { o } else { nil } }.last
    }
}

@Suite struct TaskObserverTests {
    static let secretPrompt = "Please refactor the payment module SECRET-PROMPT-7731 carefully"

    @Test func sessionWithTwoAgentsOneNested() async throws {
        let h = try ObserverHome()
        try h.write("s1.jsonl", [
            Fx.user(0, "s1", "hello SECRET-TYPED-1"),
            Fx.assistant(1, "s1", id: "m1", tokens: 100, [Fx.agentCall("tu1", "Survey the API", prompt: Self.secretPrompt)]),
            Fx.user(2, "s1", Fx.toolResult("tu1", "Async agent launched"), result: ["status": "async_launched", "agentId": "a1", "resolvedModel": "claude-sonnet-5-5"]),
            Fx.assistant(3, "s1", id: "m2", tokens: 10, stop: "end_turn", [Fx.text("Started.")]),
        ])
        try h.write("s1/subagents/agent-a1.meta.json", [Fx.meta(description: "Survey the API", toolUseID: "tu1", finished: nil)])
        try h.write("s1/subagents/agent-a1.jsonl", [
            Fx.user(2, "s1", Self.secretPrompt, agent: "a1"),
            Fx.assistant(4, "s1", id: "x1", tokens: 300, [Fx.agentCall("tu2", "Read the schema", prompt: "look at /Users/someone/secret/path")], agent: "a1"),
            Fx.user(5, "s1", Fx.toolResult("tu2", "launched"), result: ["status": "async_launched", "agentId": "b1"], agent: "a1"),
        ])
        try h.write("s1/subagents/agent-b1.meta.json", [Fx.meta(description: "Read the schema", toolUseID: "tu2", finished: nil)])
        try h.write("s1/subagents/agent-b1.jsonl", [Fx.assistant(6, "s1", id: "y1", tokens: 40, stop: "end_turn", [Fx.text("done")], agent: "b1")])

        let o = h.observer()
        _ = await o.scan(since: Fx.t0.addingTimeInterval(-86400))
        let ev = h.events("s1")
        #expect(h.runs() == ["s1"])
        #expect(ev.ops("run.meta").count == 1)
        if case .meta(_, let project, let harness, _, _) = ev.ops("run.meta")[0].op { #expect(project == "demo" && harness == "claude-code") }
        #expect(ev.attempt("session:s1")?.kind == .session)
        let a = try #require(ev.attempt("agent:a1"))
        #expect(a.parentKey == "session:s1" && a.title == "Survey the API" && a.model == "claude-sonnet-5-5" && a.provider == "claude")
        #expect(ev.attempt("agent:b1")?.parentKey == "agent:a1")
        // b1's transcript ended its turn: it's done. a1 is still going, and the orchestrator stopped.
        #expect(ev.end("agent:b1") == .ok && ev.end("agent:a1") == nil)
        #expect(ev.ops("run.stop").count == 1)

        let run = try #require(h.fold("s1"))
        #expect(run.nodes.map(\.id) == ["~agent-a1", "~agent-b1"])
        #expect(run.node("~agent-b1").parent == "~agent-a1")
        #expect(run.state == .running && !run.hasDeclaredTasks)

        // The orchestrator replies again: resumed.
        try h.append("s1.jsonl", [Fx.assistant(60, "s1", id: "m3", tokens: 5, [Fx.text("Checking")])])
        _ = await o.ingest(paths: [h.path("s1.jsonl")])
        #expect(h.events("s1").ops("run.resume").count == 1)
    }

    @Test func metaFinishedFlippingEndsTheAgent() async throws {
        let h = try ObserverHome()
        try h.write("s2.jsonl", [Fx.assistant(1, "s2", id: "m1", [Fx.agentCall("tu1", "Long job", prompt: "p")]),
                                 Fx.user(2, "s2", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"])])
        try h.write("s2/subagents/agent-a1.meta.json", [Fx.meta(description: "Long job", toolUseID: "tu1", finished: nil)])
        try h.write("s2/subagents/agent-a1.jsonl", [Fx.assistant(5, "s2", id: "x1", tokens: 10, [Fx.text("working")], agent: "a1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        #expect(h.events("s2").end("agent:a1") == nil)
        #expect(await o.needsPolling)
        try h.write("s2/subagents/agent-a1.meta.json", [Fx.meta(description: "Long job", toolUseID: "tu1", finished: true)])
        _ = await o.poll()
        let ev = h.events("s2")
        #expect(ev.end("agent:a1") == .ok)
        // It ended when its transcript last moved.
        #expect(ev.ops("attempt.end").last?.at == Fx.t0.addingTimeInterval(5))
        #expect(await !o.needsPolling)
    }

    @Test func anErrorResultFailsTheAgent() async throws {
        let h = try ObserverHome()
        try h.write("s3.jsonl", [
            Fx.assistant(1, "s3", id: "m1", [Fx.agentCall("tu1", "Foreground job", prompt: "p"), Fx.agentCall("tu2", "Background job", prompt: "q")]),
            Fx.user(2, "s3", Fx.toolResult("tu2", "launched"), result: ["status": "async_launched", "agentId": "a2"]),
            Fx.user(9, "s3", Fx.toolResult("tu1", "it broke", error: true), result: ["status": "completed", "agentId": "a1"]),
            Fx.notification(12, "s3", toolUseID: "tu2", status: "killed"),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        let ev = h.events("s3")
        #expect(ev.end("agent:a1") == .error && ev.end("agent:a2") == .error)
        let run = try #require(h.fold("s3"))
        #expect(run.state == .failed || run.state == .partial)
    }

    @Test func tokensAreCountedOncePerMessage() async throws {
        let h = try ObserverHome()
        // One message written as three lines (thinking, text, tool use), each repeating the usage.
        let call = Fx.agentCall("tu1", "Job", prompt: "p")
        try h.write("s4.jsonl", [Fx.assistant(1, "s4", id: "m1", tokens: 100, [["type": "thinking", "thinking": ""]]),
                                 Fx.assistant(1.1, "s4", id: "m1", tokens: 100, [Fx.text("ok")]),
                                 Fx.assistant(1.2, "s4", id: "m1", tokens: 100, [call]),
                                 Fx.user(2, "s4", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"]),
                                 Fx.assistant(3, "s4", id: "m2", tokens: 7, [Fx.text("next")])])
        _ = await h.observer().scan(since: Fx.t0)
        let tokens = h.events("s4").compactMap { if case .activity("session:s4", _, let t?) = $0.op { t } else { nil } }.last
        // input + output of each message; cache reads don't count.
        #expect(tokens == 214, "\(String(describing: tokens))")
    }

    @Test func aTaggedAgentLandsInTheTagsRunAndTask() async throws {
        let h = try ObserverHome()
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "plan9", source: .agent, op: .add(.init(id: "api/tests", title: "API tests")))], stream: .journal, home: h.home)
        try h.write("s5.jsonl", [Fx.assistant(1, "s5", id: "m1", [Fx.agentCall("tu1", "Write tests [hr:plan9:api/tests]", prompt: "go")]),
                                 Fx.user(2, "s5", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"])])
        try h.write("s5/subagents/agent-a1.jsonl", [Fx.assistant(3, "s5", id: "x1", tokens: 5, [Fx.text("…")], agent: "a1")])
        _ = await h.observer().scan(since: Fx.t0)
        let a = try #require(h.events("plan9").attempt("agent:a1"))
        #expect(a.tag == "plan9:api/tests" && a.title == "Write tests")
        #expect(h.events("s5").attempt("agent:a1") == nil)
        let run = try #require(h.fold("plan9"))
        #expect(run.node("api/tests").attempts.count == 1 && run.node("api/tests").state == .running)
        // The spawning session put nothing in its own run, so it isn't one.
        #expect(!h.runs().contains("s5"))
    }

    static let brief = "Implement the retry queue for the sync engine. Keep the public API unchanged, add tests for backoff, and report the files you touched."

    @Test func aDelegateBindsToItsCodexChild() async throws {
        let h = try ObserverHome()
        try h.write("s6.jsonl", [
            Fx.assistant(1, "s6", id: "m1", [Fx.delegateCall("tu1", title: "Retry queue", task: Self.brief)]),
            Fx.user(2, "s6", Fx.toolResult("tu1", [["type": "text", "text": #"{"taskId":"node:dt:abc","childThreadId":"thread:x","status":"running"}"#]])),
        ])
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-c1.jsonl"
        try h.logs.write(rollout, [Fx.codexMeta(3, id: "c1-child"), Fx.codexEvent(3.1, "task_started"),
                                   Fx.codexUser(3.2, "<environment_context>…</environment_context>", kind: "environments.environment_context"),
                                   Fx.codexUser(3.3, "Act as the implementation sub-agent for this task.\n\n" + Self.brief.replacingOccurrences(of: " ", with: "  ")),
                                   Fx.codexTokens(20, input: 5000, cached: 4000, output: 300)].joined())
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var ev = h.events("s6")
        let d = try #require(ev.attempt("delegate:tu1"))
        #expect(d.kind == .delegate && d.title == "Retry queue" && d.model == "gpt-6.1" && d.provider == "codex" && d.agentType == "implementation")
        #expect(await o.boundChildren == ["c1-child"])
        #expect(!h.runs().contains("c1-child"))
        let tokens = ev.compactMap { if case .activity("delegate:tu1", _, let t?) = $0.op { t } else { nil } }.last
        #expect(tokens == 1300)
        #expect(ev.end("delegate:tu1") == nil)

        try h.logs.append(rollout, Fx.codexEvent(40, "task_complete"))
        _ = await o.ingest(paths: [h.logs.path(rollout)])
        ev = h.events("s6")
        #expect(ev.end("delegate:tu1") == .ok)
        #expect(await o.summary().delegatesBound == 1)
    }

    @Test func aDelegateBindsToItsClaudeChildWhoseAgentNestsUnderIt() async throws {
        let h = try ObserverHome()
        try h.write("s7.jsonl", [
            Fx.assistant(1, "s7", id: "m1", [Fx.delegateCall("tu1", title: "Retry queue", task: Self.brief, provider: "claudeAgent")]),
            Fx.user(2, "s7", Fx.toolResult("tu1", [["type": "text", "text": #"{"taskId":"node:dt:def","status":"running"}"#]])),
        ])
        try h.write("k1.jsonl", [
            Fx.user(3, "k1", [Fx.text("Act as the implementation sub-agent for this task.\n\n" + Self.brief)]),
            Fx.assistant(4, "k1", id: "c1", tokens: 50, [Fx.agentCall("tu9", "Check the tests", prompt: "p")]),
            Fx.user(5, "k1", Fx.toolResult("tu9", "launched"), result: ["status": "async_launched", "agentId": "z1"]),
        ])
        try h.write("k1/subagents/agent-z1.jsonl", [Fx.assistant(6, "k1", id: "z", tokens: 5, [Fx.text("…")], agent: "z1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        let ev = h.events("s7")
        #expect(ev.attempt("delegate:tu1")?.provider == "claude")
        #expect(ev.attempt("agent:z1")?.parentKey == "delegate:tu1")
        let bound = await o.boundChildren
        #expect(!h.runs().contains("k1") && bound == ["k1"])
        let run = try #require(h.fold("s7"))
        #expect(run.node("~agent-z1").parent == "~delegate-tu1")

        // T3 Code tells the parent it finished; the child's own turn end agrees.
        try h.append("k1.jsonl", [Fx.assistant(30, "k1", id: "c2", stop: "end_turn", [Fx.text("Done")])])
        try h.append("s7.jsonl", [Fx.user(31, "s7", "Delegated task node:dt:def (Retry queue) [completed]:\nUNIT: …")])
        _ = await o.ingest(paths: [h.path("k1.jsonl"), h.path("s7.jsonl")])
        #expect(h.events("s7").end("delegate:tu1") == .ok)
    }

    @Test func aTagForARunNobodyDeclaredIsIgnored() async throws {
        let h = try ObserverHome()
        // A brief that only explains the tag syntax must not invent a run called RUN.
        try h.write("s5b.jsonl", [Fx.assistant(1, "s5b", id: "m1", [Fx.agentCall("tu1", "Explain tags", prompt: "put [hr:RUN:PATH] in the description")]),
                                  Fx.user(2, "s5b", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"])])
        try h.write("s5b/subagents/agent-a1.jsonl", [Fx.assistant(3, "s5b", id: "x1", tokens: 5, [Fx.text("…")], agent: "a1")])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(!h.runs().contains("RUN"))
        let a = try #require(h.events("s5b").attempt("agent:a1"))
        #expect(a.tag == nil && a.title == "Explain tags")
    }

    @Test func anAgentWhoseRunChangesIsClosedInTheRunItLeaves() async throws {
        let h = try ObserverHome()
        try h.write("s5c.jsonl", [Fx.assistant(1, "s5c", id: "m1", [Fx.agentCall("tu1", "Write tests [hr:late1:api/tests]", prompt: "go")]),
                                  Fx.user(2, "s5c", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"])])
        try h.write("s5c/subagents/agent-a1.jsonl", [Fx.assistant(3, "s5c", id: "x1", tokens: 5, [Fx.text("…")], agent: "a1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        // Nobody has declared late1 yet: the agent sits in its session's run.
        #expect(h.fold("s5c")?.nodes.contains { $0.attempts.active == 1 } == true)
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "late1", source: .agent, op: .add(.init(id: "api/tests", title: "API tests")))], stream: .journal, home: h.home)
        try h.append("s5c/subagents/agent-a1.jsonl", [Fx.assistant(40, "s5c", id: "x2", tokens: 5, [Fx.text("…")], agent: "a1")])
        _ = await o.ingest(paths: [h.path("s5c/subagents/agent-a1.jsonl")])
        #expect(h.fold("late1")?.node("api/tests").state == .running)
        // No ghost left running behind it.
        #expect(h.fold("s5c")?.nodes.contains { $0.attempts.active > 0 } == false)
    }

    @Test func aWaitedDelegateEndsFromItsOwnResult() async throws {
        let h = try ObserverHome()
        // mode "wait": the outcome comes back in the call's result, and no message to the parent follows.
        try h.write("s8b.jsonl", [
            Fx.assistant(1, "s8b", id: "m1", [Fx.delegateCall("tu1", title: "Audit", task: "Audit the change with care please, all of it", provider: "zcode_acp"),
                                               Fx.delegateCall("tu2", title: "Build", task: "Build the other half of it with care, all of it", provider: "zcode_acp")]),
            Fx.user(2, "s8b", Fx.toolResult("tu1", [["type": "text", "text": #"{"taskId":"node:dt:w1","status":"completed","workState":"result_available"}"#]])),
            Fx.user(3, "s8b", Fx.toolResult("tu2", [["type": "text", "text": #"{"taskId":"node:dt:w2","status":"interrupted"}"#]])),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.events("s8b").end("delegate:tu1") == .ok)
        #expect(h.events("s8b").end("delegate:tu2") == .error)
    }

    @Test func anUnboundDelegateEndsFromTheParentAndAsksQuestions() async throws {
        let h = try ObserverHome()
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "s8", source: .agent, op: .add(.init(id: "audit", title: "Audit")))], stream: .journal, home: h.home)
        try h.write("s8.jsonl", [
            Fx.assistant(1, "s8", id: "m1", [Fx.delegateCall("tu1", title: "Audit [hr:s8:audit]", task: "Audit the GLM side of things with care please, all of it", provider: "zcode_acp")]),
            Fx.user(2, "s8", Fx.toolResult("tu1", [["type": "text", "text": #"{"taskId":"node:dt:ghi","status":"running"}"#]])),
            Fx.user(10, "s8", "Delegated task node:dt:ghi asked a question and is still working. Read it with t3_pending_request action read"),
        ])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var ev = h.events("s8")
        let d = try #require(ev.attempt("delegate:tu1"))
        #expect(d.provider == nil && d.tag == "s8:audit" && d.title == "Audit")
        #expect(ev.ops("task.wait").count == 1)
        #expect(h.fold("s8")?.node("audit").state == .waiting)
        try h.append("s8.jsonl", [Fx.user(50, "s8", "Delegated task node:dt:ghi (Audit) [failed]:\nIt could not finish.")])
        _ = await o.ingest(paths: [h.path("s8.jsonl")])
        ev = h.events("s8")
        #expect(ev.end("delegate:tu1") == .error)
        #expect(await o.summary().delegatesBound == 0)
    }

    @Test func aWorkflowAndItsAgents() async throws {
        let h = try ObserverHome()
        try h.write("s9.jsonl", [
            Fx.assistant(1, "s9", id: "m1", [["type": "tool_use", "id": "tw", "name": "Workflow", "input": ["script": "export const meta = {}"]]]),
            Fx.user(2, "s9", Fx.toolResult("tw", "launched"), result: ["status": "async_launched", "runId": "wf_1", "workflowName": "verify", "taskId": "t1",
                                                                       "transcriptDir": "/somewhere"]),
        ])
        for (id, done) in [("w1", true), ("w2", false)] {
            try h.write("s9/subagents/workflows/wf_1/agent-\(id).meta.json", [Fx.json(["agentType": "workflow-subagent", "description": "check-\(id)", "workflowPhase": "Check"])])
            var lines = [Fx.assistant(3, "s9", id: "w-" + id, tokens: 20, [Fx.text("…")], agent: id)]
            if done { lines.append(Fx.assistant(8, "s9", id: "w2-" + id, [["type": "tool_use", "id": "so", "name": "StructuredOutput", "input": [:]]], agent: id)) }
            try h.write("s9/subagents/workflows/wf_1/agent-\(id).jsonl", lines)
        }
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var ev = h.events("s9")
        #expect(ev.attempt("workflow:wf_1")?.title == "verify" && ev.attempt("workflow:wf_1")?.kind == .workflow)
        #expect(ev.attempt("agent:w1")?.parentKey == "workflow:wf_1" && ev.attempt("agent:w1")?.title == "check-w1")
        #expect(ev.end("agent:w1") == .ok && ev.end("agent:w2") == nil)
        #expect(await o.needsPolling)
        // The workflow's result file appears when it ends; its unfinished agents end with it.
        try h.write("s9/workflows/wf_1.json", [Fx.json(["runId": "wf_1", "status": "killed"])])
        _ = await o.poll()
        ev = h.events("s9")
        #expect(ev.end("workflow:wf_1") == .error && ev.end("agent:w2") == .error)
        let run = try #require(h.fold("s9"))
        #expect(run.node("~agent-w1").parent == "~workflow-wf_1")
    }

    @Test func aPlainChatProducesNothing() async throws {
        let h = try ObserverHome()
        try h.write("s10.jsonl", [Fx.user(0, "s10", "what's 2+2"), Fx.assistant(1, "s10", id: "m1", tokens: 10, stop: "end_turn", [Fx.text("4")])])
        try h.logs.write(".codex/sessions/2026/10/10/rollout-x.jsonl", [Fx.codexMeta(0, id: "cx1"), Fx.codexEvent(1, "task_started"),
                                                                      Fx.codexUser(1.1, "hi"), Fx.codexEvent(2, "task_complete")].joined())
        let report = await h.observer().scan(since: Fx.t0)
        #expect(report.events == 0 && report.filesRead == 2)
        #expect(h.runs().isEmpty)
    }

    @Test func aSessionWithAJournalButNoSpawnsIsObserved() async throws {
        let h = try ObserverHome()
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "s11", source: .agent, op: .add(.init(id: "build")))], stream: .journal, home: h.home)
        try h.write("s11.jsonl", [Fx.user(0, "s11", "go"), Fx.assistant(1, "s11", id: "m1", tokens: 10, stop: "end_turn", [Fx.text("ok")])])
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "cx2", source: .agent, op: .add(.init(id: "fix")))], stream: .journal, home: h.home)
        try h.logs.write(".codex/sessions/2026/10/10/rollout-y.jsonl", [Fx.codexMeta(0, id: "cx2"), Fx.codexEvent(1, "task_started"),
                                                                      Fx.codexTokens(2, input: 100, cached: 0, output: 10), Fx.codexEvent(3, "task_complete")].joined())
        _ = await h.observer().scan(since: Fx.t0)
        let ev = h.events("s11")
        #expect(ev.attempt("session:s11") != nil && ev.ops("run.meta").count == 1 && ev.ops("run.stop").count == 1)
        let cx = h.events("cx2")
        #expect(cx.attempt("session:cx2")?.provider == "codex" && cx.ops("run.stop").count == 1)
        if case .meta(_, _, let harness, _, _) = cx.ops("run.meta").first?.op { #expect(harness == "codex") }
    }

    @Test func cursorsSurviveARestartWithoutRewriting() async throws {
        let h = try ObserverHome()
        try h.write("s12.jsonl", [Fx.assistant(1, "s12", id: "m1", [Fx.agentCall("tu1", "Job", prompt: "p")]),
                                  Fx.user(2, "s12", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"])])
        let first = await h.observer().scan(since: Fx.t0)
        #expect(first.events > 0)
        let before = h.events("s12").count
        // A new observer reads the saved state: the same files give nothing new.
        let again = h.observer()
        #expect(await !again.isFresh)
        let second = await again.ingest(paths: [h.path("s12.jsonl")])
        #expect(second.events == 0 && second.bytes == 0 && h.events("s12").count == before)
        try h.append("s12.jsonl", [Fx.notification(9, "s12", toolUseID: "tu1", status: "completed")])
        h.clock.now = h.clock.now.addingTimeInterval(60)
        _ = await again.ingest(paths: [h.path("s12.jsonl")])
        let ev = h.events("s12")
        #expect(ev.end("agent:a1") == .ok && ev.ops("attempt.upsert").filter { $0.op == ev.ops("attempt.upsert")[0].op }.count == 1)
    }

    @Test func activityIsThrottled() async throws {
        let h = try ObserverHome()
        try h.write("s13.jsonl", [Fx.assistant(1, "s13", id: "m1", [Fx.agentCall("tu1", "Job", prompt: "p")]),
                                  Fx.user(2, "s13", Fx.toolResult("tu1", "launched"), result: ["status": "async_launched", "agentId": "a1"])])
        try h.write("s13/subagents/agent-a1.jsonl", [Fx.assistant(3, "s13", id: "x1", tokens: 10, [Fx.text("…")], agent: "a1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        func activities() -> Int { h.events("s13").filter { if case .activity("agent:a1", _, _) = $0.op { true } else { false } }.count }
        #expect(activities() == 1)
        for (i, wall) in [5.0, 12, 20].enumerated() {
            h.clock.now = h.clock.now.addingTimeInterval(wall - (i == 0 ? 0 : [5.0, 12, 20][i - 1]))
            try h.append("s13/subagents/agent-a1.jsonl", [Fx.assistant(10 + Double(i), "s13", id: "x\(i + 2)", tokens: 10, [Fx.text("…")], agent: "a1")])
            _ = await o.ingest(paths: [h.path("s13/subagents/agent-a1.jsonl")])
        }
        #expect(activities() == 1)
        #expect(await o.needsPolling)
        h.clock.now = h.clock.now.addingTimeInterval(15)
        _ = await o.poll()
        #expect(activities() == 2)
        // The end always carries the last activity with it.
        try h.append("s13/subagents/agent-a1.jsonl", [Fx.assistant(30, "s13", id: "x9", tokens: 10, stop: "end_turn", [Fx.text("done")], agent: "a1")])
        h.clock.now = h.clock.now.addingTimeInterval(1)
        _ = await o.ingest(paths: [h.path("s13/subagents/agent-a1.jsonl")])
        #expect(activities() == 3 && h.events("s13").end("agent:a1") == .ok)
    }

    @Test func nothingTypedAndNoPathIsWritten() async throws {
        let h = try ObserverHome()
        try h.write("s14.jsonl", [
            Fx.user(0, "s14", "my typed words SECRET-TYPED-2"),
            Fx.assistant(1, "s14", id: "m1", [Fx.agentCall("tu1", "Survey", prompt: Self.secretPrompt),
                                              Fx.delegateCall("tu2", title: "Retry queue", task: Self.brief + " SECRET-TASK-3")]),
            Fx.user(2, "s14", Fx.toolResult("tu1", "output SECRET-OUTPUT-4"), result: ["status": "async_launched", "agentId": "a1", "prompt": Self.secretPrompt]),
            Fx.user(3, "s14", Fx.toolResult("tu2", [["type": "text", "text": #"{"taskId":"node:dt:p","status":"running","summary":"SECRET-OUTPUT-5"}"#]])),
        ])
        try h.write("s14/subagents/agent-a1.jsonl", [Fx.user(2, "s14", Self.secretPrompt, agent: "a1"),
                                                    Fx.assistant(3, "s14", id: "x", tokens: 5, [["type": "tool_use", "id": "b", "name": "Bash", "input": ["command": "cat /etc/SECRET-INPUT-6"]]], agent: "a1")])
        _ = await h.observer().scan(since: Fx.t0)
        let bytes = h.allBytes()
        #expect(!bytes.isEmpty)
        // The working folder goes on `run.meta` only (it stays on this Mac); nothing else carries a path.
        let metas = h.events("s14").ops("run.meta")
        #expect(!metas.isEmpty && metas.allSatisfy { if case .meta(_, _, _, _, let cwd) = $0.op { cwd == Fx.cwd } else { false } })
        let rest = bytes.replacingOccurrences(of: #""cwd":"\#(Fx.cwd)""#, with: "")
        for secret in ["SECRET", "/Users", "someone", "code/demo", "payment", "retry queue for the sync", h.logs.url.path, "codex_someone"] {
            #expect(!rest.contains(secret), "wrote \(secret)")
        }
        // The observer's own state keeps no prompt either: briefs are hashes.
        let state = try String(decoding: Data(contentsOf: TaskObserver.stateURL(home: h.home)), as: UTF8.self)
        #expect(!state.contains("SECRET") && !state.contains("payment"))
    }

    @Test func fingerprintsMatchAcrossTheT3Preamble() {
        let brief = try! #require(Fingerprint.brief(Self.brief))
        #expect(Fingerprint.candidates("Act as the review sub-agent for this task.\n\n" + Self.brief).contains(brief))
        #expect(Fingerprint.candidates(Self.brief).contains(brief))
        #expect(!Fingerprint.candidates("Something else entirely, not the brief at all, really not.").contains(brief))
        #expect(Fingerprint.brief("too short") == nil)
    }
}
