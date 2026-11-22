import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

/// Synthetic lines for the harness's question, plan and limit tools, in the shapes Claude Code
/// 2.1, the Claude desktop app and Codex write.
extension Fx {
    static func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func ask(_ id: String, _ questions: [(String, [String])]) -> [String: Any] {
        toolUse(id, "AskUserQuestion", ["questions": questions.map { q, options in
            ["question": q, "header": "Pick", "multiSelect": false, "options": options.map { ["label": $0, "description": "about " + $0] }] as [String: Any]
        }])
    }

    static func todos(_ id: String, _ items: [(String, String)]) -> [String: Any] {
        toolUse(id, "TodoWrite", ["todos": items.map { ["content": $0.0, "status": $0.1, "activeForm": "Doing " + $0.0] }])
    }

    /// A background agent: launched, so the session is a run.
    static func launch(_ s: Double, _ session: String, _ tu: String, _ agent: String) -> [String] {
        [assistant(s, session, id: "launch-" + tu, [agentCall(tu, "Helper", prompt: "p")]),
         user(s + 0.5, session, toolResult(tu, "launched"), result: ["status": "async_launched", "agentId": agent])]
    }

    static func codexCall(_ s: Double, _ name: String, callID: String, _ arguments: [String: Any]) -> String {
        let args = String(decoding: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
        return #"{"timestamp":"\#(ts(s))","ordinal":5,"type":"response_item","payload":{"type":"function_call","name":"\#(name)","arguments":\#(quoted(args)),"call_id":"\#(callID)"}}"# + "\n"
    }

    static func codexOutput(_ s: Double, callID: String, _ output: String) -> String {
        #"{"timestamp":"\#(ts(s))","ordinal":6,"type":"response_item","payload":{"type":"function_call_output","call_id":"\#(callID)","output":\#(quoted(output))}}"# + "\n"
    }
}

extension Array where Element == TaskEvent {
    var waits: [(task: String?, attempt: String?, reason: TaskWaitReason, note: String?, options: [String]?, at: Date)] {
        compactMap { if case .wait(let t, let a, let r, let n, let o) = $0.op { (t, a, r, n, o, $0.at) } else { nil } }
    }

    var mirrors: [(items: [TaskPlanItem], tool: String?)] {
        compactMap { if case .planMirror(let items, let tool) = $0.op { (items, tool) } else { nil } }
    }

    var metas: [(project: String?, harness: String?, host: String?, cwd: String?)] {
        compactMap { if case .meta(_, let p, let h, let host, let cwd, _, _, _) = $0.op { (p, h, host, cwd) } else { nil } }
    }
}

@Suite struct TaskObserverHarnessTests {
    // MARK: Questions

    @Test func aPendingQuestionWaitsUntilAnswered() async throws {
        let h = try ObserverHome()
        let long = String(repeating: "Which storage engine should the cache use for the long run? ", count: 10)
        let options = ["SQLite", "Plain files", String(repeating: "A very long option label ", count: 5), "D", "E", "F", "G", "H"]
        try h.write("q1.jsonl", Fx.launch(1, "q1", "tu0", "a0") + [
            Fx.assistant(5, "q1", id: "m2", [Fx.ask("tq", [(long, options), ("Second?", ["Yes", "No"])])]),
        ])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var w = h.events("q1").waits
        #expect(w.count == 1)
        let q = try #require(w.first)
        #expect(q.task == nil && q.attempt == nil && q.reason == .input && q.at == Fx.t0.addingTimeInterval(5))
        #expect((q.note?.count ?? 0) <= TaskQuestion.maxLength && q.note?.hasSuffix("(+1 more)") == true && q.note?.hasPrefix("Which storage engine") == true)
        #expect(q.options?.count == 6 && q.options?.first == "SQLite" && q.options!.allSatisfy { $0.count <= 60 })
        #expect(h.events("q1").ops("run.resume").isEmpty)

        // A restart reads the saved state: the question isn't written again.
        let again = h.observer()
        try h.append("q1.jsonl", [Fx.user(6, "q1", [["type": "text", "text": "unrelated"]])])
        _ = await again.ingest(paths: [h.path("q1.jsonl")])
        #expect(h.events("q1").waits.count == 1)

        // The answer comes back as the call's result: the run resumes.
        try h.append("q1.jsonl", [Fx.user(40, "q1", Fx.toolResult("tq", "User answered: SQLite"), result: ["answers": ["x": "SQLite"]])])
        _ = await again.ingest(paths: [h.path("q1.jsonl")])
        let ev = h.events("q1")
        #expect(ev.ops("run.resume").map(\.at) == [Fx.t0.addingTimeInterval(40)])
        w = ev.waits
        #expect(w.count == 1)
        _ = await again.ingest(paths: [h.path("q1.jsonl")])
        #expect(h.events("q1").ops("run.resume").count == 1)
    }

    @Test func aPlanWaitingForApprovalAsks() async throws {
        let h = try ObserverHome()
        try h.write("q2.jsonl", Fx.launch(1, "q2", "tu0", "a0") + [
            Fx.assistant(5, "q2", id: "m2", [Fx.toolUse("tp", "ExitPlanMode", ["plan": "\n# Ship the settings pane\n\n1. Build it\n2. Test it", "planFilePath": "/x/plan.md"])]),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        let q = try #require(h.events("q2").waits.first)
        #expect(q.note == "Approve the plan? Ship the settings pane" && q.options == ["Approve", "Keep planning"])
        // The plan's file path is never written.
        #expect(!h.allBytes().contains("plan.md"))
    }

    @Test func aQuestionAnsweredBeforeItWasSeenIsNotWritten() async throws {
        let h = try ObserverHome()
        try h.write("q3.jsonl", Fx.launch(1, "q3", "tu0", "a0") + [
            Fx.assistant(5, "q3", id: "m2", [Fx.ask("tq", [("Go ahead?", ["Yes", "No"])])]),
            Fx.user(9, "q3", Fx.toolResult("tq", "User answered: Yes")),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.events("q3").waits.isEmpty && h.events("q3").ops("run.resume").isEmpty)
    }

    @Test func aSubagentsQuestionWaitsOnItsAttempt() async throws {
        let h = try ObserverHome()
        try h.write("q4.jsonl", Fx.launch(1, "q4", "tu1", "a1"))
        try h.write("q4/subagents/agent-a1.jsonl", [Fx.assistant(3, "q4", id: "x1", [Fx.ask("tq", [("Which port?", ["8080", "9090"])])], agent: "a1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        let q = try #require(h.events("q4").waits.first)
        #expect(q.attempt == "agent:a1" && q.task == nil && q.note == "Which port?" && q.options == ["8080", "9090"])
        try h.append("q4/subagents/agent-a1.jsonl", [Fx.user(30, "q4", Fx.toolResult("tq", "8080"), agent: "a1")])
        _ = await o.ingest(paths: [h.path("q4/subagents/agent-a1.jsonl")])
        let ev = h.events("q4")
        let last = ev.last { if case .activity("agent:a1", _, _) = $0.op { true } else { false } }
        #expect(last?.at == Fx.t0.addingTimeInterval(30))
        #expect(ev.ops("run.resume").isEmpty && ev.waits.count == 1)
    }

    @Test func aCodexQuestionAndPlan() async throws {
        let h = try ObserverHome()
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-cq.jsonl"
        try h.logs.write(rollout, [
            Fx.codexMeta(0, id: "cq1"), Fx.codexEvent(1, "task_started"), Fx.codexUser(1.1, "Plan the work"),
            Fx.codexCall(2, "update_plan", callID: "call_p", ["explanation": "Steps", "plan": [["step": "Read the code", "status": "completed"],
                                                                                               ["step": "Change it", "status": "in_progress"],
                                                                                               ["step": "Test it", "status": "pending"]]]),
            Fx.codexOutput(2.1, callID: "call_p", "Plan updated"),
            Fx.codexCall(3, "request_user_input", callID: "call_q", ["questions": [["id": "q", "header": "Mode", "question": "Fast or careful?",
                                                                                    "options": [["label": "Fast", "description": "d"], ["label": "Careful", "description": "d"]]]]]),
        ].joined())
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var ev = h.events("cq1")
        let plan = try #require(ev.mirrors.last)
        #expect(plan.tool == "codex-plan" && plan.items.map(\.title) == ["Read the code", "Change it", "Test it"])
        #expect(plan.items.map(\.status) == [.completed, .inProgress, .pending])
        #expect(ev.metas.first?.cwd == Fx.cwd && ev.metas.first?.harness == "codex")
        let q = try #require(ev.waits.first)
        #expect(q.note == "Fast or careful?" && q.options == ["Fast", "Careful"] && q.attempt == nil)

        try h.logs.append(rollout, [Fx.codexOutput(50, callID: "call_q", #"{"answers":{"q":"Fast"}}"#),
                                    Fx.codexCall(51, "update_plan", callID: "call_p2", ["plan": [["step": "Read the code", "status": "completed"],
                                                                                                   ["step": "Change it", "status": "completed"],
                                                                                                   ["step": "Test it", "status": "in_progress"]]])].joined())
        _ = await o.ingest(paths: [h.logs.path(rollout)])
        ev = h.events("cq1")
        #expect(ev.ops("run.resume").map(\.at) == [Fx.t0.addingTimeInterval(50)])
        #expect(ev.mirrors.count == 2 && ev.mirrors.last?.items.map(\.status) == [.completed, .completed, .inProgress])
        // Ids follow the item, not the update.
        #expect(ev.mirrors[0].items.map(\.id) == ev.mirrors[1].items.map(\.id))
    }

    @Test func aCodexAsyncQuestionIsAnsweredByTheNextMessage() async throws {
        let h = try ObserverHome()
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-ca.jsonl"
        try h.logs.write(rollout, [
            Fx.codexMeta(0, id: "ca1"), Fx.codexEvent(1, "task_started"), Fx.codexUser(1.1, "Do it"),
            Fx.codexCall(2, "update_plan", callID: "p", ["plan": [["step": "One", "status": "in_progress"], ["step": "Two", "status": "pending"]]]),
            Fx.codexCall(3, "request_user_input_async", callID: "qa", ["questions": [["title": "Keep the old API?", "options": ["Keep", "Drop"]]]]),
            Fx.codexOutput(3.2, callID: "qa", #"{"status":"sent"}"#),
            Fx.codexEvent(4, "task_complete"),
        ].joined())
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        #expect(h.events("ca1").waits.first?.note == "Keep the old API?" && h.events("ca1").waits.first?.options == ["Keep", "Drop"])
        try h.logs.append(rollout, [Fx.codexEvent(60, "task_started"), Fx.codexUser(60.1, "Keep")].joined())
        _ = await o.ingest(paths: [h.logs.path(rollout)])
        #expect(h.events("ca1").ops("run.resume").contains { $0.at == Fx.t0.addingTimeInterval(60) })
    }

    // MARK: Plans

    @Test func aTodoListIsMirroredAndMakesARun() async throws {
        let h = try ObserverHome()
        try h.write("p1.jsonl", [
            Fx.user(0, "p1", "build it"),
            Fx.assistant(1, "p1", id: "m1", [Fx.todos("t1", [("Read the code", "completed"), ("Write the parser", "in_progress"), ("Add tests", "pending")])]),
            Fx.user(1.5, "p1", Fx.toolResult("t1", "Todos have been modified successfully")),
            Fx.assistant(2, "p1", id: "m2", [Fx.todos("t2", [("Read the code", "completed"), ("Write the parser", "in_progress"), ("Add tests", "pending")])]),
        ])
        // One item is no plan.
        try h.write("p0.jsonl", [Fx.assistant(1, "p0", id: "m1", [Fx.todos("t1", [("Only this", "pending")])])])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        #expect(h.runs() == ["p1"])
        var ev = h.events("p1")
        #expect(ev.mirrors.count == 1 && ev.ops("plan.mirror").first?.at == Fx.t0.addingTimeInterval(1))
        let first = try #require(ev.mirrors.first)
        #expect(first.tool == "todo" && first.items.map(\.status) == [.completed, .inProgress, .pending])
        #expect(Set(first.items.map(\.id)).count == 3 && first.items.allSatisfy { TaskPath.isValid($0.id) })
        #expect(ev.attempt("session:p1") != nil && ev.metas.count == 1)

        try h.append("p1.jsonl", [Fx.assistant(30, "p1", id: "m3", [Fx.todos("t3", [("Read the code", "completed"), ("Write the parser", "completed"),
                                                                                        ("Add tests", "in_progress")])])])
        _ = await o.ingest(paths: [h.path("p1.jsonl")])
        ev = h.events("p1")
        #expect(ev.mirrors.count == 2 && ev.mirrors[1].items.map(\.status) == [.completed, .completed, .inProgress])
        #expect(ev.mirrors[1].items.map(\.id) == first.items.map(\.id))
    }

    @Test func tasksAreMirroredWithTheirOwnIds() async throws {
        let h = try ObserverHome()
        var lines: [String] = []
        for (i, title) in ["Survey", "Build", "Ship"].enumerated() {
            let s = Double(i * 2 + 1)
            lines.append(Fx.assistant(s, "p2", id: "c\(i)", [Fx.toolUse("tc\(i)", "TaskCreate", ["subject": title, "description": "d", "activeForm": "Doing"])]))
            lines.append(Fx.user(s + 0.5, "p2", Fx.toolResult("tc\(i)", "Task #\(i + 1) created successfully"), result: ["task": ["id": "\(i + 1)", "subject": title]]))
        }
        lines.append(Fx.assistant(8, "p2", id: "u1", [Fx.toolUse("tu1", "TaskUpdate", ["taskId": "1", "status": "in_progress"])]))
        lines.append(Fx.assistant(9, "p2", id: "u2", [Fx.toolUse("tu2", "TaskUpdate", ["taskId": "3", "status": "deleted"])]))
        try h.write("p2.jsonl", lines)
        _ = await h.observer().scan(since: Fx.t0)
        let plan = try #require(h.events("p2").mirrors.last)
        #expect(plan.tool == "tasks" && plan.items.map(\.id) == ["1", "2"] && plan.items.map(\.title) == ["Survey", "Build"])
        #expect(plan.items.map(\.status) == [.inProgress, .pending])
    }

    @Test func aSubagentsPlanIsIgnored() async throws {
        let h = try ObserverHome()
        try h.write("p3.jsonl", Fx.launch(1, "p3", "tu1", "a1"))
        try h.write("p3/subagents/agent-a1.jsonl", [Fx.assistant(3, "p3", id: "x1", [Fx.todos("t1", [("A", "pending"), ("B", "pending")])], agent: "a1")])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.events("p3").mirrors.isEmpty && h.events("p3").attempt("agent:a1") != nil)
    }

    @Test func theDesktopPlanToolStepsAndTheAppIsTheHost() async throws {
        let h = try ObserverHome()
        let desk: [String: Any] = ["entrypoint": "claude-desktop"]
        func plan(_ s: Double, _ id: String, _ input: [String: Any]) -> String {
            Fx.assistant(s, "p4", id: "m" + id, [Fx.toolUse("tu" + id, "mcp__ccd_turn__update_plan", input)], extra: desk)
        }
        try h.write("p4.jsonl", [
            plan(1, "1", ["items": [["content": "Look around", "status": "in_progress"], ["content": "Change it", "status": "pending"],
                                    ["content": "Check it", "status": "pending"]], "scope": "first_task"]),
            plan(2, "2", ["advance": true]),
        ])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var ev = h.events("p4")
        #expect(ev.mirrors.last?.tool == "desktop-plan" && ev.mirrors.last?.items.map(\.status) == [.completed, .inProgress, .pending])
        #expect(ev.metas.last?.host == TaskObserver.desktopHost && ev.metas.last?.cwd == Fx.cwd)
        // Changes read in one batch are written as one list.
        #expect(ev.mirrors.count == 1)
        try h.append("p4.jsonl", [plan(3, "3", ["done": [2], "start": 3])])
        _ = await o.ingest(paths: [h.path("p4.jsonl")])
        try h.append("p4.jsonl", [Fx.assistant(4, "p4", id: "w", [Fx.toolUse("tw", "mcp__ccd_turn__wrap_up", ["recap": "Done"])], extra: desk)])
        _ = await o.ingest(paths: [h.path("p4.jsonl")])
        ev = h.events("p4")
        try #require(ev.mirrors.count == 3)
        #expect(ev.mirrors[1].items.map(\.status) == [.completed, .completed, .inProgress])
        #expect(ev.mirrors[2].items.allSatisfy { $0.status == .completed })
        #expect(Set(ev.mirrors.map { $0.items.map(\.id) }).count == 1)
    }

    @Test func aTerminalSessionHasNoHost() async throws {
        let h = try ObserverHome()
        try h.write("p5.jsonl", Fx.launch(1, "p5", "tu0", "a0"))
        _ = await h.observer().scan(since: Fx.t0)
        let m = try #require(h.events("p5").metas.first)
        #expect(m.host == nil && m.cwd == Fx.cwd && m.project == "demo")
    }

    // MARK: Interrupts and errors

    @Test func anInterruptStopsTheRunAndCutsOffForegroundAgents() async throws {
        let h = try ObserverHome()
        try h.write("i1.jsonl", Fx.launch(1, "i1", "tbg", "bg") + [
            Fx.assistant(3, "i1", id: "m2", [Fx.agentCall("tfg", "Foreground job", prompt: "p")]),
        ])
        try h.write("i1/subagents/agent-fg.meta.json", [Fx.meta(description: "Foreground job", toolUseID: "tfg", finished: nil)])
        try h.write("i1/subagents/agent-fg.jsonl", [Fx.assistant(4, "i1", id: "f1", tokens: 5, [Fx.text("working")], agent: "fg")])
        try h.write("i1/subagents/agent-bg.jsonl", [Fx.assistant(4, "i1", id: "b1", tokens: 5, [Fx.text("working")], agent: "bg")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        #expect(h.events("i1").ops("run.stop").isEmpty)

        try h.append("i1.jsonl", [Fx.user(20, "i1", [Fx.text("[Request interrupted by user for tool use]")])])
        _ = await o.ingest(paths: [h.path("i1.jsonl")])
        var ev = h.events("i1")
        #expect(ev.ops("run.stop").map(\.at) == [Fx.t0.addingTimeInterval(20)])
        #expect(ev.end("agent:fg") == .interrupted && ev.end("agent:bg") == nil)

        try h.append("i1.jsonl", [Fx.user(30, "i1", "try again"), Fx.assistant(31, "i1", id: "m3", [Fx.text("On it")])])
        _ = await o.ingest(paths: [h.path("i1.jsonl")])
        ev = h.events("i1")
        #expect(ev.ops("run.resume").count == 1)
    }

    @Test func anInterruptBeforeTheMetaFileIsReadStillCutsTheAgentOff() async throws {
        let h = try ObserverHome()
        try h.write("i2.jsonl", Fx.launch(1, "i2", "tbg", "bg") + [
            Fx.assistant(3, "i2", id: "m2", [Fx.agentCall("tfg", "Foreground job", prompt: "p")]),
            Fx.user(20, "i2", [Fx.text("[Request interrupted by user]")]),
        ])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        // The agent's files show up afterwards and link to the call that was cut off.
        try h.write("i2/subagents/agent-fg.meta.json", [Fx.meta(description: "Foreground job", toolUseID: "tfg", finished: nil)])
        try h.write("i2/subagents/agent-fg.jsonl", [Fx.assistant(4, "i2", id: "f1", tokens: 5, [Fx.text("working")], agent: "fg")])
        _ = await o.ingest(paths: [h.path("i2/subagents/agent-fg.jsonl")])
        #expect(h.events("i2").end("agent:fg") == .interrupted)
    }

    @Test func typedTextAboutInterruptsIsNotAnInterrupt() async throws {
        let h = try ObserverHome()
        try h.write("i3.jsonl", Fx.launch(1, "i3", "tbg", "bg") + [
            Fx.user(5, "i3", "why did you print [Request interrupted by user] earlier?"),
            Fx.assistant(6, "i3", id: "m2", [Fx.toolUse("tb", "Bash", ["command": "ls"])]),
            Fx.user(7, "i3", Fx.toolResult("tb", "log: [Request interrupted by user]")),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.events("i3").ops("run.stop").isEmpty)
    }

    @Test func anErrorWithoutAnAgentIDEndsTheLinkedAgent() async throws {
        let h = try ObserverHome()
        try h.write("e1.jsonl", [Fx.assistant(1, "e1", id: "m1", [Fx.agentCall("tu1", "Job", prompt: "p")])])
        try h.write("e1/subagents/agent-a1.meta.json", [Fx.meta(description: "Job", toolUseID: "tu1", finished: nil)])
        try h.write("e1/subagents/agent-a1.jsonl", [Fx.assistant(2, "e1", id: "x1", tokens: 5, [Fx.text("…")], agent: "a1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        #expect(h.events("e1").end("agent:a1") == nil)
        try h.append("e1.jsonl", [Fx.user(9, "e1", Fx.toolResult("tu1", "Error: the agent crashed", error: true))])
        _ = await o.ingest(paths: [h.path("e1.jsonl")])
        #expect(h.events("e1").end("agent:a1") == .error)
    }

    // MARK: Binding, activity, limits

    @Test func theSameBriefToTwoProvidersBindsEachChildToItsOwn() async throws {
        let h = try ObserverHome()
        let brief = TaskObserverTests.brief
        try h.write("d1.jsonl", [
            Fx.assistant(1, "d1", id: "m1", [Fx.delegateCall("tcx", title: "Codex side", task: brief, provider: "codex_main")]),
            Fx.assistant(2, "d1", id: "m2", [Fx.delegateCall("tcl", title: "Claude side", task: brief, provider: "claudeAgent")]),
        ])
        // The Codex child starts after both delegates: by time alone it would bind to the later, Claude one.
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-dx.jsonl"
        try h.logs.write(rollout, [Fx.codexMeta(4, id: "cx-child"), Fx.codexEvent(4.1, "task_started"),
                                   Fx.codexUser(4.2, "Act as the implementation sub-agent for this task.\n\n" + brief),
                                   Fx.codexTokens(10, input: 100, cached: 0, output: 10)].joined())
        try h.write("k2.jsonl", [Fx.user(5, "k2", [Fx.text("Act as the implementation sub-agent for this task.\n\n" + brief)]),
                                 Fx.assistant(6, "k2", id: "c1", tokens: 5, [Fx.text("…")])])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        #expect(await o.boundChildren == ["cx-child", "k2"])
        let ev = h.events("d1")
        let codexTokens = ev.compactMap { if case .activity("delegate:tcx", _, let t?) = $0.op { t } else { nil } }.last
        #expect(codexTokens == 110)
        let claudeTokens = ev.compactMap { if case .activity("delegate:tcl", _, let t?) = $0.op { t } else { nil } }.last
        #expect(claudeTokens == 10)
    }

    @Test func toolResultsCountAsActivity() async throws {
        let h = try ObserverHome()
        h.clock.now = Fx.t0.addingTimeInterval(1000)
        try h.write("w1.jsonl", Fx.launch(1, "w1", "tu0", "a0") + [
            Fx.assistant(2, "w1", id: "m2", [Fx.toolUse("tb", "Bash", ["command": "make"])]),
        ])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        // A fifteen-minute command's result is the session at work.
        try h.append("w1.jsonl", [Fx.user(900, "w1", Fx.toolResult("tb", String(repeating: "output ", count: 2000)))])
        h.clock.now = Fx.t0.addingTimeInterval(1100)
        _ = await o.ingest(paths: [h.path("w1.jsonl")])
        let last = h.events("w1").last { if case .activity("session:w1", _, _) = $0.op { true } else { false } }
        #expect(last?.at == Fx.t0.addingTimeInterval(900))
    }

    @Test func aForegroundAgentAtWorkIsItsSessionAtWork() async throws {
        let h = try ObserverHome()
        try h.write("w2.jsonl", [Fx.assistant(1, "w2", id: "m1", [Fx.agentCall("tfg", "Long job", prompt: "p")])])
        try h.write("w2/subagents/agent-fg.meta.json", [Fx.meta(description: "Long job", toolUseID: "tfg", finished: nil)])
        try h.write("w2/subagents/agent-fg.jsonl", [Fx.assistant(600, "w2", id: "f1", tokens: 5, [Fx.text("…")], agent: "fg")])
        _ = await h.observer().scan(since: Fx.t0)
        let last = h.events("w2").last { if case .activity("session:w2", _, _) = $0.op { true } else { false } }
        #expect(last?.at == Fx.t0.addingTimeInterval(600))
    }

    @Test func codexToolOutputCountsAsActivity() async throws {
        let h = try ObserverHome()
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "cw1", source: .agent, op: .add(.init(id: "fix")))], stream: .journal, home: h.home)
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-cw.jsonl"
        try h.logs.write(rollout, [Fx.codexMeta(0, id: "cw1"), Fx.codexEvent(1, "task_started"), Fx.codexUser(1.1, "go"),
                                   Fx.codexOutput(700, callID: "c1", "long build output")].joined())
        _ = await h.observer().scan(since: Fx.t0)
        let last = h.events("cw1").last { if case .activity("session:cw1", _, _) = $0.op { true } else { false } }
        #expect(last?.at == Fx.t0.addingTimeInterval(700))
    }

    @Test func aUsageLimitWaits() async throws {
        let h = try ObserverHome()
        func limit(_ s: Double, _ id: String, agent: String? = nil) -> String {
            Fx.assistant(s, "l1", id: id, stop: "stop_sequence", [Fx.text("You've hit your session limit · resets 3pm (Somewhere)")], agent: agent,
                         extra: ["isApiErrorMessage": true, "error": "rate_limit", "apiErrorStatus": 429,
                                 "message": ["id": id, "role": "assistant", "model": "<synthetic>", "stop_reason": "stop_sequence",
                                             "content": [Fx.text("You've hit your session limit · resets 3pm (Somewhere)")],
                                             "usage": ["input_tokens": 0, "output_tokens": 0]]])
        }
        try h.write("l1.jsonl", Fx.launch(1, "l1", "tu1", "a1") + [limit(5, "lim1"), limit(6, "lim2")])
        try h.write("l1/subagents/agent-a1.jsonl", [Fx.assistant(2, "l1", id: "x1", tokens: 5, [Fx.text("…")], agent: "a1"), limit(4, "lim0", agent: "a1")])
        let o = h.observer()
        _ = await o.scan(since: Fx.t0)
        var w = h.events("l1").waits.filter { $0.reason == .limit }
        #expect(w.count == 2)
        let run = try #require(w.first { $0.attempt == nil })
        #expect(run.task == nil && run.note == "You've hit your session limit · resets 3pm (Somewhere)" && run.at == Fx.t0.addingTimeInterval(5))
        #expect(w.contains { $0.attempt == "agent:a1" && $0.at == Fx.t0.addingTimeInterval(4) })
        // The limit message is no activity of the session's: nothing at 5 or 6 can clear it.
        #expect(!h.events("l1").contains { if case .activity("session:l1", _, _) = $0.op { $0.at >= Fx.t0.addingTimeInterval(5) } else { false } })
        // After more work, a new limit is a new wait.
        try h.append("l1.jsonl", [Fx.assistant(100, "l1", id: "m9", tokens: 3, [Fx.text("Back")]), limit(200, "lim3")])
        _ = await o.ingest(paths: [h.path("l1.jsonl")])
        w = h.events("l1").waits.filter { $0.reason == .limit && $0.attempt == nil }
        #expect(w.map(\.at) == [Fx.t0.addingTimeInterval(5), Fx.t0.addingTimeInterval(200)])
    }

    @Test func aCodexUsageLimitWaits() async throws {
        let h = try ObserverHome()
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "cl1", source: .agent, op: .add(.init(id: "fix")))], stream: .journal, home: h.home)
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-cl.jsonl"
        try h.logs.write(rollout, [Fx.codexMeta(0, id: "cl1"), Fx.codexEvent(1, "task_started"), Fx.codexUser(1.1, "go"),
                                   Fx.codexEvent(5, "error", #","message":"You've hit your usage limit.","codex_error_info":"usage_limit_exceeded""#),
                                   Fx.codexEvent(5.5, "task_complete", #","error":{"codex_error_info":"usage_limit_exceeded","message":"limit"}"#)].joined())
        _ = await h.observer().scan(since: Fx.t0)
        let ev = h.events("cl1")
        let w = ev.waits.filter { $0.reason == .limit }
        #expect(w.count == 1 && w.first?.attempt == nil && w.first?.note == "Usage limit reached")
        #expect(ev.ops("run.stop").count == 1)
    }

    @Test func aCodexInterruptStops() async throws {
        let h = try ObserverHome()
        try TaskJournal.append([TaskEvent(at: Fx.t0, run: "ci1", source: .agent, op: .add(.init(id: "fix")))], stream: .journal, home: h.home)
        let rollout = ".codex/sessions/2026/10/10/rollout-2026-10-10T00-00-00-ci.jsonl"
        try h.logs.write(rollout, [Fx.codexMeta(0, id: "ci1"), Fx.codexEvent(1, "task_started"), Fx.codexUser(1.1, "go"),
                                   Fx.codexEvent(9, "turn_aborted", #","reason":"interrupted""#)].joined())
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.events("ci1").ops("run.stop").map(\.at) == [Fx.t0.addingTimeInterval(9)])
    }

    // MARK: Saved state

    @Test func stateSavedBeforeThisPassStillDecodes() throws {
        // Version-1 keys only, as the first pass wrote them.
        let old: [String: Any] = [
            "version": 1, "prunedAt": 0.0, "metaRuns": ["s1"], "delegateTasks": [:] as [String: String],
            "files": ["/x/s1.jsonl": ["role": "session", "session": "s1", "inode": 1, "offset": 10, "mtime": 5.0, "recentKeys": [] as [Int], "sawText": true]],
            "sessions": ["s1": ["id": "s1", "harness": "claude-code", "startedAt": 1.0, "lastAt": 2.0, "tokens": 3, "aborted": false, "spawned": true,
                                "out": ["run": "s1", "activityAt": 2.0] as [String: Any], "outStopped": false] as [String: Any]],
            "attempts": ["agent:a1": ["key": "agent:a1", "kind": "agent", "session": "s1", "startedAt": 1.0, "lastAt": 2.0, "tokens": 0,
                                      "out": [:] as [String: Any]] as [String: Any]],
            "spawns": ["tu1": ["tool": "agent", "spawner": "session:s1", "session": "s1", "at": 1.0] as [String: Any]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
        let state = try PropertyListDecoder().decode(ObserverState.self, from: data)
        #expect(state.sessions["s1"]?.spawned == true && state.sessions["s1"]?.question == nil && state.pendingCalls.isEmpty)
        #expect(state.spawns["tu1"]?.resultAt == nil && state.attempts["agent:a1"]?.out.question == nil)
    }

    @Test func questionAndPlanTextIsTrimmed() {
        #expect(HarnessText.clip("a\n\n  b   c", 10) == "a b c")
        #expect(HarnessText.clip(String(repeating: "x", count: 200), 120).count == 120)
        #expect(HarnessText.firstLine("\n\n## **Plan:** do it\nmore") == "Plan:** do it")
        #expect(HarnessText.limitNote("Claude AI usage limit reached|1760000000") == "Claude AI usage limit reached")
        #expect(TaskObserver.planStatus("canceled") == .cancelled && TaskObserver.planStatus("weird") == .pending)
    }
}
