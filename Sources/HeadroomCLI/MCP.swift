import Foundation
import HeadroomKit

/// `headroom mcp`: a stdio Model Context Protocol server. Newline-delimited JSON-RPC 2.0 on
/// standard input and output (`initialize`, `notifications/initialized`, `ping`, `tools/list`,
/// `tools/call`). Tools read the allowance and the task runs, and declare and update tasks with
/// the same operations as `headroom task`.
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
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
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
                "instructions": "Headroom shows the user how much Claude and Codex allowance is left and what long agent runs are doing. Declare a plan with plan_tasks, put each task's tag in the description of the agent you spawn for it, and report progress with update_task.",
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

    static var taskProperties: [String: Any] { [
        "id": ["type": "string", "description": "Path id such as api/tests; may start with RUN:"],
        "title": ["type": "string"],
        "effort": ["type": ["string", "number"], "description": "xs, s, m, l, xl (1, 2, 4, 8, 16) or a positive number; relative to siblings"],
        "importance": ["type": "string", "enum": ["critical", "normal", "optional"]],
        "steps": ["type": "integer", "minimum": 1, "description": "Total steps"],
    ] }

    static var tools: [[String: Any]] { [
        ["name": "get_headroom", "description": "Weekly Claude and Codex allowance left, time to renewal, the 5-hour session and blocks, from Headroom.app's snapshot.",
         "inputSchema": ["type": "object", "properties": [String: Any]()], "annotations": ["readOnlyHint": true]],
        ["name": "get_tasks", "description": "Task runs as a tree with states, progress (done, in flight, estimate), must-haves, ETA and tokens.",
         "inputSchema": ["type": "object", "properties": ["run": ["type": "string", "description": "Only this run"], "all": ["type": "boolean", "description": "Every run from the last 7 days, not just active ones"]]],
         "annotations": ["readOnlyHint": true]],
        ["name": "plan_tasks", "description": "Declare many tasks at once. Returns each task's tag, [hr:RUN:PATH], to put in the description of the agent spawned for it.",
         "inputSchema": ["type": "object", "required": ["tasks"], "properties": [
             "run": ["type": "string", "description": "Run id; defaults to this session"],
             "title": ["type": "string", "description": "Title for the run"],
             "tasks": ["type": "array", "description": "Tasks; each may have children (ids relative to the parent)",
                       "items": ["type": "object", "required": ["id"], "properties": taskProperties.merging(["children": ["type": "array", "items": ["type": "object"]]]) { a, _ in a }]],
         ]]],
        ["name": "update_task", "description": "Add, start, report progress on, wait on, or finish one task.",
         "inputSchema": ["type": "object", "required": ["id", "action"], "properties": taskProperties.merging([
             "action": ["type": "string", "enum": TaskOps.actions],
             "run": ["type": "string"],
             "step": ["type": ["integer", "string"], "description": "Steps done, or K/N"],
             "fraction": ["type": "number", "minimum": 0, "maximum": 1],
             "note": ["type": "string"],
             "for": ["type": "string", "enum": ["input", "dependency", "limit"], "description": "What a wait is for"],
             "evidence": ["type": "string", "description": "What shows a task is done"],
             "reason": ["type": "string", "description": "Why a task failed, was skipped or cancelled"],
         ]) { a, _ in a }]],
    ] }

    func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let now = ctx.now()
        switch name {
        case "get_headroom":
            guard let s = SnapshotFile.read(from: snapshotURL) else { return ("Headroom has not written a snapshot yet. Is the app running?", true) }
            return (HeadroomCLI.jsonOutput(s, now: now), false)
        case "get_tasks":
            let only = (args["run"] as? String).flatMap(TaskRunID.sanitize)
            var loaded = TaskStore(home: ctx.home).load(now: now, all: args["all"] as? Bool == true || only != nil)
            if let only { loaded.runs = loaded.runs.filter { $0.id == only } }
            let feed = TasksFeed(generatedAt: now, writerPID: 0, runs: loaded.runs)
            return ((try? TasksFile.encoder(pretty: true).encode(feed)).map { String(decoding: $0, as: UTF8.self) } ?? "{}", false)
        case "plan_tasks":
            guard let run = RunResolver.resolve(flag: args["run"] as? String, environment: ctx.environment) else { return (RunResolver.missing, true) }
            do {
                let p = try TaskOps.plan(["tasks": args["tasks"] ?? []], now: now)
                guard !p.tasks.isEmpty else { return ("No tasks given.", true) }
                let events = p.tasks.map { TaskEvent(at: now, run: run, source: .agent, op: .add($0)) }
                try ctx.append(TaskOps.withMeta(events, run: run, title: args["title"] as? String, project: args["project"] as? String, ctx: ctx))
                return ((["Declared \(p.tasks.count) tasks in run \(run):"] + p.tasks.map { "\(TaskRef(run: run, path: $0.id).tag)  \($0.title ?? $0.id)" }).joined(separator: "\n"), false)
            } catch let f as TaskOps.Failure {
                return (f.message, true)
            } catch {
                return ("Could not write the journal: \(error.localizedDescription)", true)
            }
        default:
            guard let id = args["id"] as? String, let action = args["action"] as? String else { return ("update_task needs id and action", true) }
            guard let (run, path) = RunResolver.resolve(flag: args["run"] as? String, id: id, environment: ctx.environment) else { return (RunResolver.missing, true) }
            var options: [String: String] = [:]
            for k in ["title", "effort", "importance", "steps", "step", "fraction", "note", "for", "evidence", "reason"] {
                if let v = TaskOps.string(args[k]) { options[k] = v }
            }
            do {
                let events = try TaskOps.events(action: action, run: run, path: path, options: options, now: now)
                try ctx.append(TaskOps.withMeta(events, run: run, title: nil, project: nil, ctx: ctx))
                return (action == "add" ? TaskRef(run: run, path: path).tag : "ok", false)
            } catch let f as TaskOps.Failure {
                return (f.message, true)
            } catch {
                return ("Could not write the journal: \(error.localizedDescription)", true)
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
