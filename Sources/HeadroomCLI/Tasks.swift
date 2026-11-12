import Foundation
import HeadroomKit

/// The operations `headroom task …` and the MCP server share: options in, events out.
enum TaskOps {
    struct Failure: Error { var message: String }

    static let actions = ["add", "start", "progress", "wait", "done", "fail", "skip", "cancel"]

    /// Events for one action on one task. `options` are flag values without the dashes.
    static func events(action: String, run: String, path: String, options o: [String: String], now: Date) throws(Failure) -> [TaskEvent] {
        guard TaskPath.isValid(path) else {
            throw Failure(message: "bad task id '\(path)': use letters, digits, '.', '_' and '-', with '/' between parts")
        }
        func e(_ op: TaskEvent.Op) -> [TaskEvent] { [TaskEvent(at: now, run: run, source: .agent, op: op)] }
        switch action {
        case "add": return e(.add(try spec(path, o)))
        case "start": return e(.start(task: path))
        case "progress":
            var step: Int?, total: Int?, fraction: Double?
            if let s = o["step"] {
                let parts = s.split(separator: "/", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard (1...2).contains(parts.count), let k = parts[0], k >= 0, parts.count == 1 || (parts[1] ?? 0) > 0 else {
                    throw Failure(message: "bad --step '\(s)': use K or K/N")
                }
                step = k
                total = parts.count == 2 ? parts[1] : nil
            }
            if let f = o["fraction"] {
                guard let v = Double(f), v >= 0, v <= 1 else { throw Failure(message: "bad --fraction '\(f)': use a number from 0 to 1") }
                fraction = v
            }
            return e(.progress(task: path, step: step, total: total, fraction: fraction, note: o["note"]))
        case "wait":
            guard let r = o["for"], let reason = TaskWaitReason(rawValue: r) else { throw Failure(message: "wait needs --for input|dependency|limit") }
            return e(.wait(task: path, attempt: nil, reason: reason, note: o["note"]))
        case "done": return e(.done(task: path, evidence: o["evidence"]))
        case "fail":
            guard let reason = o["reason"], !reason.isEmpty else { throw Failure(message: "fail needs --reason TEXT") }
            return e(.fail(task: path, reason: reason))
        case "skip": return e(.skip(task: path, reason: o["reason"]))
        case "cancel": return e(.cancel(task: path, reason: o["reason"]))
        default: throw Failure(message: "unknown task action '\(action)'")
        }
    }

    static func spec(_ path: String, _ o: [String: String]) throws(Failure) -> TaskEvent.TaskSpec {
        var spec = TaskEvent.TaskSpec(id: path, title: o["title"])
        if let s = o["effort"] {
            guard let w = TaskEffort.parse(s) else { throw Failure(message: "bad --effort '\(s)': use xs, s, m, l, xl or a positive number") }
            spec.effort = w
        }
        if let s = o["importance"] {
            guard let imp = TaskImportance(rawValue: s) else { throw Failure(message: "bad --importance '\(s)': use critical, normal or optional") }
            spec.importance = imp
        }
        if let s = o["steps"] {
            guard let n = Int(s), n > 0 else { throw Failure(message: "bad --steps '\(s)': use a positive whole number") }
            spec.steps = n
        }
        return spec
    }

    /// A plan: `{"title", "project", "tasks": [task]}` or a bare `[task]`, where a task is
    /// `{"id", "title", "effort", "importance", "steps", "children": [task]}`. Child ids are
    /// relative to their parent unless they already start with it.
    static func plan(_ json: Any, now: Date) throws(Failure) -> (title: String?, project: String?, tasks: [TaskEvent.TaskSpec]) {
        var out: [TaskEvent.TaskSpec] = []
        func walk(_ list: Any?, under parent: String?) throws(Failure) {
            guard let list else { return }
            guard let items = list as? [Any] else { throw Failure(message: "plan: tasks must be a list") }
            for item in items {
                guard let obj = item as? [String: Any] else { throw Failure(message: "plan: each task must be an object") }
                guard let raw = string(obj["id"]), !raw.isEmpty else { throw Failure(message: "plan: every task needs an id") }
                let id = parent.map { raw.hasPrefix($0 + "/") ? raw : "\($0)/\(raw)" } ?? raw
                guard TaskPath.isValid(id) else { throw Failure(message: "plan: bad task id '\(id)'") }
                var opts: [String: String] = [:]
                for k in ["title", "effort", "importance", "steps"] { if let v = string(obj[k]) { opts[k] = v } }
                var spec = try spec(id, opts)
                spec.title = spec.title ?? TaskPath.last(id)
                out.append(spec)
                try walk(obj["children"] ?? obj["tasks"], under: id)
            }
        }
        if let obj = json as? [String: Any] {
            try walk(obj["tasks"] ?? obj["children"] ?? [], under: nil)
            return (string(obj["title"]), string(obj["project"]), out)
        }
        try walk(json, under: nil)
        return (nil, nil, out)
    }

    /// JSON scalars as the strings the flag parser would see.
    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): n.boolValue ? "true" : "false"
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    /// The run's metadata, added in front of its first event so every run knows its project and harness.
    static func withMeta(_ events: [TaskEvent], run: String, title: String?, project: String?, ctx: TaskContext) -> [TaskEvent] {
        let first = !FileManager.default.fileExists(atPath: TaskJournal.url(run: run, stream: .journal, home: ctx.home).path)
        guard first || title != nil || project != nil else { return events }
        let pwd = ctx.environment["PWD"].map { URL(fileURLWithPath: $0).lastPathComponent }
        // Only ever the folder's name, even when the caller passes a path.
        let project = project.flatMap { $0.contains("/") ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
        let meta = TaskEvent(at: ctx.now(), run: run, source: .agent,
                             op: .meta(title: title, project: project ?? (first ? pwd : nil), harness: first ? RunResolver.harness(environment: ctx.environment) : nil))
        return [meta] + events
    }
}

/// `headroom task …`
enum TaskCommand {
    static let help = """
    usage: headroom task plan [--run ID] [--title T] [--file PATH | -]
           headroom task add ID --title T [--effort xs|s|m|l|xl|N] [--importance critical|normal|optional] [--steps N]
           headroom task start ID
           headroom task progress ID [--step K[/N]] [--fraction F] [--note TEXT]
           headroom task wait ID --for input|dependency|limit [--note TEXT]
           headroom task done ID [--evidence TEXT]
           headroom task fail ID --reason TEXT
           headroom task skip ID [--reason TEXT]
           headroom task cancel ID
           headroom task guide
           headroom task hook [--enforce] [--harness claude-code|codex]

    Every command takes --run ID; otherwise the id may start with RUN:, else the run comes
    from $HEADROOM_RUN, $CLAUDE_CODE_SESSION_ID, $CODEX_THREAD_ID or $T3CODE_THREAD_ID.
    """

    static func run(_ args: [String], ctx: TaskContext) -> Int32 {
        guard let action = args.first else {
            ctx.output(help)
            return HeadroomCLI.Exit.usage.rawValue
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "--help", "-h", "help":
            ctx.output(help)
            return HeadroomCLI.Exit.ok.rawValue
        case "guide":
            ctx.output(guide(run: RunResolver.resolve(flag: nil, environment: ctx.environment)))
            return HeadroomCLI.Exit.ok.rawValue
        case "hook":
            return HookCommand.run(rest, ctx: ctx)
        case "plan":
            return plan(rest, ctx: ctx)
        case let a where TaskOps.actions.contains(a):
            return single(a, rest, ctx: ctx)
        default:
            ctx.error("headroom task: unknown command '\(action)'")
            ctx.output(help)
            return HeadroomCLI.Exit.usage.rawValue
        }
    }

    static func usage(_ message: String, _ ctx: TaskContext) -> Int32 {
        ctx.error("headroom task: \(message)")
        return HeadroomCLI.Exit.usage.rawValue
    }

    static func single(_ action: String, _ args: [String], ctx: TaskContext) -> Int32 {
        let valued: Set<String> = ["--run", "--title", "--effort", "--importance", "--steps", "--step", "--fraction", "--note", "--for", "--evidence", "--reason"]
        let a: Args
        do { a = try Args(args, valued: valued) } catch { return usage(error.message, ctx) }
        guard a.positional.count == 1, let id = a.positional.first else { return usage("\(action) needs exactly one task id", ctx) }
        guard let (run, path) = RunResolver.resolve(flag: a["--run"], id: id, environment: ctx.environment) else { return usage(RunResolver.missing, ctx) }
        if action == "add", a["--title"]?.isEmpty ?? true { return usage("add needs --title T", ctx) }
        var options: [String: String] = [:]
        for (k, v) in a.values where k != "--run" { options[String(k.dropFirst(2))] = v }
        do {
            let events = try TaskOps.events(action: action, run: run, path: path, options: options, now: ctx.now())
            try ctx.append(TaskOps.withMeta(events, run: run, title: nil, project: nil, ctx: ctx))
        } catch let f as TaskOps.Failure {
            return usage(f.message, ctx)
        } catch {
            ctx.error("headroom task: could not write the journal: \(error.localizedDescription)")
            return HeadroomCLI.Exit.failure.rawValue
        }
        if action == "add" { ctx.output(TaskRef(run: run, path: path).tag) }
        return HeadroomCLI.Exit.ok.rawValue
    }

    static func plan(_ args: [String], ctx: TaskContext) -> Int32 {
        let a: Args
        do { a = try Args(args, valued: ["--run", "--title", "--file"]) } catch { return usage(error.message, ctx) }
        guard let run = RunResolver.resolve(flag: a["--run"], environment: ctx.environment) else { return usage(RunResolver.missing, ctx) }
        let data: Data
        if let file = a["--file"], file != "-" {
            guard let d = FileManager.default.contents(atPath: file) else { return usage("can't read \(file)", ctx) }
            data = d
        } else if a["--file"] == "-" || a.positional == ["-"] || (a.positional.isEmpty && ctx.input.isPiped) {
            data = ctx.input.readAll()
        } else {
            return usage("plan reads a JSON tree from --file PATH or standard input (-)", ctx)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return usage("plan: not valid JSON", ctx) }
        let p: (title: String?, project: String?, tasks: [TaskEvent.TaskSpec])
        do { p = try TaskOps.plan(json, now: ctx.now()) } catch { return usage(error.message, ctx) }
        guard !p.tasks.isEmpty else { return usage("plan: no tasks", ctx) }
        let now = ctx.now()
        let events = p.tasks.map { TaskEvent(at: now, run: run, source: .agent, op: .add($0)) }
        do {
            try ctx.append(TaskOps.withMeta(events, run: run, title: a["--title"] ?? p.title, project: p.project, ctx: ctx))
        } catch {
            ctx.error("headroom task: could not write the journal: \(error.localizedDescription)")
            return HeadroomCLI.Exit.failure.rawValue
        }
        ctx.output("Declared \(p.tasks.count) task\(p.tasks.count == 1 ? "" : "s") in run \(run). Put a task's tag in the description of the agent you spawn for it:")
        for t in p.tasks {
            ctx.output(String(repeating: "  ", count: TaskPath.depth(t.id) + 1) + TaskRef(run: run, path: t.id).tag + "  " + (t.title ?? t.id))
        }
        return HeadroomCLI.Exit.ok.rawValue
    }

    static func guide(run: String?) -> String {
        let r = run ?? "RUN"
        return """
        Headroom tracks long runs as a tree of tasks so the user can see progress without asking.
        Run id: \(run.map { "\($0) (from your environment; nothing to pass)" } ?? "pass --run ID, or set HEADROOM_RUN").

        1. Declare the plan once, before starting work. Ids are paths: api/tests is a child of api.
           headroom task plan <<'EOF'
           {"title": "Refactor auth", "tasks": [
             {"id": "api", "title": "API changes", "effort": "l", "importance": "critical", "children": [
               {"id": "schema", "title": "Schema migration", "effort": "s"},
               {"id": "tests", "title": "API tests", "steps": 4}]},
             {"id": "docs", "title": "Docs", "effort": "xs", "importance": "optional"}]}
           EOF
           Effort is relative among siblings (xs s m l xl = 1 2 4 8 16, or a number; default m).
           Importance: critical work failing fails the run; optional work never blocks it.

        2. When you spawn a subagent or delegate for a task, put its tag in the description or
           prompt, e.g. "Write the API tests [hr:\(r):api/tests]". Headroom then shows that agent's
           activity and tokens on the task. Untagged agents still appear, under the task of the agent
           that spawned them.

        3. Report as you go (each is one quick call; nothing is printed):
           headroom task start api/schema
           headroom task progress api/tests --step 2/4 --note "auth cases pass"
           headroom task wait api/tests --for input --note "need the staging token"
           headroom task done api/schema --evidence "migration applied, 12 tests pass"
           headroom task fail docs --reason "generator crashes"      (or skip / cancel)
           Add tasks you discover with: headroom task add api/rate-limit --title "Rate limiting" --effort s

        4. Before you stop, give every task you started an outcome: done, fail, skip or cancel.

        5. If your own prompt carries a tag such as [hr:7f3a:api/tests], you are working on that
           task in someone else's run. Use the full id from the tag in every call:
           headroom task progress 7f3a:api/tests --step 1/3
           headroom task add 7f3a:api/tests/fixtures --title "Fixtures" --effort s
           headroom task done 7f3a:api/tests --evidence "42 tests pass"

        See the tree with: headroom tasks
        """
    }
}

/// `headroom tasks`
enum TasksCommand {
    /// `keepWatching` sees each frame drawn and says whether to draw another.
    static func run(_ args: [String], ctx: TaskContext, keepWatching: (String) -> Bool = { _ in true }) -> Int32 {
        let a: Args
        do { a = try Args(args, valued: ["--run"], flags: ["--all", "--json", "--watch"]) } catch {
            ctx.error("headroom tasks: \(error.message)")
            return HeadroomCLI.Exit.usage.rawValue
        }
        guard a.positional.isEmpty else {
            ctx.error("headroom tasks: unexpected '\(a.positional[0])'")
            return HeadroomCLI.Exit.usage.rawValue
        }
        let only = a["--run"].flatMap(TaskRunID.sanitize)
        let store = TaskStore(home: ctx.home)
        while true {
            let now = ctx.now()
            var loaded = store.load(now: now, all: a.has("--all") || only != nil)
            if let only { loaded.runs = loaded.runs.filter { $0.id == only } }
            let frame: String
            if a.has("--json") {
                let feed = TasksFeed(generatedAt: now, writerPID: 0, runs: loaded.runs)
                frame = (try? TasksFile.encoder(pretty: true).encode(feed)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            } else {
                let text = TaskRender.render(loaded.runs, style: ctx.style, now: now, live: loaded.live, all: a.has("--all") || only != nil)
                frame = a.has("--watch") && ctx.style.colors ? "\u{1B}[H\u{1B}[2J" + text : text
            }
            ctx.output(frame)
            guard a.has("--watch"), keepWatching(frame) else { return HeadroomCLI.Exit.ok.rawValue }
            // A minute at most, so ages, stale marks and the forecast stay current.
            TaskWatch.wait(home: ctx.home, runs: loaded.runs.map(\.id), timeout: 60)
        }
    }
}

/// `headroom wait --run ID`: blocks until the run finishes, or with `--until attention` also
/// until it needs a person or stops. Zero CPU while waiting.
enum RunWaitCommand {
    static func run(_ args: [String], ctx: TaskContext) -> Int32 {
        let a: Args
        do { a = try Args(args, valued: ["--run", "--until", "--timeout"], flags: ["--json"]) } catch {
            ctx.output("headroom wait: \(error.message)")
            return HeadroomCLI.Exit.usage.rawValue
        }
        guard let run = a["--run"].flatMap(TaskRunID.sanitize) else {
            ctx.output("headroom wait: --run needs a run id")
            return HeadroomCLI.Exit.usage.rawValue
        }
        let until = a["--until"] ?? "done"
        guard until == "done" || until == "attention" else {
            ctx.output("headroom wait: --until must be done or attention")
            return HeadroomCLI.Exit.usage.rawValue
        }
        guard let timeout = WaitCommand.parseDuration(a["--timeout"] ?? "6h") else {
            ctx.output("headroom wait: bad --timeout (use e.g. 90s, 45m, 6h, 2d)")
            return HeadroomCLI.Exit.usage.rawValue
        }
        let json = a.has("--json")
        let deadline = ctx.now().addingTimeInterval(timeout)
        let store = TaskStore(home: ctx.home)
        var announced = false
        func report(_ r: TaskRun?, timedOut: Bool) {
            if json {
                var obj: [String: Any] = ["run": run, "state": r?.state.rawValue ?? NSNull(), "wait_reason": r?.waitReason?.rawValue ?? NSNull(), "timed_out": timedOut]
                if let r { obj["done"] = r.progress.done }
                ctx.output((try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            } else if let r {
                ctx.output((timedOut ? "⏱ timed out · " : "▶ ") + TaskRender.summary(r, style: ctx.style))
            } else {
                ctx.output("⏱ timed out · no events for run \(run)")
            }
        }
        while true {
            let r = store.run(run, now: ctx.now())
            if let r, r.state.isTerminal || (until == "attention" && (r.state == .stopped || r.needsInput)) {
                report(r, timedOut: false)
                return HeadroomCLI.Exit.ok.rawValue
            }
            if !announced && !json {
                announced = true
                ctx.output(ctx.style.dim("⏸ waiting on run \(r?.title ?? run)" + (until == "attention" ? " (until it needs you)" : "")))
            }
            let left = deadline.timeIntervalSince(ctx.now())
            if left <= 0 {
                report(r, timedOut: true)
                return HeadroomCLI.Exit.timeout.rawValue
            }
            TaskWatch.wait(home: ctx.home, runs: [run], timeout: left)
        }
    }
}
