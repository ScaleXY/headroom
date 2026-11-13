import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomKit

/// The second pass: checks against the run, the line back, several ids, status, adopt, the
/// SessionStart hook, heartbeats and host/cwd.
@Suite(.serialized) struct TaskReportTests {
    let plan = #"{"title": "Refactor auth", "tasks": [{"id": "api", "title": "API", "children": [{"id": "schema", "title": "Schema"}, {"id": "tests", "title": "Tests", "steps": 4}]}, {"id": "docs", "title": "Docs"}]}"#

    func seeded() -> Home {
        let h = Home()
        h.run(["task", "plan"], stdin: plan)
        return h
    }

    /// The failure `TaskOps.apply` throws (what the CLI prints on standard error).
    func failure(_ h: Home, _ q: TaskOps.Request, env: [String: String] = ["HEADROOM_RUN": "r1"]) -> String? {
        do { _ = try TaskOps.apply(q, ctx: h.ctx(env: env)); return nil } catch { return error.message }
    }

    @Test func aTypoNeverCreatesATaskOnceAPlanExists() throws {
        let h = seeded()
        let n = h.events().count
        #expect(h.run(["task", "done", "api/shema"]).0 == 64)
        #expect(h.run(["task", "start", "nothing-like-it"]).0 == 64)
        #expect(h.events().count == n)
        let msg = try #require(failure(h, .init(action: "done", ids: ["api/shema"])))
        #expect(msg.contains("no task api/shema in run r1. Did you mean api/schema?") && msg.contains("headroom task add api/shema"))
        // Far from everything: the open tasks instead.
        #expect(failure(h, .init(action: "start", ids: ["zzzzzzzzzz"]))?.contains("Open tasks: api/schema, api/tests, docs") == true)
        // `fix:auth` is read as run `fix`, which doesn't exist.
        let colon = try #require(failure(h, .init(action: "done", ids: ["fix:auth"])))
        #expect(colon.contains("no run 'fix'") && colon.contains("fix/auth"))
        // add still creates; and before any plan, anything goes.
        #expect(h.run(["task", "add", "api/rate", "--title", "Rate limits"]).0 == 0)
        #expect(h.run(["task", "start", "api/rate"]).0 == 0)
        let fresh = Home()
        #expect(fresh.run(["task", "start", "anything"]).0 == 0)
        #expect(fresh.run(["task", "start", "else"]).0 == 0) // a start isn't a plan
        // Re-adding a known task needs no title.
        #expect(h.run(["task", "add", "docs", "--effort", "xs"]).0 == 0)
        #expect(h.fold()?.node("docs").effort == 1)
    }

    @Test func aParentWithOpenChildrenClosesOnlyWithForce() throws {
        let h = seeded()
        h.run(["task", "start", "api/schema"])
        #expect(h.run(["task", "done", "api"]).0 == 64)
        let msg = try #require(failure(h, .init(action: "done", ids: ["api"])))
        #expect(msg.contains("api/schema (running), api/tests (planned)") && msg.contains("--force"))
        #expect(h.fold()?.node("api/schema").state == .running)
        // Closing the children in the same call is fine, and each keeps its own outcome.
        #expect(h.run(["task", "done", "api", "api/schema", "api/tests", "--evidence", "green"]).0 == 0)
        let r = try #require(h.fold())
        #expect(r.node("api/schema").state == .done && r.node("api/tests").state == .done && r.node("api/schema").evidence == "green")
        // --force closes them all the same way.
        let g = seeded()
        #expect(g.run(["task", "cancel", "api", "--force", "--reason", "replanned"]).0 == 0)
        #expect(g.fold()?.node("api/tests").state == .cancelled)
    }

    @Test func severalIdsAtOnceInOneRun() throws {
        let h = seeded()
        let (code, out) = h.run(["task", "start", "api/schema", "api/tests", "docs"])
        #expect(code == 0 && out.hasPrefix("started api/schema, api/tests, docs · run 0%"))
        #expect(h.run(["task", "skip", "api/tests", "docs", "--reason", "later"]).1.hasPrefix("⊘ api/tests, docs skipped"))
        let r = try #require(h.fold())
        #expect(r.node("api/schema").state == .running && r.node("docs").state == .skipped && r.node("docs").note == "later")
        // Ids from two runs in one call: refused.
        h.run(["task", "start", "x", "--run", "r2"])
        #expect(failure(h, .init(action: "done", ids: ["api/schema", "r2:x"]))?.contains("one call reports on one run") == true)
        #expect(h.run(["task", "progress", "api/schema", "docs"]).0 == 64)
    }

    @Test func stepsMustFitTheirTotal() {
        let h = seeded()
        #expect(h.run(["task", "progress", "api/tests", "--step", "5/4"]).0 == 64)
        #expect(h.run(["task", "progress", "api/tests", "--step", "5"]).0 == 64) // more than the declared 4
        #expect(h.run(["task", "progress", "api/schema", "--step", "2"]).0 == 64) // no total declared
        #expect(h.run(["task", "progress", "api/schema", "--step", "2/3"]).0 == 0)
        #expect(h.run(["task", "progress", "api/schema", "--step", "3"]).0 == 0)
        #expect(h.fold()?.node("api/schema").steps == TaskSteps(done: 3, total: 3))
    }

    @Test func everyWriteAnswersInAtMostThreeLines() throws {
        let h = seeded()
        let (_, started) = h.run(["task", "start", "api/schema"])
        #expect(started == "started api/schema · run 0% · open: api/schema (running <1m), api/tests (planned), docs (planned)")
        h.now = h.now.addingTimeInterval(31 * 60)
        let (_, done) = h.run(["task", "progress", "api/tests", "--step", "2/4"])
        let lines = done.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("api/tests 2/4 · run ") && lines[0].contains("api/schema (running 31m)"))
        // The task silent for over 20 minutes is named.
        #expect(lines[1] == "api/schema has had no report for 31m: report its progress, or close it if it's finished.")
        // When everything is closed it says so.
        let (_, last) = h.run(["task", "done", "api/schema", "api/tests", "docs"])
        #expect(last == "✓ api/schema, api/tests, docs done · run 100% · nothing open")
        #expect(h.run(["task", "add", "more", "--title", "More", "--quiet"]).1 == "[hr:r1:more]")
    }

    @Test func agentTextIsCleanedAndCapped() throws {
        let h = Home()
        let long = String(repeating: "x", count: 500)
        h.run(["task", "add", "a", "--title", "Line one\nline two\u{1B}[31m red\u{202E}"])
        h.run(["task", "progress", "a", "--note", long])
        h.run(["task", "fail", "a", "--reason", "\u{07}bell\tand tab"])
        let r = try #require(h.fold())
        #expect(r.node("a").title == "Line one line two[31m red")
        #expect(r.node("a").note?.count == TaskText.noteLimit && r.node("a").note?.hasSuffix("…") == true)
        #expect(r.node("a").failure == "bell and tab")
        // Even text written by hand, before cleaning, prints safely.
        try TaskJournal.append([TaskEvent(at: h.now, run: "r1", source: .agent, op: .progress(task: "b", step: nil, total: nil, fraction: nil, note: "a\nb\u{1B}c"))],
                               stream: .journal, home: h.url)
        let out = h.run(["tasks"]).1
        #expect(!out.contains("\u{1B}") && out.contains("a bc"))
        #expect(TaskText.clean(String(repeating: "t", count: 200), limit: TaskText.titleLimit)?.count == 120)
    }

    @Test func planChecksItsInput() throws {
        // A pipe nobody writes to: no hang, a usage error.
        let h = Home()
        var lines: [String] = []
        let silent = CLIInput(readAll: { Issue.record("read a silent pipe"); return Data() }, readLine: { nil }, isPiped: true, isReady: { _ in false })
        let start = Date()
        let code = HeadroomCLI.run(["task", "plan"], environment: ["HEADROOM_RUN": "r1"], output: { lines.append($0) }, home: h.url, input: silent, now: { h.now })
        #expect(code == 64 && Date().timeIntervalSince(start) < 5)
        let tty = CLIInput(readAll: { Data() }, readLine: { nil }, isPiped: false)
        #expect(HeadroomCLI.run(["task", "plan", "-"], environment: ["HEADROOM_RUN": "r1"], output: { _ in }, home: h.url, input: tty, now: { h.now }) == 64)
        // The parser says why.
        do { _ = try JSONSerialization.jsonObject(with: Data("{\"tasks\": [}".utf8)); Issue.record("parsed") } catch {
            #expect(!TaskOps.jsonError(error).isEmpty)
        }
        // Field errors name the task; duplicates are refused; unknown keys are noted.
        func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }
        #expect(throws: TaskOps.Failure.self) { try TaskOps.plan(json(#"{"tasks": [{"id": "api", "children": [{"id": "tests", "effort": "huge"}]}]}"#)) }
        do { _ = try TaskOps.plan(json(#"{"tasks": [{"id": "api", "children": [{"id": "tests", "effort": "huge"}]}]}"#)) } catch {
            #expect(error.message == "plan: task api/tests: bad effort 'huge': use xs, s, m, l, xl or a positive number")
        }
        do { _ = try TaskOps.plan(json(#"{"tasks": [{"id": "a"}, {"id": "b", "children": [{"id": "c"}]}, {"id": "b/c"}]}"#)); Issue.record("accepted a duplicate") } catch {
            #expect(error.message.contains("b/c appears twice"))
        }
        let p = try TaskOps.plan(json(#"{"tasks": [{"id": "a", "name": "A", "subtasks": [{"id": "x"}]}], "owner": "me"}"#))
        #expect(p.warnings == ["ignored \"owner\" in the plan", "ignored \"name\" in task a (use \"title\")", "ignored \"subtasks\" in task a (use \"children\")"])
        let (pc, out) = h.run(["task", "plan"], stdin: #"{"tasks": [{"id": "a", "name": "A"}]}"#)
        #expect(pc == 0 && out.contains("note: ignored \"name\" in task a (use \"title\")"))
        #expect(h.run(["task", "plan"], stdin: #"[{"id": "a"}, {"id": "a"}]"#).0 == 64)
        // A second plan with none of the first one's ids is noted.
        let again = h.run(["task", "plan"], stdin: #"[{"id": "z"}]"#).1
        #expect(again.contains("already had a plan (a)") && again.contains("headroom task cancel a"))
    }

    @Test func statusIsTheCallersRunOnly() throws {
        let h = seeded()
        h.run(["task", "progress", "api/tests", "--step", "1/4", "--note", "first"])
        h.run(["task", "add", "secret", "--title", "Other project's notes"], env: ["HEADROOM_RUN": "elsewhere"])
        h.now = h.now.addingTimeInterval(22 * 60)
        let (code, out) = h.run(["task", "status"])
        #expect(code == 0)
        #expect(out == """
        run r1 "Refactor auth" · 6% · 0 of 3 done
        api       running  0/2
          schema  planned
          tests   running  1/4  22m, no report for 22m
        docs      planned
        """)
        #expect(!out.contains("secret") && !out.contains("elsewhere"))
        #expect(h.run(["task", "status", "--titles"]).1.contains("tests   running  1/4  22m, no report for 22m  \"Tests\""))
        // A finished group is one line.
        h.run(["task", "done", "api/schema", "api/tests"])
        #expect(h.run(["task", "status"]).1.hasSuffix("\napi   done     2/2\ndocs  planned"))
        #expect(Home().run(["task", "status"]).1.contains("nothing reported yet"))
        // `tasks --run` reads just that run.
        let one = h.run(["tasks", "--run", "r1"]).1
        #expect(one.contains("Refactor auth") && !one.contains("Other project"))
    }

    @Test func hooksAndCommandsResolveTheSameRun() {
        let h = Home()
        // HEADROOM_RUN beats the hook payload's session id, as it does for commands.
        h.run(["task", "add", "a", "--title", "A"], env: ["HEADROOM_RUN": "mine"])
        _ = h.run(["task", "hook"], env: ["HEADROOM_RUN": "mine"], stdin: #"{"session_id": "sess", "hook_event_name": "SubagentStart", "agent_id": "x", "agent_type": "Explore"}"#)
        #expect(h.events("mine").contains { if case .attempt = $0.op { true } else { false } })
        #expect(h.events("sess").isEmpty)
        // --run on the hook beats both.
        _ = h.run(["task", "hook", "--run", "flagged"], env: ["HEADROOM_RUN": "mine"], stdin: #"{"session_id": "sess", "hook_event_name": "SubagentStart", "agent_id": "y", "agent_type": "Explore"}"#)
        #expect(!h.events("flagged").isEmpty)
    }

    @Test func adoptPointsASessionAtAnEarlierRun() throws {
        let h = Home()
        h.run(["task", "plan"], env: ["CLAUDE_CODE_SESSION_ID": "old"], stdin: plan)
        let env = ["CLAUDE_CODE_SESSION_ID": "new"]
        #expect(h.run(["task", "adopt", "nope"], env: env).0 == 64)
        #expect(h.run(["task", "adopt", "old"], env: [:]).0 == 64) // no session to link
        let (code, out) = h.run(["task", "adopt", "old"], env: env)
        #expect(code == 0 && out.contains("now reports into run old") && out.contains("run old \"Refactor auth\""))
        #expect(h.run(["task", "start", "api/schema"], env: env).0 == 0)
        #expect(h.fold("old")?.node("api/schema").state == .running)
        // Hooks for the new session follow it.
        _ = h.run(["task", "hook"], env: [:], stdin: #"{"session_id": "new", "hook_event_name": "SubagentStart", "agent_id": "z", "agent_type": "Explore"}"#)
        #expect(h.events("new").isEmpty && h.events("old").contains { if case .attempt = $0.op { true } else { false } })
        // Adopting itself undoes it.
        #expect(h.run(["task", "adopt", "new"], env: env).0 == 0)
        #expect(RunResolver.resolve(flag: nil, environment: env, home: h.url) == "new")
    }

    @Test func sessionStartHandsBackTheTree() throws {
        let h = Home()
        h.run(["task", "plan"], env: ["CLAUDE_CODE_SESSION_ID": "s1", "PWD": "/Users/me/shop"], stdin: plan)
        func start(_ source: String, session: String = "s1") -> String {
            h.run(["task", "hook"], env: [:], stdin: #"{"session_id": "\#(session)", "hook_event_name": "SessionStart", "source": "\#(source)", "cwd": "/Users/me/shop"}"#).1
        }
        #expect(start("startup").isEmpty)
        let out = start("compact")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let specific = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "SessionStart")
        let context = try #require(specific["additionalContext"] as? String)
        #expect(context.contains("run s1 \"Refactor auth\"") && context.contains("  tests") && context.contains("Keep reporting"))
        // A new session after /clear in the same folder is pointed at the unfinished run.
        let cleared = start("clear", session: "s2")
        #expect(cleared.contains("headroom task adopt s1"))
        #expect(start("compact", session: "s2").isEmpty)
        #expect(h.events("s2").isEmpty) // SessionStart never starts a run
    }

    @Test func hooksBeatAndRecordWhereTheSessionRuns() throws {
        let h = Home()
        #expect(HookInstaller.lastEvent(.claudeCode, store: h.url) == nil)
        _ = h.run(["task", "hook"], env: ["__CFBundleIdentifier": "com.googlecode.iterm2"],
                  stdin: #"{"session_id": "s", "cwd": "/Users/me/shop", "hook_event_name": "SubagentStart", "agent_id": "a", "agent_type": "Explore"}"#)
        #expect(HookInstaller.lastEvent(.claudeCode, store: h.url) == h.now)
        #expect(h.events("s").first?.op == .meta(title: nil, project: "shop", harness: "claude-code", host: "com.googlecode.iterm2", cwd: "/Users/me/shop"))
        // The same place again: no new metadata. A new folder: one.
        _ = h.run(["task", "hook"], env: ["__CFBundleIdentifier": "com.googlecode.iterm2"], stdin: #"{"session_id": "s", "cwd": "/Users/me/shop", "hook_event_name": "SessionEnd"}"#)
        #expect(h.events("s").filter { if case .meta = $0.op { true } else { false } }.count == 1)
        _ = h.run(["task", "hook"], env: ["TERM_PROGRAM": "vscode"], stdin: #"{"session_id": "s", "cwd": "/Users/me/shop/web", "hook_event_name": "UserPromptSubmit"}"#)
        #expect(h.events("s").contains { $0.op == .meta(title: nil, project: nil, harness: nil, host: "vscode", cwd: "/Users/me/shop/web") })
        // Codex's beat is its own.
        h.now = h.now.addingTimeInterval(30)
        _ = h.run(["task", "hook", "--harness", "codex"], env: [:], stdin: #"{"session_id": "c", "hook_event_name": "Stop"}"#)
        #expect(HookInstaller.lastEvent(.codex, store: h.url) == h.now)
        // `task plan` records its own host and folder.
        h.run(["task", "plan"], env: ["HEADROOM_RUN": "p", "TERM_PROGRAM": "ghostty", "PWD": "/Users/me/app"], stdin: #"[{"id": "a"}]"#)
        #expect(h.events("p").first?.op == .meta(title: nil, project: "app", harness: nil, host: "ghostty", cwd: "/Users/me/app"))
    }
}

@Suite(.serialized) struct HooksSetupTests {
    func hooks(_ h: Home, _ args: [String], env: [String: String] = [:]) -> (Int32, String) {
        let lines = Lines()
        let code = HooksCommand.run(args, ctx: h.ctx(env: ["HOME": h.url.path, "NO_COLOR": "1"].merging(env) { _, b in b }, out: lines.add), executable: "/Users/me/.local/bin/headroom")
        return (code, lines.all.joined(separator: "\n"))
    }

    @Test func honoursConfigDirectoriesSymlinksAndInstructions() throws {
        let h = Home()
        let fm = FileManager.default
        // CLAUDE_CONFIG_DIR and CODEX_HOME move the default files.
        let conf = h.url.appendingPathComponent("conf")
        #expect(hooks(h, ["install", "--instructions"], env: ["CLAUDE_CONFIG_DIR": conf.path]).0 == 0)
        #expect(fm.fileExists(atPath: conf.appendingPathComponent("settings.json").path))
        #expect(try String(contentsOf: conf.appendingPathComponent("CLAUDE.md"), encoding: .utf8).contains("headroom task guide"))
        let status = hooks(h, ["status"], env: ["CLAUDE_CONFIG_DIR": conf.path]).1
        #expect(status.contains("All 7 installed") && status.contains("Agent instructions: in"))
        #expect(hooks(h, ["uninstall", "--instructions"], env: ["CLAUDE_CONFIG_DIR": conf.path]).1.contains("Removed Headroom's instructions"))
        let codexHome = h.url.appendingPathComponent("cx")
        #expect(hooks(h, ["install", "--codex"], env: ["CODEX_HOME": codexHome.path]).0 == 0)
        #expect(fm.fileExists(atPath: codexHome.appendingPathComponent("hooks.json").path))
        // A symlinked settings file stays a link; the write lands in its target.
        let dotfiles = h.url.appendingPathComponent("dotfiles/claude-settings.json")
        try fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model": "opus"}"#.utf8).write(to: dotfiles)
        let link = h.url.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/claude-settings.json")
        #expect(hooks(h, ["install"]).0 == 0)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/claude-settings.json")
        #expect(try String(contentsOf: dotfiles, encoding: .utf8).contains("task hook"))
        #expect(fm.fileExists(atPath: dotfiles.path + ".headroom-backup"))
    }

    @Test func refusesAHooksValueThatIsNotAnObjectAndWritesOnlyOnChange() throws {
        let h = Home()
        let url = h.url.appendingPathComponent("s/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks": ["say done"]}"#.utf8).write(to: url)
        #expect(hooks(h, ["install", "--settings", url.path]).0 == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"hooks": ["say done"]}"#)
        // Unchanged files are never rewritten, so their formatting survives an uninstall with nothing to do.
        let odd = #"{"b":1,   "a":2}"#
        try Data(odd.utf8).write(to: url)
        #expect(hooks(h, ["uninstall", "--settings", url.path]).1.contains("No Headroom hooks"))
        #expect(try String(contentsOf: url, encoding: .utf8) == odd)
    }
}
