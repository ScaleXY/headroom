import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomKit

/// A temporary Headroom home and a fixed clock.
final class Home: @unchecked Sendable {
    let url: URL
    var now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tasks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func run(_ args: [String], env: [String: String] = ["NO_COLOR": "1", "HEADROOM_RUN": "r1"], stdin: String? = nil, clock: (() -> Date)? = nil) -> (Int32, String) {
        var lines: [String] = []
        let fixed = now
        let code = HeadroomCLI.run(args, environment: env, output: { lines.append($0) }, home: url, input: .data(Data((stdin ?? "").utf8)),
                                   now: clock ?? { fixed })
        return (code, lines.joined(separator: "\n"))
    }

    func ctx(env: [String: String] = ["NO_COLOR": "1", "HEADROOM_RUN": "r1"], stdin: String = "", out: @escaping (String) -> Void = { _ in }, clock: (() -> Date)? = nil) -> TaskContext {
        let fixed = now
        return TaskContext(home: url, environment: env, now: clock ?? { fixed }, output: out, style: Style(colors: false), input: .data(Data(stdin.utf8)))
    }

    func events(_ run: String = "r1") -> [TaskEvent] { TaskJournal.read(run: run, home: url) }
    func fold(_ run: String = "r1") -> TaskRun? { TaskFold.fold(events(run), now: now).first }
}

extension TaskRun {
    func node(_ id: String) -> TaskNode { nodes.first { $0.id == id }! }
}

/// Collects output across threads.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite(.serialized) struct TaskCommandTests {
    @Test func runIDResolutionOrder() {
        let h = Home()
        var env = ["HEADROOM_RUN": "a", "CLAUDE_CODE_SESSION_ID": "b", "CODEX_THREAD_ID": "c", "T3CODE_THREAD_ID": "d"]
        for expected in ["a", "b", "c", "d"] {
            #expect(h.run(["task", "start", "t-\(expected)"], env: env).0 == 0)
            #expect(h.events(expected).contains { $0.op == .start(task: "t-\(expected)") })
            env.removeValue(forKey: ["a": "HEADROOM_RUN", "b": "CLAUDE_CODE_SESSION_ID", "c": "CODEX_THREAD_ID", "d": "T3CODE_THREAD_ID"][expected]!)
        }
        #expect(h.run(["task", "start", "x"], env: [:]).0 == 64)
        // The id's RUN: prefix beats the environment, and --run beats both. The prefix must name
        // a run that exists (or the current one): `fix:auth` is a typo for `fix/auth`, not a new run.
        #expect(h.run(["task", "start", "pre:api/x"], env: ["HEADROOM_RUN": "a"]).0 == 64)
        #expect(h.events("pre").isEmpty)
        #expect(h.run(["task", "start", "seed", "--run", "pre"]).0 == 0)
        #expect(h.run(["task", "start", "a:own"], env: ["HEADROOM_RUN": "a"]).0 == 0)
        #expect(h.run(["task", "start", "pre:api/x"], env: ["HEADROOM_RUN": "a"]).0 == 0)
        #expect(h.events("pre").contains { $0.op == .start(task: "api/x") })
        #expect(h.run(["task", "start", "pre:api/y", "--run", "flag"], env: ["HEADROOM_RUN": "a"]).0 == 0)
        #expect(h.events("flag").contains { $0.op == .start(task: "api/y") })
        #expect(!h.events("pre").contains { $0.op == .start(task: "api/y") })
        // Odd characters are cut down to a safe file name.
        #expect(h.run(["task", "start", "x", "--run", "my run/1"]).0 == 0)
        #expect(!h.events("my-run-1").isEmpty)
    }

    @Test func everySingleTaskCommand() throws {
        let h = Home()
        let (code, tag) = h.run(["task", "add", "api/tests", "--title", "API tests", "--effort", "l", "--importance", "critical", "--steps", "5"])
        #expect(code == 0 && tag.hasPrefix("[hr:r1:api/tests] added · run 0%"))
        #expect(h.run(["task", "add", "q", "--title", "Q", "--quiet"]).1 == "[hr:r1:q]")
        #expect(h.run(["task", "cancel", "q", "--quiet"]).1.isEmpty)
        #expect(h.run(["task", "add", "docs", "--title", "Docs", "--effort", "1.5", "--importance", "optional"]).0 == 0)
        #expect(h.run(["task", "add", "a", "--title", "A"]).0 == 0)
        #expect(h.run(["task", "add", "b", "--title", "B"]).0 == 0)
        #expect(h.run(["task", "start", "api/tests"]).0 == 0)
        #expect(h.run(["task", "progress", "api/tests", "--step", "2/5", "--note", "-- two down --"]).0 == 0)
        #expect(h.run(["task", "progress", "docs", "--fraction", "0.25"]).0 == 0)
        #expect(h.run(["task", "wait", "docs", "--for", "dependency", "--note", "after api"]).0 == 0)
        #expect(h.run(["task", "done", "a", "--evidence", "it works"]).0 == 0)
        #expect(h.run(["task", "fail", "b", "--reason", "flaky"]).0 == 0)
        #expect(h.run(["task", "add", "c", "--title", "C"]).0 == 0)
        #expect(h.run(["task", "skip", "c", "--reason", "not needed"]).0 == 0)
        #expect(h.run(["task", "add", "d", "--title", "D"]).0 == 0)
        #expect(h.run(["task", "cancel", "d"]).0 == 0)
        let r = try #require(h.fold())
        let tests = r.node("api/tests")
        #expect(tests.title == "API tests" && tests.effort == 8 && tests.importance == .critical && tests.state == .running)
        #expect(tests.steps == TaskSteps(done: 2, total: 5) && tests.note == "-- two down --")
        #expect(r.node("docs").state == .waiting && r.node("docs").waitReason == .dependency && r.node("docs").waitNote == "after api" && r.node("docs").effort == 1.5)
        #expect(r.node("a").evidence == "it works" && r.node("b").failure == "flaky")
        #expect(r.node("c").state == .skipped && r.node("c").note == "not needed" && r.node("d").state == .cancelled)
        #expect(r.project == nil && r.harness == nil) // HEADROOM_RUN names no harness, and the test env has no PWD
        // The first event carries the run's metadata.
        let h2 = Home()
        h2.run(["task", "start", "x"], env: ["CLAUDE_CODE_SESSION_ID": "s1", "PWD": "/Users/me/code/shop"])
        #expect(h2.fold("s1")?.harness == "claude-code" && h2.fold("s1")?.project == "shop")
    }

    @Test func badTaskArgumentsAreUsageErrors() {
        let h = Home()
        for args in [["task", "add", "x"], ["task", "add", "x y", "--title", "T"], ["task", "add", "x", "--title", "T", "--effort", "huge"],
                     ["task", "add", "x", "--title", "T", "--importance", "vital"], ["task", "add", "x", "--title", "T", "--steps", "0"],
                     ["task", "progress", "x", "--step", "a/b"], ["task", "progress", "x", "--fraction", "1.5"], ["task", "wait", "x"],
                     ["task", "wait", "x", "--for", "coffee"], ["task", "fail", "x"], ["task", "start"], ["task", "progress", "a", "b"],
                     ["task", "done", "x", "--bogus"], ["task", "frobnicate"], ["task", "note", "--title"],
                     // Flags meant for another action are refused, not dropped.
                     ["task", "start", "x", "--note", "n"], ["task", "done", "x", "--reason", "r"], ["task", "progress", "x", "--evidence", "e"],
                     ["task", "start", "x", "--force"], ["task", "done", "x", "--quiet=yes"],
                     ["task", "progress", "x", "--step", "5/4"], ["task", "progress", "x", "--step", "3"], ["task", "add", "x", "--title", "\n\t "],
                     ["task", "status", "x"], ["task", "plan", "x"], ["task", "adopt"]] {
            #expect(h.run(args).0 == 64, "\(args)")
        }
        #expect(h.events().isEmpty)
        #expect(h.run(["task", "--help"]).1.contains("headroom task plan"))
        // Each action has its own help.
        for action in TaskOps.actions + ["plan", "status", "adopt"] {
            let (code, out) = h.run(["task", action, "--help"])
            #expect(code == 0 && out.contains("usage: headroom task \(action)"), "\(action)")
        }
        #expect(h.run(["task", "done", "-h"]).1.contains("--force"))
        #expect(h.run(["task", "add", "x", "--title", "--help"]).0 == 0) // free text isn't a help flag
        // --flag=value works like --flag value.
        #expect(h.run(["task", "progress", "x", "--note=half way", "--fraction=0.5"]).0 == 0)
        #expect(h.fold()?.node("x").note == "half way")
    }

    @Test func aProjectGivenAsAPathIsStoredAsItsFolderName() throws {
        let h = Home()
        #expect(h.run(["task", "plan"], stdin: #"{"project": "/Users/me/clients/shop", "tasks": [{"id": "api"}]}"#).0 == 0)
        #expect(try #require(h.fold()).project == "shop")
        let journal = String(decoding: try Data(contentsOf: TaskJournal.url(run: "r1", stream: .journal, home: h.url)), as: UTF8.self)
        #expect(!journal.contains("/Users/me"))
    }

    @Test func planDeclaresATreeAndPrintsTags() throws {
        let h = Home()
        let plan = #"{"title": "Refactor", "project": "shop", "tasks": [{"id": "api", "title": "API", "effort": "l", "importance": "critical", "children": [{"id": "schema", "effort": 2}, {"id": "api/tests", "steps": 4}]}, {"id": "docs", "importance": "optional"}]}"#
        let (code, out) = h.run(["task", "plan"], stdin: plan)
        #expect(code == 0)
        #expect(out.contains("Declared 4 tasks in run r1"))
        #expect(out.contains("  [hr:r1:api]  API\n    [hr:r1:api/schema]  schema\n    [hr:r1:api/tests]  tests\n  [hr:r1:docs]  docs"))
        let r = try #require(h.fold())
        #expect(r.title == "Refactor" && r.project == "shop")
        #expect(r.nodes.map(\.id) == ["api", "api/schema", "api/tests", "docs"])
        #expect(r.node("api/schema").effort == 2 && r.node("api/tests").steps?.total == 4 && r.node("docs").importance == .optional)
        // From a file, a bare list, with --title.
        let file = h.url.appendingPathComponent("plan.json")
        try Data(#"[{"id": "x", "title": "X"}]"#.utf8).write(to: file)
        #expect(h.run(["task", "plan", "--run", "r2", "--title", "Second", "--file", file.path]).0 == 0)
        #expect(h.fold("r2")?.title == "Second" && h.fold("r2")?.nodes.count == 1)
        #expect(h.run(["task", "plan", "-"], stdin: "not json").0 == 64)
        #expect(h.run(["task", "plan"], stdin: #"{"tasks": []}"#).0 == 64)
        #expect(h.run(["task", "plan"], stdin: #"{"tasks": [{"title": "no id"}]}"#).0 == 64)
        #expect(h.run(["task", "plan", "--file", "/nonexistent/plan.json"]).0 == 64)
    }

    @Test func guideNamesTheRun() throws {
        let h = Home()
        let (code, out) = h.run(["task", "guide"])
        #expect(code == 0 && out.contains("headroom task plan") && out.contains("[hr:r1:api/tests]") && out.contains("r1 (from your environment"))
        #expect(h.run(["task", "guide"], env: [:]).1.contains("[hr:RUN:api/tests]"))
        // It opens by asking which you are, before anything about planning.
        let which = try #require(out.range(of: "which are you"))
        let plan = try #require(out.range(of: "headroom task plan"))
        #expect(which.lowerBound < plan.lowerBound)
        for phrase in ["Don't declare a plan", "under 3 steps", "derived", "close the task yourself", "skip", "cancel", "never started", "headroom task status"] {
            #expect(out.contains(phrase), "\(phrase)")
        }
    }
}

@Suite(.serialized) struct TasksViewTests {
    func seed(_ h: Home) {
        h.run(["task", "plan"], stdin: #"{"title": "Refactor auth", "tasks": [{"id": "api", "title": "API changes", "effort": "l", "children": [{"id": "schema", "title": "Schema", "importance": "critical"}, {"id": "tests", "title": "Tests", "steps": 4}]}, {"id": "docs", "title": "Docs", "importance": "optional"}]}"#)
        h.run(["task", "done", "api/schema"])
        h.run(["task", "progress", "api/tests", "--step", "1"])
        h.run(["task", "fail", "docs", "--reason", "crashes"])
    }

    @Test func fallbackFoldWithoutTasksJSON() throws {
        let h = Home()
        seed(h)
        let (code, out) = h.run(["tasks"])
        #expect(code == 0)
        #expect(out.contains("● Refactor auth  "))
        #expect(out.contains("must-haves 1/1"))
        #expect(out.contains("✓ Schema"))
        #expect(out.contains("● Tests") && out.contains("1/4"))
        #expect(out.contains("✗ Docs") && out.contains("crashes"))
        #expect(out.hasSuffix("(Headroom.app isn't running, so only tasks agents reported are shown)"))
        #expect(!out.contains("\u{1B}["))
        let (jcode, json) = h.run(["tasks", "--json"])
        #expect(jcode == 0)
        let feed = try TasksFile.decoder().decode(TasksFeed.self, from: Data(json.utf8))
        #expect(feed.schema == 1 && feed.runs.count == 1 && feed.runs.first?.nodes.count == 4)
        // API is half its weight in, docs (optional, failed) leaves the denominator: schema 1, tests 1/4 → 62%.
        #expect(abs((feed.runs.first?.progress.done ?? 0) - 0.625) < 1e-9)
        #expect(h.run(["tasks", "--run", "nope"]).1.contains("No task runs in the last 7 days."))
        #expect(h.run(["tasks", "--bogus"]).0 == 64)
    }

    @Test func activeRunsByDefaultAllWithFlag() {
        let h = Home()
        seed(h)
        h.run(["task", "done", "api/tests"])
        h.now = h.now.addingTimeInterval(3600) // finished an hour ago: no longer active
        #expect(h.run(["tasks"]).1.contains("No active task runs."))
        let all = h.run(["tasks", "--all"]).1
        #expect(all.contains("✓ Refactor auth"))
    }

    @Test func liveTasksJSONIsUsed() throws {
        let h = Home()
        seed(h) // run r1, written before the app's file: the app's copy wins
        let appRun = TaskRun(id: "r1", title: "From the app", project: nil, harness: nil, startedAt: h.now, updatedAt: h.now, state: .running, waitReason: nil,
                             stale: false, progress: .zero, mustHaves: TaskMustHaves(done: 0, total: 0), etaSeconds: nil, tokens: 0, scopeChanges: 0,
                             warning: "transcript unreadable", nodes: [])
        let feed = TasksFeed(generatedAt: Date().addingTimeInterval(60), writerPID: getpid(), runs: [appRun])
        try TasksFile.encoder().encode(feed).write(to: TasksFile.url(home: h.url))
        let out = h.run(["tasks"]).1
        #expect(out.contains("From the app") && out.contains("⚠ transcript unreadable"))
        #expect(!out.contains("isn't running"))
        // A run written to after the app's file is folded here, keeping the app's warning.
        let older = TasksFeed(generatedAt: Date().addingTimeInterval(-60), writerPID: getpid(), runs: [appRun])
        try TasksFile.encoder().encode(older).write(to: TasksFile.url(home: h.url))
        let fresh = h.run(["tasks"]).1
        #expect(fresh.contains("Refactor auth") && fresh.contains("⚠ transcript unreadable"))
        // A dead writer's file is ignored.
        let dead = TasksFeed(generatedAt: Date().addingTimeInterval(60), writerPID: 999_999, runs: [appRun])
        try TasksFile.encoder().encode(dead).write(to: TasksFile.url(home: h.url))
        #expect(h.run(["tasks"]).1.contains("Refactor auth"))
    }

    @Test func watchRedrawsOnChange() async {
        let h = Home()
        seed(h)
        let lines = Lines()
        after(0.4) { _ = h.run(["task", "done", "api/tests"]) }
        let code = await offPool {
            let start = Date()
            var frames = 0
            // Other suites post the same notification, so draw until the change shows (or give up).
            return TasksCommand.run(["--watch"], ctx: h.ctx(out: lines.add, clock: Date.init)) { frame in
                frames += 1
                return !frame.contains("✓ Tests") && frames < 40 && Date().timeIntervalSince(start) < 10
            }
        }
        #expect(code == 0)
        #expect(lines.all.count >= 2)
        #expect(lines.all.first?.contains("● Tests") == true)
        #expect(lines.all.last?.contains("✓ Tests") == true)
    }

    @Test func statuslineAddsTheRun() throws {
        let h = Home()
        let snap = Snapshot(generatedAt: h.now, appVersion: "t", appPID: getpid(), providers: [ProviderSnapshot(id: .claude, weekly: WeeklySnapshot(
            label: nil, used: 0.2, left: 0.8, resetsAt: h.now.addingTimeInterval(86400), windowHours: 168, state: "plenty", multiple: 2, cells: 4,
            hourglass: false, runsOutAt: nil, unusedAtReset: nil, verdict: VerdictSnapshot(title: "", primary: "", secondary: "")))])
        try SnapshotFile.encoder().encode(snap).write(to: h.url.appendingPathComponent("snapshot.json"))
        let base = h.run(["statusline", "--format", "plain"], env: [:]).1
        #expect(base == "Claude 🟦🟦🟦🟦⬛ 80%")
        seed(h)
        #expect(h.run(["statusline", "--format", "plain"]).1 == base + "  ▤ 62% ▶1")
        // Claude Code pipes its session JSON; its session_id names the run.
        h.run(["task", "wait", "api/tests", "--for", "input"], env: ["CLAUDE_CODE_SESSION_ID": "sess"])
        let piped = h.run(["statusline"], env: ["NO_COLOR": "1"], stdin: #"{"session_id": "sess", "model": {}}"#).1
        #expect(piped.hasSuffix("▤ 0% ⏸input"))
        #expect(h.run(["statusline", "--format", "plain"], env: ["HEADROOM_RUN": "unknown"]).1 == base)
    }
}

@Suite(.serialized) struct HookTests {
    func hook(_ h: Home, _ payload: String, _ args: [String] = []) -> (Int32, String) {
        h.run(["task", "hook"] + args, env: ["NO_COLOR": "1"], stdin: payload)
    }

    @Test func subagentLifecycle() throws {
        let h = Home()
        #expect(hook(h, #"{"session_id": "abc123", "transcript_path": "/x.jsonl", "cwd": "/Users/me/shop", "hook_event_name": "SubagentStart", "agent_id": "agent-def456", "agent_type": "Explore"}"#) == (0, ""))
        var events = h.events("abc123")
        #expect(events.first?.op == .meta(title: nil, project: "shop", harness: "claude-code", host: nil, cwd: "/Users/me/shop"))
        #expect(events.last?.op == .attempt(.init(key: "agent:def456", kind: .agent, agentType: "Explore")))
        #expect(events.allSatisfy { $0.source == .hook })
        #expect(hook(h, #"{"session_id": "abc123", "hook_event_name": "SubagentStop", "stop_hook_active": false, "agent_id": "def456", "agent_type": "Explore", "agent_transcript_path": "/a/subagents/agent-def456.jsonl", "last_assistant_message": "done", "background_tasks": []}"#).0 == 0)
        events = h.events("abc123")
        #expect(events.last?.op == .attemptEnd(attempt: "agent:def456", outcome: .ok))
        // The harness's own helpers stop with an empty agent type: ignored.
        _ = hook(h, #"{"session_id": "abc123", "hook_event_name": "SubagentStop", "agent_id": "zzz", "agent_type": ""}"#)
        #expect(h.events("abc123").count == events.count)
        let r = try #require(TaskFold.fold(h.events("abc123"), now: h.now).first)
        #expect(r.node("~agent-def456").state == .done && !r.node("~agent-def456").confirmed && r.node("~agent-def456").title == "Explore")
    }

    @Test func notificationsPromptsStopsAndEnds() {
        let h = Home()
        h.run(["task", "add", "api", "--title", "API"], env: ["HEADROOM_RUN": "s1"])
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "Notification", "message": "Claude needs your permission to use Bash", "title": "Permission needed", "notification_type": "permission_prompt"}"#)
        #expect(h.events("s1").last?.op == .wait(task: nil, attempt: nil, reason: .input, note: "Claude needs your permission to use Bash"))
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "Notification", "notification_type": "idle_prompt", "agent_id": "a9"}"#)
        #expect(h.events("s1").last?.op == .wait(task: nil, attempt: "agent:a9", reason: .input, note: "idle_prompt"))
        let n = h.events("s1").count
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "Notification", "notification_type": "auth_success", "message": "ok"}"#)
        #expect(h.events("s1").count == n)
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": "go on", "permission_mode": "default"}"#)
        #expect(h.events("s1").last?.op == .resume)
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "x", "background_tasks": [{"id": "t", "type": "shell"}], "session_crons": []}"#)
        #expect(h.events("s1").last?.op == .stop(blocked: false))
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "SessionEnd", "reason": "other"}"#)
        #expect(h.events("s1").last?.op == .end)
        // Codex: PermissionRequest instead of Notification, harness from the flag.
        _ = hook(h, #"{"session_id": "cx", "hook_event_name": "SubagentStart", "agent_id": "k1", "agent_type": "worker", "turn_id": "t1", "model": "gpt"}"#, ["--harness", "codex"])
        _ = hook(h, #"{"session_id": "cx", "hook_event_name": "PermissionRequest", "tool_name": "shell", "tool_input": {}}"#, ["--harness", "codex"])
        #expect(h.events("cx").first?.op == .meta(title: nil, project: nil, harness: "codex"))
        #expect(h.events("cx").last?.op == .wait(task: nil, attempt: nil, reason: .input, note: "permission for shell"))
    }

    @Test func oddInputNeverFails() {
        let h = Home()
        for payload in ["", "not json", "[]", "{}", #"{"hook_event_name": 7}"#, #"{"hook_event_name": "Stop"}"#, #"{"hook_event_name": "PreToolUse", "session_id": "s"}"#,
                        #"{"hook_event_name": "Notification", "session_id": "s", "notification_type": null}"#,
                        #"{"hook_event_name": "SubagentStart", "session_id": "s"}"#, #"{"hook_event_name": "SubagentStart", "session_id": 12, "agent_id": "x"}"#] {
            #expect(hook(h, payload) == (0, ""), "\(payload)")
        }
        // Lifecycle events alone never create a run.
        _ = hook(h, #"{"session_id": "quiet", "hook_event_name": "Stop", "stop_hook_active": false}"#)
        _ = hook(h, #"{"session_id": "quiet", "hook_event_name": "UserPromptSubmit"}"#)
        #expect(TaskJournal.runs(home: h.url).isEmpty)
        // With no session id the environment names the run.
        h.run(["task", "add", "a", "--title", "A"], env: ["HEADROOM_RUN": "envrun"])
        #expect(h.run(["task", "hook"], env: ["HEADROOM_RUN": "envrun"], stdin: #"{"hook_event_name": "Stop"}"#).0 == 0)
        #expect(h.events("envrun").last?.op == .stop(blocked: false))
    }

    @Test func enforcingStopBlocksOnceForOrphanedTasks() throws {
        let h = Home()
        let env = ["HEADROOM_RUN": "s1"]
        h.run(["task", "add", "api", "--title", "API"], env: env)
        h.run(["task", "add", "docs", "--title", "Docs"], env: env)
        h.run(["task", "start", "api"], env: env)
        let stop = #"{"session_id": "s1", "hook_event_name": "Stop", "stop_hook_active": false}"#
        #expect(hook(h, stop) == (0, "")) // not enforcing
        let (code, out) = hook(h, stop, ["--enforce"])
        #expect(code == 0)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: String])
        #expect(obj["decision"] == "block" && obj["reason"]?.contains("api") == true && obj["reason"]?.contains("docs") == false)
        #expect(h.events("s1").last?.op == .stop(blocked: true))
        // Never twice in a row, whatever the harness says.
        #expect(hook(h, stop, ["--enforce"]) == (0, ""))
        // The message offers an answer for work still running in the background.
        #expect(obj["reason"]?.contains("running in the background") == true)
        // Reporting on the task answers the block for this turn; the harness's own guard holds too.
        h.now = h.now.addingTimeInterval(60)
        h.run(["task", "progress", "api", "--note", "running in the background"], env: env)
        #expect(hook(h, #"{"session_id": "s1", "hook_event_name": "Stop", "stop_hook_active": true}"#, ["--enforce"]) == (0, ""))
        #expect(hook(h, stop, ["--enforce"]) == (0, ""))
        // A new turn that ends with it still running: sent back again.
        h.now = h.now.addingTimeInterval(60)
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "UserPromptSubmit"}"#)
        h.now = h.now.addingTimeInterval(60)
        #expect(hook(h, stop, ["--enforce"]).1.contains("block"))
        // Not while the harness says work is still running in the background.
        h.now = h.now.addingTimeInterval(60)
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "UserPromptSubmit"}"#)
        h.now = h.now.addingTimeInterval(60)
        #expect(hook(h, #"{"session_id": "s1", "hook_event_name": "Stop", "stop_hook_active": false, "background_tasks": [{"id": "b1", "type": "agent"}]}"#, ["--enforce"]) == (0, ""))
        #expect(h.events("s1").last?.op == .stop(blocked: false))
        // A task with an agent on it is fine.
        h.run(["task", "done", "api"], env: env)
        h.run(["task", "start", "docs"], env: env)
        _ = hook(h, #"{"session_id": "s1", "hook_event_name": "SubagentStart", "agent_id": "w", "agent_type": "general-purpose"}"#)
        _ = h.run(["task", "hook"], env: ["NO_COLOR": "1"], stdin: "") // nothing on stdin: ignored
        var tl = h.events("s1")
        tl.append(TaskEvent(at: h.now, run: "s1", source: .harness, op: .attempt(.init(key: "agent:w", tag: "docs"))))
        try TaskJournal.append([tl.last!], stream: .observed, home: h.url)
        #expect(hook(h, stop, ["--enforce"]) == (0, ""))
    }
}

@Suite(.serialized) struct HooksInstallTests {
    func settings(_ h: Home, _ text: String?) throws -> URL {
        let url = h.url.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text { try Data(text.utf8).write(to: url) }
        return url
    }

    func hooks(_ h: Home, _ args: [String]) -> (Int32, String) {
        let lines = Lines()
        let code = HooksCommand.run(args, ctx: h.ctx(env: ["HOME": h.url.path, "NO_COLOR": "1"], out: lines.add), executable: "/Users/me/.local/bin/headroom")
        return (code, lines.all.joined(separator: "\n"))
    }

    func json(_ url: URL) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }

    @Test func installIsIdempotentAndKeepsEverythingElse() throws {
        let h = Home()
        let original = #"{"model": "opus", "permissions": {"allow": ["Bash(ls)"]}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}], "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/x/lint.sh"}]}]}}"#
        let url = try settings(h, original)
        let (code, out) = hooks(h, ["install", "--settings", url.path])
        #expect(code == 0 && out.contains("Installed Headroom hooks"))
        #expect(String(decoding: try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("settings.json.headroom-backup")), as: UTF8.self) == original)
        let root = try json(url)
        #expect(root["model"] as? String == "opus" && (root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)", "Bash(headroom task:*)"])
        let hk = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hk.keys) == ["Stop", "PreToolUse", "Notification", "UserPromptSubmit", "SubagentStart", "SubagentStop", "SessionEnd", "SessionStart"])
        #expect(((hk["SessionStart"] as? [[String: Any]])?.first?["matcher"] as? String) == "resume|clear|compact")
        // The user's keys keep their order and the file its two-space indentation.
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"model\": \"opus\",\n  \"permissions\": {"))
        let stop = try #require(hk["Stop"] as? [[String: Any]])
        #expect(stop.count == 2 && ((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "say done")
        #expect(((stop[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/Users/me/.local/bin/headroom task hook")
        let note = try #require((hk["Notification"] as? [[String: Any]])?.first)
        #expect((note["matcher"] as? String)?.contains("permission_prompt") == true && (note["matcher"] as? String)?.contains("idle_prompt") == true)
        // Again: nothing changes.
        let before = try Data(contentsOf: url)
        #expect(hooks(h, ["install", "--settings", url.path]).1.contains("already installed"))
        #expect(try Data(contentsOf: url) == before)
        // With --enforce: replaced, not added.
        #expect(hooks(h, ["install", "--settings", url.path, "--enforce"]).0 == 0)
        let enforced = try #require(try json(url)["hooks"] as? [String: Any])
        let stops = try #require(enforced["Stop"] as? [[String: Any]])
        #expect(stops.count == 2 && ((stops[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/Users/me/.local/bin/headroom task hook --enforce")
        let (_, status) = hooks(h, ["status", "--settings", url.path])
        #expect(status.contains("All 7 installed") && status.contains("✓ SubagentStart") && status.contains("no hook has run yet"))
        #expect(status.contains("--enforce") && status.contains("without a permission prompt"))
        // Uninstall leaves the user's hooks and keys exactly.
        #expect(hooks(h, ["uninstall", "--settings", url.path]).1.contains("Removed"))
        let after = try json(url)
        #expect(NSDictionary(dictionary: after).isEqual(to: try #require(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])))
        #expect(hooks(h, ["uninstall", "--settings", url.path]).1.contains("No Headroom hooks"))
        #expect(hooks(h, ["status", "--settings", url.path]).1.contains("Not installed"))
        // The backup is still the file from before Headroom: the reinstall and the uninstall didn't replace it.
        #expect(String(decoding: try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("settings.json.headroom-backup")), as: UTF8.self) == original)
    }

    @Test func aHooksEntryThatIsNotAListIsLeftAlone() throws {
        let h = Home()
        let odd = #"{"hooks": {"Stop": {"command": "say done"}}}"#
        let url = try settings(h, odd)
        #expect(hooks(h, ["install", "--settings", url.path]).0 == 1)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == odd)
    }

    @Test func newFilesBadFilesAndCodex() throws {
        let h = Home()
        // No file yet: created, no backup.
        let fresh = h.url.appendingPathComponent("new/.claude/settings.json")
        #expect(hooks(h, ["install", "--settings", fresh.path]).0 == 0)
        #expect(try json(fresh)["hooks"] != nil)
        #expect(!FileManager.default.fileExists(atPath: fresh.path + ".headroom-backup"))
        #expect(hooks(h, ["uninstall", "--settings", fresh.path]).0 == 0)
        #expect(try json(fresh).isEmpty)
        // Not JSON: left alone.
        let bad = try settings(h, "{ not json")
        #expect(hooks(h, ["install", "--settings", bad.path]).0 == 1)
        #expect(String(decoding: try Data(contentsOf: bad), as: UTF8.self) == "{ not json")
        // Codex's hooks.json under HOME by default.
        #expect(hooks(h, ["install", "--codex"]).0 == 0)
        let codex = try json(h.url.appendingPathComponent(".codex/hooks.json"))
        let ck = try #require(codex["hooks"] as? [String: Any])
        #expect(Set(ck.keys) == ["PermissionRequest", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "SessionEnd", "SessionStart"])
        #expect(((ck["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/Users/me/.local/bin/headroom task hook --harness codex")
        #expect(codex["permissions"] == nil)
        #expect(hooks(h, ["status", "--codex"]).1.contains("All 7 installed"))
        // Default Claude path under HOME, and --project under PWD.
        #expect(hooks(h, ["install"]).0 == 0)
        #expect(FileManager.default.fileExists(atPath: h.url.appendingPathComponent(".claude/settings.json").path))
        let lines = Lines()
        let proj = h.url.appendingPathComponent("proj")
        _ = HooksCommand.run(["install", "--project"], ctx: h.ctx(env: ["HOME": h.url.path, "PWD": proj.path], out: lines.add), executable: "/a b/headroom")
        let pj = try json(proj.appendingPathComponent(".claude/settings.json"))
        #expect((((pj["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "'/a b/headroom' task hook")
        #expect(hooks(h, ["bogus"]).0 == 64 && hooks(h, ["install", "--wat"]).0 == 64)
        #expect(h.run(["hooks", "--help"]).1.contains("--codex"))
    }

    @Test func recognisesOnlyOurCommands() {
        #expect(HookInstaller.isOurs("/opt/homebrew/bin/headroom task hook"))
        #expect(HookInstaller.isOurs("headroom task hook --enforce"))
        #expect(HookInstaller.isOurs("'/a b/headroom' task hook"))
        #expect(!HookInstaller.isOurs("headroom tasks"))
        #expect(!HookInstaller.isOurs("/x/not-headroom task hook"))
        #expect(!HookInstaller.isOurs("echo headroom task hook"))
    }

    @Test func dispatchThroughTheCLI() throws {
        let h = Home()
        let url = try settings(h, "{}")
        // A `headroom` on the path in this home, so the hook doesn't point at the test runner.
        let bin = h.url.appendingPathComponent(".local/bin/headroom")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let (code, out) = h.run(["hooks", "install", "--settings", url.path], env: ["HOME": h.url.path])
        #expect(code == 0 && out.contains("task hook"))
        #expect(h.run(["hooks", "status", "--settings", url.path]).1.contains("All 7 installed"))
    }
}

@Suite(.serialized) struct MCPTests {
    func session(_ h: Home, _ lines: [String], env: [String: String] = ["HEADROOM_RUN": "m1"]) -> [[String: Any]] {
        let (code, out) = h.run(["mcp"], env: env, stdin: lines.joined(separator: "\n") + "\n")
        #expect(code == 0)
        return out.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    func call(_ id: Int, _ name: String, _ args: [String: Any]) -> String {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": args]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func text(_ reply: [String: Any]) -> String { (((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    func isError(_ reply: [String: Any]) -> Bool { (reply["result"] as? [String: Any])?["isError"] as? Bool ?? false }

    @Test func handshakeAndErrors() throws {
        let h = Home()
        let replies = session(h, [
            #"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}"#,
            #"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#,
            #"{"jsonrpc": "2.0", "id": "p", "method": "ping"}"#,
            #"{"jsonrpc": "2.0", "id": 3, "method": "tools/list"}"#,
            "",
            "garbage",
            #"{"jsonrpc": "2.0", "id": 4, "method": "resources/list"}"#,
            #"{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "nope"}}"#,
            #"{"jsonrpc": "2.0", "id": 6, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}}"#,
        ])
        #expect(replies.count == 7)
        let initResult = try #require(replies[0]["result"] as? [String: Any])
        #expect(replies[0]["id"] as? Int == 1 && initResult["protocolVersion"] as? String == "2025-06-18")
        #expect((initResult["serverInfo"] as? [String: Any])?["name"] as? String == "headroom")
        #expect((initResult["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(replies[1]["id"] as? String == "p" && (replies[1]["result"] as? [String: Any])?.isEmpty == true)
        let tools = try #require((replies[2]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["get_headroom", "get_tasks", "task_status", "task_guide", "plan_tasks", "update_task"])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        #expect((replies[3]["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect((replies[4]["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect((replies[5]["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect((replies[6]["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    }

    @Test func toolsDeclareUpdateAndRead() throws {
        let h = Home()
        var replies = session(h, [call(1, "get_headroom", [:])])
        #expect(isError(replies[0]) && text(replies[0]).contains("no"))
        let snap = Snapshot(generatedAt: h.now, appVersion: "t", appPID: 1, providers: [])
        try SnapshotFile.encoder().encode(snap).write(to: h.url.appendingPathComponent("snapshot.json"))
        replies = session(h, [
            call(1, "get_headroom", [:]),
            call(2, "plan_tasks", ["title": "Via MCP", "tasks": [["id": "api", "title": "API", "effort": "l", "children": [["id": "tests", "steps": 3]]], ["id": "docs", "importance": "optional"]]]),
            call(3, "update_task", ["id": "api/tests", "action": "progress", "step": "1/3", "note": "first"]),
            call(4, "update_task", ["id": "docs", "action": "done", "evidence": "written"]),
            call(5, "update_task", ["id": "extra", "action": "add", "title": "Extra", "effort": 2]),
            call(6, "update_task", ["id": "api/tests", "action": "explode"]),
            call(7, "update_task", ["id": "docs", "action": "wait"]),
            call(8, "get_tasks", [:]),
            call(9, "update_task", ["id": "other:x", "action": "start"]),
            call(10, "update_task", ["id": "api/tset", "action": "start"]),
            call(11, "update_task", ["id": "new", "action": "add"]),
            call(12, "update_task", ["id": "api/tests", "action": "start", "note": "dropped?"]),
            call(13, "update_task", ["ids": ["api/tests", "extra"], "action": "done", "evidence": "all green"]),
            call(14, "task_status", [:]),
            call(15, "task_guide", [:]),
            call(16, "update_task", ["id": "api", "action": "skip"]),
        ])
        #expect(!isError(replies[0]) && text(replies[0]).contains("\"schema\""))
        #expect(text(replies[1]).contains("[hr:m1:api/tests]") && !isError(replies[1]))
        // Every write answers with the run's percent and what is open.
        #expect(text(replies[2]).hasPrefix("api/tests 1/3 · run ") && text(replies[2]).contains("open: api/tests"))
        #expect(text(replies[3]).hasPrefix("✓ docs done · run "))
        #expect(text(replies[4]).hasPrefix("[hr:m1:extra] added · run "))
        #expect(isError(replies[5]) && isError(replies[6]))
        let feed = try TasksFile.decoder().decode(TasksFeed.self, from: Data(text(replies[7]).utf8))
        let run = try #require(feed.run("m1"))
        #expect(run.title == "Via MCP")
        #expect(run.node("api/tests").steps == TaskSteps(done: 1, total: 3) && run.node("docs").state == .done && run.node("extra").effort == 2)
        // The same checks as the command line: no run from a typo, no task from a typo, no
        // untitled new task, no option the action doesn't use.
        #expect(isError(replies[8]) && h.events("other").isEmpty)
        #expect(isError(replies[9]) && text(replies[9]).contains("Did you mean api/tests?"))
        #expect(isError(replies[10]) && text(replies[10]).contains("--title"))
        #expect(isError(replies[11]) && text(replies[11]).contains("start doesn't use note"))
        #expect(!isError(replies[12]) && text(replies[12]).hasPrefix("✓ api/tests, extra done"))
        #expect(text(replies[13]).hasPrefix("run m1 \"Via MCP\"") && text(replies[13]).contains("\napi ") && text(replies[13]).contains("\nextra "))
        #expect(text(replies[14]).contains("which are you"))
        #expect(!isError(replies[15]) && text(replies[15]).hasPrefix("⊘ api skipped")) // its children are all closed
        // No run id anywhere.
        let none = session(h, [call(1, "update_task", ["id": "x", "action": "start"])], env: [:])
        #expect(isError(none[0]))
    }
}

@Suite(.serialized) struct RunWaitTests {
    @Test func returnsAtOnceWhenFinished() {
        let h = Home()
        h.run(["task", "add", "a", "--title", "A"])
        h.run(["task", "done", "a"])
        let (code, out) = h.run(["wait", "--run", "r1"])
        #expect(code == 0 && out.contains("▶ r1 · done · 100%"))
        let (jcode, json) = h.run(["wait", "--run", "r1", "--json"])
        #expect(jcode == 0 && json.contains(#""state":"done""#))
    }

    @Test func timesOutWhileRunning() {
        let h = Home()
        h.run(["task", "start", "a"])
        let start = Date()
        let (code, out) = h.run(["wait", "--run", "r1", "--timeout", "1s"], clock: Date.init)
        #expect(code == 2 && out.contains("timed out"))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(h.run(["wait", "--run", "nobody", "--timeout", "0s"]).0 == 2)
        #expect(h.run(["wait", "--run", "r1", "--until", "soon"]).0 == 64)
        #expect(h.run(["wait", "--run", "r1", "--timeout", "never"]).0 == 64)
    }

    @Test func wakesWhenTheRunFinishes() async {
        let h = Home()
        h.run(["task", "start", "a"])
        after(0.4) { _ = h.run(["task", "done", "a"], clock: Date.init) }
        let start = Date()
        let (code, out) = await offPool { h.run(["wait", "--run", "r1", "--timeout", "20s"], clock: Date.init) }
        #expect(code == 0 && out.contains("waiting on run r1") && out.contains("done"))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func attentionReturnsOnInputOrStop() {
        let h = Home()
        h.run(["task", "start", "a"])
        h.run(["task", "wait", "a", "--for", "input"])
        #expect(h.run(["wait", "--run", "r1", "--until", "attention"]).0 == 0)
        #expect(h.run(["wait", "--run", "r1", "--timeout", "0s"]).0 == 2) // still not done
        let s = Home()
        s.run(["task", "start", "a"])
        _ = s.run(["task", "hook"], env: [:], stdin: #"{"session_id": "r1", "hook_event_name": "Stop"}"#)
        let (code, out) = s.run(["wait", "--run", "r1", "--until", "attention"])
        #expect(code == 0 && out.contains("your turn"))
    }
}

@Suite struct TaskCompactionCLITests {
    /// Agents that finished two days ago are counted, not listed, in the fallback fold.
    @Test func fallbackFoldCompactsOldFinishedAgents() throws {
        let h = Home()
        let old = h.now.addingTimeInterval(-2 * 86400)
        var events: [TaskEvent] = [TaskEvent(at: old, run: "r1", source: .harness, op: .attempt(.init(key: "session:1", kind: .session)))]
        for i in 0..<5 {
            events.append(TaskEvent(at: old.addingTimeInterval(Double(i)), run: "r1", source: .harness,
                                    op: .attempt(.init(key: "agent:o\(i)", kind: .agent, parentKey: "session:1", title: "Old \(i)"))))
            events.append(TaskEvent(at: old.addingTimeInterval(60 + Double(i)), run: "r1", source: .harness, op: .attemptEnd(attempt: "agent:o\(i)", outcome: .ok)))
        }
        events.append(TaskEvent(at: h.now.addingTimeInterval(-30), run: "r1", source: .harness,
                                op: .attempt(.init(key: "agent:new", kind: .agent, parentKey: "session:1", title: "Still going"))))
        try TaskJournal.append(events, stream: .observed, home: h.url)
        let out = h.run(["tasks"]).1
        #expect(out.contains("Still going") && !out.contains("Old 0"))
        #expect(out.contains("+ 5 finished earlier"))
        let feed = try TasksFile.decoder().decode(TasksFeed.self, from: Data(h.run(["tasks", "--json"]).1.utf8))
        #expect(feed.runs.first?.finishedEarlier == 5 && feed.runs.first?.nodes.count == 1)
    }
}
