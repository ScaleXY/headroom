import Foundation
import HeadroomKit

/// `headroom mcp`: a stdio Model Context Protocol server. Newline-delimited JSON-RPC 2.0 on
/// standard input and output (`initialize`, `notifications/initialized`, `ping`, `tools/list`,
/// `tools/call`). Tools read the allowance and the task runs, and declare and update tasks with
/// the same operations, checks and answers as `headroom task`.
struct MCPServer {
    var ctx: TaskContext
    var snapshotURL: URL

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    func serve() -> Int32 {
        while let line = ctx.input.readLine() {
            if let reply = handle(line) { ctx.output(reply) }
        }
        return HeadroomCLI.Exit.ok.rawValue
    }

    /// The reply to one line, or nil for notifications and blank lines.
    func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        // JSON, but not a request object (a batch, say, which MCP doesn't have).
        guard let msg = json as? [String: Any] else { return error(nil, -32600, "invalid request") }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return id == nil ? nil : error(id, -32600, "invalid request")
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        // Notifications get no reply, known or not.
        guard let id, !(id is NSNull) else { return nil }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return result(id, [
                "protocolVersion": asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[1],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "headroom", "version": HeadroomCLI.version],
                "instructions": "Headroom shows the user how much Claude and Codex allowance is left and what long agent runs are doing. "
                    + "For work with 3 or more steps, read task_guide once, declare a plan with plan_tasks, put each task's tag in the description of the agent you spawn for it, "
                    + "and report with update_task. task_status shows your run after a context compaction.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return error(id, -32602, "unknown tool")
            }
            let (text, failed) = call(name, params["arguments"] as? [String: Any] ?? [:])
            return result(id, ["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return error(id, -32601, "method not found: \(method)")
        }
    }

    // MARK: Tools

    static let runDescription = "Run id. Omit it to use $HEADROOM_RUN, else the session this server was started in, resolved on every call "
        + "(following `headroom task adopt`). After /clear or a resume that session can be stale: pass the run id explicitly (task_status shows it)."

    static var taskProperties: [String: Any] { [
        "id": ["type": "string", "description": "Path id such as api/tests; may start with RUN: (from a [hr:RUN:PATH] tag)"],
        "title": ["type": "string", "description": "Up to 120 characters"],
        "effort": ["type": ["string", "number"], "description": "xs, s, m, l, xl (1, 2, 4, 8, 16) or a positive number; relative to siblings"],
        "importance": ["type": "string", "enum": ["critical", "normal", "optional"]],
        "steps": ["type": "integer", "minimum": 1, "description": "Total steps"],
    ] }

    static var tools: [[String: Any]] { [
        ["name": "get_headroom", "description": "Weekly Claude and Codex allowance left, time to renewal, the 5-hour session and blocks, from Headroom.app's snapshot.",
         "inputSchema": ["type": "object", "properties": [String: Any]()], "annotations": ["readOnlyHint": true]],
        ["name": "get_tasks", "description": "Task runs as a tree with states, progress (done, in flight, estimate), must-haves, ETA and tokens. For your own run, task_status is shorter.",
         "inputSchema": ["type": "object", "properties": ["run": ["type": "string", "description": "Only this run"], "all": ["type": "boolean", "description": "Every run from the last 7 days, not just active ones"]]],
         "annotations": ["readOnlyHint": true]],
        ["name": "task_status", "description": "Your run as a compact tree: one line per task with its id, state, steps, and age or note. Use it to find your place after a context compaction.",
         "inputSchema": ["type": "object", "properties": ["run": ["type": "string", "description": runDescription], "titles": ["type": "boolean", "description": "Add each task's title"]]],
         "annotations": ["readOnlyHint": true]],
        ["name": "task_guide", "description": "How to report progress: whether to plan, how to tag delegated agents, and what each outcome means. Read it once before long multi-step work.",
         "inputSchema": ["type": "object", "properties": ["run": ["type": "string", "description": runDescription]]], "annotations": ["readOnlyHint": true]],
        ["name": "plan_tasks", "description": "Declare the run's tasks at once. Returns each task's tag, [hr:RUN:PATH], to put in the description of the agent spawned for it. Ids must be unique.",
         "inputSchema": ["type": "object", "required": ["tasks"], "properties": [
             "run": ["type": "string", "description": runDescription],
             "title": ["type": "string", "description": "Title for the run"],
             "project": ["type": "string", "description": "The project's folder name"],
             "tasks": ["type": "array", "description": "Tasks; each may have children (ids relative to the parent)",
                       "items": ["type": "object", "required": ["id"], "properties": taskProperties.merging(["children": ["type": "array", "items": ["type": "object"]]]) { a, _ in a }]],
         ]]],
        ["name": "update_task", "description": "Add, start, report progress on, wait on, or close tasks. start, done, fail, skip and cancel take several ids. "
            + "Returns the run's percent and what is still open. Once a plan exists only add creates tasks; a task with open children closes only with force.",
         "inputSchema": ["type": "object", "required": ["action"], "properties": taskProperties.merging([
             "action": ["type": "string", "enum": TaskOps.actions],
             "ids": ["type": "array", "items": ["type": "string"], "description": "Several ids at once, instead of id"],
             "run": ["type": "string", "description": runDescription],
             "step": ["type": ["integer", "string"], "description": "progress: steps done, K/N"],
             "fraction": ["type": "number", "minimum": 0, "maximum": 1, "description": "progress: how far, 0 to 1"],
             "note": ["type": "string", "description": "progress, wait: up to 400 characters"],
             "for": ["type": "string", "enum": ["input", "dependency", "limit"], "description": "wait: what it waits for"],
             "options": ["type": "array", "items": ["type": "string"], "description": "wait: answers the user can pick"],
             "evidence": ["type": "string", "description": "done: what shows it is done"],
             "reason": ["type": "string", "description": "fail (required), skip, cancel: why"],
             "instead": ["type": "string", "description": "fail: the task taking over (another way to the same end); the run isn't failed while it holds"],
             "force": ["type": "boolean", "description": "done, fail, skip, cancel: also close open tasks under it the same way"],
         ]) { a, _ in a }]],
    ] }

    /// The run for a call: the argument, else the environment and any adoption, read now.
    func run(_ args: [String: Any]) -> String? {
        RunResolver.resolve(flag: args["run"] as? String, environment: ctx.environment, home: ctx.home)
    }

    func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let now = ctx.now()
        switch name {
        case "get_headroom":
            guard let s = SnapshotFile.read(from: snapshotURL) else { return ("Headroom has not written a snapshot yet. Is the app running?", true) }
            return (HeadroomCLI.jsonOutput(s, now: now), false)
        case "get_tasks":
            let only = (args["run"] as? String).flatMap(TaskRunID.sanitize)
            let store = TaskStore(home: ctx.home)
            let runs = only.map { store.run($0, now: now).map { [$0] } ?? [] } ?? store.load(now: now, all: args["all"] as? Bool == true).runs
            let feed = TasksFeed(generatedAt: now, writerPID: 0, runs: runs)
            return ((try? TasksFile.encoder(pretty: true).encode(feed)).map { String(decoding: $0, as: UTF8.self) } ?? "{}", false)
        case "task_status":
            guard let run = run(args) else { return (RunResolver.missing, true) }
            guard let r = TaskFold.fold(TaskJournal.read(run: run, home: ctx.home), now: now).first else {
                return ("run \(run): nothing reported yet. For work with 3 or more steps, declare a plan (task_guide explains how).", false)
            }
            return (TaskEcho.status(r, now: now, titles: args["titles"] as? Bool == true).joined(separator: "\n"), false)
        case "task_guide":
            return (TaskCommand.guide(run: run(args)), false)
        case "plan_tasks":
            guard let run = run(args) else { return (RunResolver.missing, true) }
            do {
                let p = try TaskOps.plan(["tasks": args["tasks"] ?? []])
                guard !p.tasks.isEmpty else { return ("No tasks given.", true) }
                let before = TaskJournal.read(run: run, home: ctx.home)
                let events = p.tasks.map { TaskEvent(at: now, run: run, source: .agent, op: .add($0)) }
                let written = TaskOps.withMeta(events, run: run, title: TaskText.title(args["title"] as? String), project: TaskText.title(args["project"] as? String),
                                               ctx: ctx, existing: before, place: true)
                try ctx.append(written)
                var lines = ["Declared \(p.tasks.count) tasks in run \(run):"] + p.tasks.map { "\(TaskRef(run: run, path: $0.id).tag)  \($0.title ?? TaskPath.last($0.id))" }
                lines += p.warnings.map { "note: " + $0 }
                if let r = TaskFold.fold(before + written, now: now).first, let room = TaskEcho.room(r, ctx: ctx) { lines.append(room) }
                return (lines.joined(separator: "\n"), false)
            } catch let f as TaskOps.Failure {
                return (f.message, true)
            } catch {
                return ("Could not write the journal: \(error.localizedDescription)", true)
            }
        default:
            guard let action = args["action"] as? String, TaskOps.actions.contains(action) else {
                return ("update_task needs action: one of \(TaskOps.actions.joined(separator: ", "))", true)
            }
            // An empty `ids` beside an `id` (callers fill unused lists with []) means the `id`.
            let listed = (args["ids"] as? [Any])?.compactMap(TaskOps.string) ?? []
            let ids = listed.isEmpty ? (args["id"].flatMap(TaskOps.string).map { [$0] } ?? []) : listed
            guard !ids.isEmpty else { return ("update_task needs id (or ids)", true) }
            let allowed = TaskOps.options[action] ?? []
            // The same per-action options as the command line: nothing silently dropped.
            let given = ["title", "effort", "importance", "steps", "step", "fraction", "note", "for", "evidence", "reason", "force", "options", "instead"]
                .filter { args[$0] != nil && !(args[$0] is NSNull) }
            if let stray = given.first(where: { !allowed.contains($0 == "options" ? "option" : $0) }) {
                let takes = allowed.map { $0 == "option" ? "options" : $0 }
                return ("\(action) doesn't use \(stray); \(action) takes \(takes.isEmpty ? "no options" : takes.joined(separator: ", ")) (and run)", true)
            }
            var options: [String: String] = [:]
            for k in allowed where k != "force" && k != "option" { if let v = TaskOps.string(args[k]) { options[k] = v } }
            let q = TaskOps.Request(action: action, ids: ids, options: options, answers: (args["options"] as? [Any])?.compactMap(TaskOps.string) ?? [],
                                    force: args["force"] as? Bool == true, run: args["run"] as? String)
            do {
                let out = try TaskOps.apply(q, ctx: ctx)
                var lines = out.lines
                if !out.tags.isEmpty, !lines.isEmpty { lines[0] = out.tags.joined(separator: " ") + " " + lines[0] }
                return (lines.joined(separator: "\n"), false)
            } catch {
                return (error.message, true)
            }
        }
    }

    // MARK: JSON-RPC

    func result(_ id: Any, _ value: Any) -> String? { encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    func error(_ id: Any?, _ code: Int, _ message: String) -> String? { encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]) }

    func encode(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
    }
}
