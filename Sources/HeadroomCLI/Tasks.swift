import Foundation
import HeadroomKit

/// The operations `headroom task …` and the MCP server share: options in, checked against the
/// run as it stands, events out, and a line back.
enum TaskOps {
    struct Failure: Error {
        var message: String
        /// The journal couldn't be written (exit 1), rather than a usage mistake (exit 64).
        var io = false
        init(_ message: String, io: Bool = false) { self.message = message; self.io = io }
    }

    static let actions = ["add", "start", "progress", "wait", "done", "fail", "skip", "cancel"]
    static let closing: Set<String> = ["done", "fail", "skip", "cancel"]
    /// Actions that take several ids at once.
    static let multiID: Set<String> = ["start", "done", "fail", "skip", "cancel"]

    /// The options each action takes, without dashes. Every action also takes `run` and `quiet`.
    static let options: [String: [String]] = [
        "add": ["title", "effort", "importance", "steps"],
        "start": [],
        "progress": ["step", "fraction", "note"],
        "wait": ["for", "note", "option"],
        "done": ["evidence", "force"],
        "fail": ["reason", "force", "instead"],
        "skip": ["reason", "force"],
        "cancel": ["reason", "force"],
    ]

    static let usage: [String: String] = [
        "add": "add ID --title T [--effort xs|s|m|l|xl|N] [--importance critical|normal|optional] [--steps N]",
        "start": "start ID [ID …]",
        "progress": "progress ID [--step K/N] [--fraction F] [--note TEXT]",
        "wait": "wait ID --for input|dependency|limit [--note TEXT] [--option ANSWER …]",
        "done": "done ID [ID …] [--evidence TEXT] [--force]",
        "fail": "fail ID [ID …] --reason TEXT [--instead NEW] [--force]",
        "skip": "skip ID [ID …] [--reason TEXT] [--force]",
        "cancel": "cancel ID [ID …] [--reason TEXT] [--force]",
    ]

    static let about: [String: String] = [
        "add": "Declares a task you discovered, or changes a declared one's title, effort, importance or steps. A new task needs --title. Effort is relative among siblings: xs s m l xl (1 2 4 8 16) or a number.",
        "start": "Marks tasks as being worked on.",
        "progress": "Reports how far a task has got: --step K/N (K of N steps done; K alone once N is known), --fraction F (0 to 1), --note TEXT (up to 400 characters).",
        "wait": "Marks a task as blocked on a person (input), another task (dependency) or a usage limit (limit). --option offers an answer the user can pick; repeat it for each.",
        "done": "Closes tasks as finished. --evidence says what shows it: tests passing, a commit, a URL.",
        "fail": "Closes tasks you tried and couldn't finish. --reason is required. --instead NEW names the task taking over (another way to the same end), so the run isn't marked failed while NEW goes on.",
        "skip": "Closes tasks you decided aren't needed.",
        "cancel": "Closes tasks dropped because the plan changed.",
    ]

    /// The flags an action takes, for error messages.
    static func takes(_ action: String) -> String {
        ((options[action] ?? []).map { "--\($0)" } + ["--run", "--quiet"]).joined(separator: ", ")
    }

    static func badID(_ id: String) -> Failure {
        Failure("bad task id '\(TaskText.display(id, limit: 60))': use letters, digits, '.', '_' and '-', with '/' between parts (api/tests)")
    }

    // MARK: One event

    /// The event for one action on one task. `o` holds flag values without the dashes.
    static func event(action: String, run: String, path: String, options o: [String: String], answers: [String] = [], now: Date) throws(Failure) -> TaskEvent {
        func e(_ op: TaskEvent.Op) -> TaskEvent { TaskEvent(at: now, run: run, source: .agent, op: op) }
        switch action {
        case "add": return e(.add(try spec(path, o)))
        case "start": return e(.start(task: path))
        case "progress":
            let (step, total) = try steps(o["step"])
            var fraction: Double?
            if let f = o["fraction"] {
                guard let v = Double(f), v >= 0, v <= 1 else { throw Failure("bad --fraction '\(f)': use a number from 0 to 1, e.g. 0.4") }
                fraction = v
            }
            return e(.progress(task: path, step: step, total: total, fraction: fraction, note: TaskText.note(o["note"])))
        case "wait":
            guard let r = o["for"], let reason = TaskWaitReason(rawValue: r) else {
                throw Failure("wait needs --for input (a person), dependency (another task) or limit (a usage limit)")
            }
            let offered = answers.compactMap(TaskText.title)
            return e(.wait(task: path, attempt: nil, reason: reason, note: TaskText.note(o["note"]), options: offered.isEmpty ? nil : offered))
        case "done": return e(.done(task: path, evidence: TaskText.note(o["evidence"])))
        case "fail":
            guard let reason = TaskText.note(o["reason"]) else { throw Failure("fail needs --reason TEXT: say what went wrong") }
            var instead: String?
            if let next = o["instead"] {
                guard TaskPath.isValid(next), next != path else {
                    throw Failure("bad --instead '\(TaskText.display(next, limit: 60))': name the task taking over, e.g. --instead api/fallback")
                }
                instead = next
            }
            return e(.fail(task: path, reason: reason, instead: instead))
        case "skip": return e(.skip(task: path, reason: TaskText.note(o["reason"])))
        case "cancel": return e(.cancel(task: path, reason: TaskText.note(o["reason"])))
        default: throw Failure("unknown task action '\(action)'")
        }
    }

    /// `K` or `K/N`, with K ≤ N.
    static func steps(_ s: String?) throws(Failure) -> (Int?, Int?) {
        guard let s else { return (nil, nil) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), let k = parts[0], k >= 0, parts.count == 1 || (parts[1] ?? 0) > 0 else {
            throw Failure("bad --step '\(s)': use K/N, K steps done of N, e.g. --step 2/4")
        }
        let n = parts.count == 2 ? parts[1] : nil
        if let n, k > n { throw Failure("bad --step '\(s)': K can't be more than N. Pass the new total if the task grew, e.g. --step \(k)/\(k + 1)") }
        return (k, n)
    }

    /// A task's fields. `plan` names the field the way the plan JSON does, and the task.
    static func spec(_ path: String, _ o: [String: String], plan: Bool = false) throws(Failure) -> TaskEvent.TaskSpec {
        func bad(_ field: String, _ value: String, _ fix: String) -> Failure {
            plan ? Failure("plan: task \(path): bad \(field) '\(value)': \(fix)") : Failure("bad --\(field) '\(value)': \(fix)")
        }
        var spec = TaskEvent.TaskSpec(id: path, title: TaskText.title(o["title"]))
        if let s = o["effort"] {
            guard let w = TaskEffort.parse(s) else { throw bad("effort", s, "use xs, s, m, l, xl or a positive number") }
            spec.effort = w
        }
        if let s = o["importance"] {
            guard let imp = TaskImportance(rawValue: s) else { throw bad("importance", s, "use critical, normal or optional") }
            spec.importance = imp
        }
        if let s = o["steps"] {
            guard let n = Int(s), n > 0 else { throw bad("steps", s, "use a positive whole number") }
            spec.steps = n
        }
        return spec
    }

    // MARK: A report

    struct Request {
        var action: String
        var ids: [String]
        var options: [String: String] = [:]
        /// `wait --option`: answers offered.
        var answers: [String] = []
        var force = false
        /// `--run`.
        var run: String?
    }

    struct Outcome {
        var run: String
        /// `add`: the new task's tag.
        var tags: [String]
        /// The echo: at most three lines.
        var lines: [String]
    }

    /// Checks the request against the run, appends its events and folds the run for the echo.
    static func apply(_ q: Request, ctx: TaskContext) throws(Failure) -> Outcome {
        let now = ctx.now()
        guard !q.ids.isEmpty else { throw Failure("\(q.action) needs a task id. Usage: headroom task \(usage[q.action] ?? q.action)") }
        if q.ids.count > 1, !multiID.contains(q.action) {
            throw Failure("\(q.action) takes one task id (\(q.ids.count) given); only \(multiID.sorted().joined(separator: ", ")) take several")
        }
        let explicit = q.run.flatMap { $0.isEmpty ? nil : $0 }
        let current = RunResolver.resolve(flag: explicit, environment: ctx.environment, home: ctx.home)
        if let explicit, current == nil { throw Failure("bad --run '\(explicit)': use letters, digits, '.', '_' and '-'") }
        var run: String?
        var paths: [String] = []
        for id in q.ids {
            let (r, p) = try target(id, explicit: explicit != nil, current: current, home: ctx.home)
            if let run, run != r { throw Failure("one call reports on one run, but these ids name \(run) and \(r): make one call per run") }
            run = r
            guard TaskPath.isValid(p) else { throw badID(p) }
            if !paths.contains(p) { paths.append(p) }
        }
        let runID = run!
        let before = TaskJournal.read(run: runID, home: ctx.home)
        let folded = before.isEmpty ? nil : TaskFold.fold(before, now: now).first
        try check(q, paths: paths, run: runID, events: before, folded: folded)
        // Children first, so each keeps its own outcome when a parent closes in the same call.
        let ordered = closing.contains(q.action)
            ? paths.enumerated().sorted { (-TaskPath.depth($0.element), $0.offset) < (-TaskPath.depth($1.element), $1.offset) }.map(\.element) : paths
        var events: [TaskEvent] = []
        for p in ordered { events.append(try event(action: q.action, run: runID, path: p, options: q.options, answers: q.answers, now: now)) }
        let written = withMeta(events, run: runID, title: nil, project: nil, ctx: ctx, existing: before)
        do { try ctx.append(written) } catch { throw Failure("could not write the journal: \(error.localizedDescription)", io: true) }
        guard let after = TaskFold.fold(before + written, now: now).first else { return Outcome(run: runID, tags: [], lines: []) }
        let known = Set(folded?.nodes.map(\.id) ?? [])
        let tags = q.action == "add" ? paths.map { TaskRef(run: runID, path: $0).tag } : []
        return Outcome(run: runID, tags: tags,
                       lines: TaskEcho.lines(changed: changed(q, paths: paths, after: after, known: known), touched: Set(paths), run: after, ctx: ctx))
    }

    /// The run and path an id names. A `RUN:` prefix must name a run that exists, or this one.
    static func target(_ id: String, explicit: Bool, current: String?, home: URL) throws(Failure) -> (String, String) {
        if explicit, let current { return (current, TaskRef(id)?.path ?? id) }
        if let ref = TaskRef(id) {
            guard ref.run == current || RunResolver.exists(ref.run, home: home) else {
                throw Failure("no run '\(ref.run)' (from the '\(ref.run):' in \(id)). Task ids use '/' between parts, e.g. \(ref.run)/\(ref.path); "
                              + "a RUN: prefix is only for the run in a [hr:RUN:PATH] tag")
            }
            return (ref.run, ref.path)
        }
        if id.contains(":") { throw badID(id) }
        guard let current else { throw Failure(RunResolver.missing) }
        return (current, id)
    }

    /// Whether the run's journal has a declared plan: a task added by an agent or a person.
    static func hasPlan(_ events: [TaskEvent]) -> Bool {
        events.contains { e in
            guard e.source == .agent || e.source == .user, case .add = e.op else { return false }
            return true
        }
    }

    /// Refuses what would silently do the wrong thing: an unknown id once a plan exists, a new
    /// task with no title, closing a task with open children, a step count with no total.
    static func check(_ q: Request, paths: [String], run: String, events: [TaskEvent], folded: TaskRun?) throws(Failure) {
        let nodes = folded?.nodes ?? []
        let known = Set(nodes.map(\.id))
        if q.action == "add" {
            if let p = paths.first, !known.contains(p), TaskText.title(q.options["title"]) == nil {
                throw Failure("add needs --title T for a new task (\(p) isn't in run \(run) yet)")
            }
            return
        }
        if hasPlan(events), let p = paths.first(where: { !known.contains($0) }) {
            throw unknownTask(p, run: run, nodes: nodes)
        }
        if q.action == "progress", let p = paths.first, let s = q.options["step"], !s.contains("/"), let k = Int(s.trimmingCharacters(in: .whitespaces)) {
            guard let total = nodes.first(where: { $0.id == p })?.steps?.total else {
                throw Failure("\(p) has no step total, so --step \(s) can't say how far it is: pass --step \(s)/N (N steps in all)")
            }
            if k > total { throw Failure("--step \(k) is more than \(p)'s \(total) steps: pass --step \(k)/N with the new total") }
        }
        if closing.contains(q.action), !q.force {
            let set = Set(paths)
            var open: [TaskNode] = []
            for p in paths {
                for n in nodes where n.leaf && !n.state.isTerminal && !TaskPath.isImplicit(n.id) && n.id.hasPrefix(p + "/") && !set.contains(n.id)
                    && !set.contains(where: { $0 != p && $0.hasPrefix(p + "/") && n.id.hasPrefix($0 + "/") }) && !open.contains(where: { $0.id == n.id }) {
                    open.append(n)
                }
            }
            if !open.isEmpty {
                let list = open.prefix(6).map { "\($0.id) (\($0.state.rawValue))" }.joined(separator: ", ") + (open.count > 6 ? " and \(open.count - 6) more" : "")
                let verb = ["done": "done", "fail": "failed", "skip": "skipped", "cancel": "cancelled"][q.action]!
                throw Failure("\(paths.joined(separator: " ")) still has open tasks under it: \(list). Closing it would mark them \(verb) too. "
                              + "Give each its own outcome first (headroom task done ID …, or fail/skip/cancel), or pass --force to mark them all \(verb).")
            }
        }
    }

    static func unknownTask(_ p: String, run: String, nodes: [TaskNode]) -> Failure {
        let ids = nodes.map(\.id).filter { !TaskPath.isImplicit($0) }
        let near = Fuzzy.closest(p, in: ids)
        var msg = "no task \(p) in run \(run)."
        if !near.isEmpty {
            msg += " Did you mean \(near.joined(separator: " or "))?"
        } else {
            let open = nodes.filter { $0.leaf && !$0.state.isTerminal && !TaskPath.isImplicit($0.id) }.map(\.id)
            if !open.isEmpty { msg += " Open tasks: \(open.prefix(6).joined(separator: ", "))\(open.count > 6 ? " …" : "")." }
        }
        return Failure(msg + " Once a plan exists only plan and add create tasks; to add this one: headroom task add \(p) --title \"…\"")
    }

    /// The first words of the echo.
    static func changed(_ q: Request, paths: [String], after: TaskRun, known: Set<String>) -> String {
        let names = paths.count <= 3 ? paths.joined(separator: ", ") : "\(paths.count) tasks"
        switch q.action {
        case "add": return known.contains(paths[0]) ? "updated" : "added"
        case "start": return "started \(names)"
        case "progress":
            let n = after.nodes.first { $0.id == paths[0] }
            if q.options["step"] != nil, let s = n?.steps { return "\(paths[0]) \(s.done)/\(s.total)" }
            if let f = n?.fraction, q.options["fraction"] != nil { return "\(paths[0]) \(Int((f * 100).rounded()))%" }
            return "\(paths[0]) noted"
        case "wait": return "\(paths[0]) waiting on \(q.options["for"] ?? "dependency")"
        case "done": return "✓ \(names) done"
        case "fail":
            guard let next = q.options["instead"] else { return "✗ \(names) failed" }
            let exists = after.nodes.contains { $0.id == next }
            return "↷ \(names) failed, replaced by \(next)" + (exists ? "" : " (add it: headroom task add \(next) --title …)")
        case "skip": return "⊘ \(names) skipped"
        default: return "⊘ \(names) cancelled"
        }
    }

    // MARK: Plans

    struct Plan {
        var title: String?
        var project: String?
        var tasks: [TaskEvent.TaskSpec]
        /// Keys that were ignored, as sentences.
        var warnings: [String]
    }

    static let taskKeys: Set<String> = ["id", "title", "effort", "importance", "steps", "children", "tasks"]
    static let planKeys: Set<String> = ["title", "project", "tasks", "children"]
    /// What people often write instead.
    static let keyHints = ["subtasks": "children", "items": "children", "name": "title", "label": "title", "weight": "effort", "size": "effort",
                           "priority": "importance", "total": "steps"]

    /// A plan: `{"title", "project", "tasks": [task]}` or a bare `[task]`, where a task is
    /// `{"id", "title", "effort", "importance", "steps", "children": [task]}`. Child ids are
    /// relative to their parent unless they already start with it. Ids must be unique.
    static func plan(_ json: Any) throws(Failure) -> Plan {
        var out: [TaskEvent.TaskSpec] = []
        var seen: Set<String> = []
        var warnings: [String] = []
        func unknown(_ obj: [String: Any], _ allowed: Set<String>, _ place: String) {
            for k in obj.keys.sorted() where !allowed.contains(k) {
                warnings.append("ignored \"\(TaskText.display(k, limit: 40))\" in \(place)" + (keyHints[k].map { " (use \"\($0)\")" } ?? ""))
            }
        }
        func walk(_ list: Any?, under parent: String?) throws(Failure) {
            guard let list else { return }
            guard let items = list as? [Any] else { throw Failure("plan: \(parent.map { "children of \($0)" } ?? "tasks") must be a list") }
            for item in items {
                guard let obj = item as? [String: Any] else { throw Failure("plan: each task must be an object like {\"id\": \"api\", \"title\": \"API\"}") }
                guard let raw = string(obj["id"]), !raw.isEmpty else {
                    let named = string(obj["title"]) ?? string(obj["name"])
                    throw Failure("plan: every task needs an id" + (named.map { " (the one titled \"\(TaskText.display($0, limit: 40))\" has none)" } ?? ""))
                }
                let id = parent.map { raw.hasPrefix($0 + "/") ? raw : "\($0)/\(raw)" } ?? raw
                guard TaskPath.isValid(id) else { throw Failure("plan: " + badID(id).message) }
                guard seen.insert(id).inserted else { throw Failure("plan: task id \(id) appears twice; every id must be unique") }
                unknown(obj, taskKeys, "task \(id)")
                var opts: [String: String] = [:]
                for k in ["title", "effort", "importance", "steps"] { if let v = string(obj[k]) { opts[k] = v } }
                var spec = try spec(id, opts, plan: true)
                spec.title = spec.title ?? TaskPath.last(id)
                out.append(spec)
                try walk(obj["children"] ?? obj["tasks"], under: id)
            }
        }
        if let obj = json as? [String: Any] {
            unknown(obj, planKeys, "the plan")
            try walk(obj["tasks"] ?? obj["children"] ?? [], under: nil)
            return Plan(title: TaskText.title(string(obj["title"])), project: TaskText.title(string(obj["project"])), tasks: out, warnings: warnings)
        }
        try walk(json, under: nil)
        return Plan(title: nil, project: nil, tasks: out, warnings: warnings)
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

    /// The parser's own words for why `data` isn't JSON.
    static func jsonError(_ error: Error) -> String {
        let ns = error as NSError
        let text = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    // MARK: Run metadata

    /// The run's metadata in front of its first event, so every run knows its project, harness,
    /// host app and folder; with `place`, also whenever the host or folder changed.
    static func withMeta(_ events: [TaskEvent], run: String, title: String?, project: String?, ctx: TaskContext, existing: [TaskEvent], place: Bool = false) -> [TaskEvent] {
        let first = !FileManager.default.fileExists(atPath: TaskJournal.url(run: run, stream: .journal, home: ctx.home).path)
        let pwd = ctx.environment["PWD"].flatMap { $0.isEmpty ? nil : $0 }
        let host = RunResolver.host(environment: ctx.environment)
        var h: String?, c: String?
        if first {
            h = host; c = pwd
        } else if place {
            let last = lastPlace(existing)
            if (host != nil && host != last.host) || (pwd != nil && pwd != last.cwd) { h = host; c = pwd }
        }
        guard first || title != nil || project != nil || h != nil || c != nil else { return events }
        // Only ever the folder's name, even when the caller passes a path.
        let project = project.flatMap { $0.contains("/") ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
        let meta = TaskEvent(at: ctx.now(), run: run, source: .agent,
                             op: .meta(title: title, project: project ?? (first ? pwd.map { URL(fileURLWithPath: $0).lastPathComponent } : nil),
                                       harness: first ? RunResolver.harness(environment: ctx.environment) : nil, host: h, cwd: c))
        return [meta] + events
    }

    /// The latest `host` and `cwd` the run's metadata recorded.
    static func lastPlace(_ events: [TaskEvent]) -> (host: String?, cwd: String?) {
        var host: String?, cwd: String?
        for e in events {
            if case .meta(_, _, _, let h, let c) = e.op {
                if let h { host = h }
                if let c { cwd = c }
            }
        }
        return (host, cwd)
    }
}

/// `headroom task …`
enum TaskCommand {
    static let help = """
    usage: headroom task plan [--run ID] [--title T] [--file PATH | -]
           headroom task add ID --title T [--effort xs|s|m|l|xl|N] [--importance critical|normal|optional] [--steps N]
           headroom task start ID [ID …]
           headroom task progress ID [--step K/N] [--fraction F] [--note TEXT]
           headroom task wait ID --for input|dependency|limit [--note TEXT] [--option ANSWER …]
           headroom task done ID [ID …] [--evidence TEXT] [--force]
           headroom task fail ID [ID …] --reason TEXT [--force]
           headroom task skip|cancel ID [ID …] [--reason TEXT] [--force]
           headroom task status [--titles]
           headroom task guide
           headroom task adopt RUN
           headroom task hook [--enforce] [--harness claude-code|codex]

    Every report prints a line back: what changed, the run's percent and what is still open
    (--quiet prints nothing). Flags take --flag VALUE or --flag=VALUE.
    The run: --run ID, else $HEADROOM_RUN, else this session ($CLAUDE_CODE_SESSION_ID,
    $CODEX_THREAD_ID, $T3CODE_THREAD_ID). An id may start with RUN: from a [hr:RUN:PATH] tag.
    `headroom task ACTION --help` explains one action.
    """

    static let ok = HeadroomCLI.Exit.ok.rawValue

    static func run(_ args: [String], ctx: TaskContext) -> Int32 {
        guard let action = args.first else {
            ctx.output(help)
            return HeadroomCLI.Exit.usage.rawValue
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "--help", "-h", "help":
            ctx.output(help)
            return ok
        case "guide": return guide(rest, ctx: ctx)
        case "status": return status(rest, ctx: ctx)
        case "adopt": return adopt(rest, ctx: ctx)
        case "hook": return HookCommand.run(rest, ctx: ctx)
        case "plan": return plan(rest, ctx: ctx)
        case let a where TaskOps.actions.contains(a): return report(a, rest, ctx: ctx)
        default:
            let near = Fuzzy.closest(action, in: TaskOps.actions + ["plan", "status", "guide", "adopt"], limit: 1)
            ctx.error("headroom task: unknown command '\(TaskText.display(action, limit: 40))'" + (near.first.map { ". Did you mean \($0)?" } ?? ""))
            ctx.output(help)
            return HeadroomCLI.Exit.usage.rawValue
        }
    }

    static func usage(_ message: String, _ ctx: TaskContext) -> Int32 {
        ctx.error("headroom task: \(message)")
        return HeadroomCLI.Exit.usage.rawValue
    }

    static func actionHelp(_ action: String) -> String {
        var text = "usage: headroom task \(TaskOps.usage[action] ?? action) [--run ID] [--quiet]\n\n\(TaskOps.about[action] ?? "")"
        if TaskOps.closing.contains(action) {
            text += "\nA task with open tasks under it isn't closed unless you pass --force, which closes them the same way."
        }
        if TaskOps.multiID.contains(action) { text += "\nTakes several ids at once: headroom task \(action) a b c." }
        return text + "\nPrints one line back: what changed, the run's percent and what is still open (--quiet: nothing)."
    }

    /// `start|progress|wait|done|fail|skip|cancel|add`.
    static func report(_ action: String, _ args: [String], ctx: TaskContext) -> Int32 {
        let allowed = TaskOps.options[action] ?? []
        let valued = Set(["--run"] + allowed.filter { $0 != "force" && $0 != "option" }.map { "--\($0)" })
        var flags: Set<String> = ["--quiet", "--help", "-h"]
        if allowed.contains("force") { flags.insert("--force") }
        let a: Args
        do { a = try Args(args, valued: valued, flags: flags, repeated: allowed.contains("option") ? ["--option"] : []) } catch {
            return usage("\(action): \(error.message). \(action) takes \(TaskOps.takes(action)). Usage: headroom task \(TaskOps.usage[action] ?? action)", ctx)
        }
        if a.has("--help") || a.has("-h") {
            ctx.output(actionHelp(action))
            return ok
        }
        var options: [String: String] = [:]
        for (k, v) in a.values where k != "--run" { options[String(k.dropFirst(2))] = v }
        let q = TaskOps.Request(action: action, ids: a.positional, options: options, answers: a.lists["--option"] ?? [], force: a.has("--force"), run: a["--run"])
        let out: TaskOps.Outcome
        do { out = try TaskOps.apply(q, ctx: ctx) } catch {
            if error.io {
                ctx.error("headroom task: \(error.message)")
                return HeadroomCLI.Exit.failure.rawValue
            }
            return usage(error.message, ctx)
        }
        if a.has("--quiet") {
            out.tags.forEach(ctx.output)
        } else {
            for (i, line) in out.lines.enumerated() { ctx.output(i == 0 && !out.tags.isEmpty ? out.tags.joined(separator: " ") + " " + line : line) }
        }
        return ok
    }

    static let planHelp = """
    usage: headroom task plan [--run ID] [--title T] [--file PATH | -] [--quiet]

    Declares the run's tasks from a JSON tree on standard input (or --file PATH) and prints each
    task's tag. Child ids are relative to their parent; ids must be unique.
      headroom task plan <<'EOF'
      {"title": "Refactor auth", "tasks": [
        {"id": "api", "title": "API changes", "effort": "l", "importance": "critical", "children": [
          {"id": "schema", "title": "Schema migration", "effort": "s"},
          {"id": "tests", "title": "API tests", "steps": 4}]},
        {"id": "docs", "title": "Docs", "effort": "xs", "importance": "optional"}]}
      EOF
    Task keys: id, title, effort (xs s m l xl or a number), importance (critical, normal,
    optional), steps (a count), children.
    """

    static func plan(_ args: [String], ctx: TaskContext) -> Int32 {
        let a: Args
        do { a = try Args(args, valued: ["--run", "--title", "--file"], flags: ["--quiet", "--help", "-h"]) } catch {
            return usage("plan: \(error.message). Usage: headroom task plan [--run ID] [--title T] [--file PATH | -]", ctx)
        }
        if a.has("--help") || a.has("-h") {
            ctx.output(planHelp)
            return ok
        }
        guard a.positional.isEmpty || a.positional == ["-"] else { return usage("plan takes no ids: it reads the whole tree as JSON. See headroom task plan --help", ctx) }
        guard let run = RunResolver.resolve(flag: a["--run"], environment: ctx.environment, home: ctx.home) else { return usage(RunResolver.missing, ctx) }
        let data: Data
        if let file = a["--file"], file != "-" {
            guard let d = FileManager.default.contents(atPath: file) else { return usage("plan: can't read \(file)", ctx) }
            data = d
        } else {
            let asked = a["--file"] == "-" || a.positional == ["-"]
            guard ctx.input.isPiped else {
                return usage("plan reads a JSON tree from standard input, but it's a terminal: pipe it in (headroom task plan <<'EOF' … EOF) or pass --file PATH", ctx)
            }
            // A pipe nobody writes to would block for ever: wait a moment, then say so.
            guard let d = ctx.input.readPiped(timeout: asked ? 2000 : 500) else {
                return usage("plan: nothing arrived on standard input. Pipe the JSON tree in (headroom task plan <<'EOF' … EOF) or pass --file PATH; headroom task plan --help shows the format", ctx)
            }
            data = d
        }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch {
            return usage("plan: not valid JSON: \(TaskOps.jsonError(error)). headroom task plan --help shows the format", ctx)
        }
        let p: TaskOps.Plan
        do { p = try TaskOps.plan(json) } catch { return usage(error.message, ctx) }
        guard !p.tasks.isEmpty else { return usage("plan: no tasks. Give a list under \"tasks\"; headroom task plan --help shows the format", ctx) }
        let now = ctx.now()
        let before = TaskJournal.read(run: run, home: ctx.home)
        var warnings = p.warnings
        if TaskOps.hasPlan(before), let earlier = TaskFold.fold(before, now: now).first {
            let old = earlier.nodes.filter { $0.declared && !TaskPath.isImplicit($0.id) }.map(\.id)
            if !old.isEmpty, Set(old).isDisjoint(with: p.tasks.map(\.id)) {
                let open = TaskEcho.open(earlier).map(\.id)
                warnings.append("run \(run) already had a plan (\(old.prefix(4).joined(separator: ", "))\(old.count > 4 ? " …" : "")); these tasks were added beside it."
                                + (open.isEmpty ? "" : " If they replace it, cancel the old ones: headroom task cancel \(open.prefix(6).joined(separator: " "))"))
            }
        }
        let events = p.tasks.map { TaskEvent(at: now, run: run, source: .agent, op: .add($0)) }
        let written = TaskOps.withMeta(events, run: run, title: TaskText.title(a["--title"]) ?? p.title, project: p.project, ctx: ctx, existing: before, place: true)
        do { try ctx.append(written) } catch {
            ctx.error("headroom task: could not write the journal: \(error.localizedDescription)")
            return HeadroomCLI.Exit.failure.rawValue
        }
        ctx.output("Declared \(p.tasks.count) task\(p.tasks.count == 1 ? "" : "s") in run \(run). Put a task's tag in the description of the agent you spawn for it:")
        for t in p.tasks {
            ctx.output(String(repeating: "  ", count: TaskPath.depth(t.id) + 1) + TaskRef(run: run, path: t.id).tag + "  " + (t.title ?? t.id))
        }
        for w in warnings { ctx.output("note: " + w) }
        if !a.has("--quiet"), let r = TaskFold.fold(before + written, now: now).first, let room = TaskEcho.room(r, ctx: ctx) { ctx.output(room) }
        return ok
    }

    /// `headroom task status`: the caller's run, compact, for an agent.
    static func status(_ args: [String], ctx: TaskContext) -> Int32 {
        let a: Args
        do { a = try Args(args, valued: ["--run"], flags: ["--titles", "--help", "-h"]) } catch {
            return usage("status: \(error.message). Usage: headroom task status [--titles] [--run ID]", ctx)
        }
        if a.has("--help") || a.has("-h") {
            ctx.output("usage: headroom task status [--titles] [--run ID]\n\nYour run as a compact tree: one line per task, id, state, steps, and how long it has run or its note. "
                       + "Finished groups are one line. --titles adds each task's title. Use it to find your place after a context compaction.")
            return ok
        }
        guard a.positional.isEmpty else { return usage("status takes no ids; it shows the whole run. Usage: headroom task status [--titles]", ctx) }
        guard let run = RunResolver.resolve(flag: a["--run"], environment: ctx.environment, home: ctx.home) else { return usage(RunResolver.missing, ctx) }
        let now = ctx.now()
        guard let r = TaskFold.fold(TaskJournal.read(run: run, home: ctx.home), now: now).first else {
            ctx.output("run \(run): nothing reported yet. For work with 3 or more steps, declare a plan: headroom task guide explains how.")
            return ok
        }
        TaskEcho.status(r, now: now, titles: a.has("--titles")).forEach(ctx.output)
        return ok
    }

    /// `headroom task adopt RUN`: this harness session reports into an earlier run, after a
    /// resume or /clear gave it a new session id.
    static func adopt(_ args: [String], ctx: TaskContext) -> Int32 {
        let a: Args
        do { a = try Args(args, flags: ["--help", "-h"]) } catch { return usage("adopt: \(error.message). Usage: headroom task adopt RUN", ctx) }
        if a.has("--help") || a.has("-h") {
            ctx.output("usage: headroom task adopt RUN\n\nMakes this session report into an earlier run (after a resume or /clear started a new session id). "
                       + "Task commands and hooks then use RUN. headroom task adopt with this session's own id undoes it.")
            return ok
        }
        guard a.positional.count == 1, let target = TaskRunID.sanitize(a.positional[0]) else { return usage("adopt needs one run id. Usage: headroom task adopt RUN", ctx) }
        guard let session = RunResolver.harnessSession(environment: ctx.environment) else {
            return usage("adopt links this harness session to a run, but no session id is set ($CLAUDE_CODE_SESSION_ID, $CODEX_THREAD_ID, $T3CODE_THREAD_ID). Pass --run \(target) on each command instead", ctx)
        }
        let url = RunResolver.aliasURL(session: session, home: ctx.home)
        if target == session {
            try? FileManager.default.removeItem(at: url)
            ctx.output("This session reports into its own run, \(session), again.")
            return ok
        }
        guard RunResolver.exists(target, home: ctx.home) else { return usage("no run \(target): nothing was ever reported to it. Check the id (headroom tasks --all lists runs)", ctx) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data((target + "\n").utf8).write(to: url, options: .atomic)
        } catch {
            ctx.error("headroom task: could not write \(url.path): \(error.localizedDescription)")
            return HeadroomCLI.Exit.failure.rawValue
        }
        var lines = ["This session (\(session)) now reports into run \(target)."]
        if ctx.environment["HEADROOM_RUN"]?.isEmpty == false { lines.append("Note: $HEADROOM_RUN is set and still wins over this.") }
        let now = ctx.now()
        if let r = TaskFold.fold(TaskJournal.read(run: target, home: ctx.home), now: now).first { lines += TaskEcho.status(r, now: now, titles: false) }
        lines.forEach(ctx.output)
        return ok
    }

    static func guide(_ args: [String], ctx: TaskContext) -> Int32 {
        let a: Args
        do { a = try Args(args, valued: ["--run"], flags: ["--help", "-h"]) } catch { return usage("guide: \(error.message)", ctx) }
        ctx.output(guide(run: RunResolver.resolve(flag: a["--run"], environment: ctx.environment, home: ctx.home)))
        return ok
    }

    static func guide(run: String?) -> String {
        let r = run ?? "RUN"
        return """
        Headroom shows the user a long run as a tree of tasks. Reporting is one short command per step.

        First, which are you?
        - Your prompt carries a tag like [hr:7f3a:api/tests]: you are working on that one task in
          someone else's run. Don't declare a plan. Report with the full id from the tag:
            headroom task start 7f3a:api/tests
            headroom task progress 7f3a:api/tests --step 1/3 --note "fixtures done"
            headroom task done 7f3a:api/tests --evidence "42 tests pass"
          Sub-steps go under it: headroom task add 7f3a:api/tests/fixtures --title "Fixtures"
        - Otherwise you are the orchestrator, in run \(run.map { "\($0) (from your environment; nothing to pass)" } ?? "RUN (pass --run ID or set HEADROOM_RUN)").
          For work under 3 steps, skip all of this.

        Orchestrator:
        1. Declare the plan once, before starting. Ids are paths: api/tests is a child of api.
             headroom task plan <<'EOF'
             {"title": "Refactor auth", "tasks": [
               {"id": "api", "title": "API changes", "effort": "l", "importance": "critical", "children": [
                 {"id": "schema", "title": "Schema migration", "effort": "s"},
                 {"id": "tests", "title": "API tests", "steps": 4}]},
               {"id": "docs", "title": "Docs", "effort": "xs", "importance": "optional"}]}
             EOF
           Effort is relative among siblings (xs s m l xl, default m). A critical task failing fails
           the run; an optional one never blocks it. Parents (api) are derived from their
           children: report on the leaves, not on parents.
        2. Delegating a task: put its tag in the agent's description, e.g.
           "Write the API tests [hr:\(r):api/tests]". That agent reports on it; when it returns,
           close the task yourself if it didn't.
        3. Report as you go. Each call answers with the run's percent and what is still open.
             headroom task start api/schema
             headroom task progress api/tests --step 2/4 --note "auth cases pass"
             headroom task done api/schema api/tests --evidence "migration applied, 12 tests pass"
             headroom task wait docs --for input --note "need the staging token"
             headroom task add api/rate-limit --title "Rate limiting" --effort s   (work you find)
        4. Outcomes: done = finished; fail --reason = tried and couldn't; skip = not needed after
           all; cancel = dropped because the plan changed. Worked around a failure another way?
           fail ID --reason … --instead NEW (and add NEW): the run isn't failed while NEW holds.
           Before you stop, give every task an outcome, including ones you never started.
        5. Lost your place (after a context compaction)? headroom task status shows the run.
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
            var loaded: TaskStore.Loaded
            if let only {
                // Just that run: never fold every other run to find it.
                loaded = TaskStore.Loaded(runs: store.run(only, now: now).map { [$0] } ?? [], live: store.live)
            } else {
                loaded = store.load(now: now, all: a.has("--all"))
            }
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
                ctx.output(ctx.style.dim("⏸ waiting on run \(TaskText.display(r?.title ?? run, limit: 80))" + (until == "attention" ? " (until it needs you)" : "")))
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
