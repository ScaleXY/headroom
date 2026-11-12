import Foundation
import HeadroomKit

/// `headroom task hook`: turns a harness hook payload on standard input into task events.
/// Always exits 0 and prints nothing, except the blocking JSON an enforcing Stop hook sends.
/// Unknown events and missing or odd fields are ignored, never an error.
///
/// Claude Code payloads (code.claude.com/docs/en/hooks): every event has `session_id`,
/// `transcript_path`, `cwd`, `hook_event_name`; `Notification` adds `notification_type`, `message`,
/// `title`; `SubagentStart` adds `agent_id`, `agent_type`; `SubagentStop` adds those plus
/// `agent_transcript_path`, `stop_hook_active`, `last_assistant_message`; `Stop` adds
/// `stop_hook_active`, `background_tasks`; `SessionEnd` adds `reason`. Codex sends the same names
/// (plus `turn_id`, `model`) and has `PermissionRequest` where Claude Code has `Notification`.
enum HookCommand {
    /// Notification types that mean a person has to act.
    static let inputNotifications: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

    /// Claude Code names subagent transcripts `agent-<agentId>.jsonl`; the observer keys attempts
    /// `agent:<agentId>`, so the hook does too.
    static func agentKey(_ id: String) -> String { "agent:" + (id.hasPrefix("agent-") ? String(id.dropFirst(6)) : id) }

    static func run(_ args: [String], ctx: TaskContext) -> Int32 {
        let ok = HeadroomCLI.Exit.ok.rawValue
        let a = try? Args(args, valued: ["--harness"], flags: ["--enforce"])
        guard ctx.input.isPiped, let payload = (try? JSONSerialization.jsonObject(with: ctx.input.readAll())) as? [String: Any],
              let name = payload["hook_event_name"] as? String else { return ok }
        let session = (payload["session_id"] as? String).flatMap(TaskRunID.sanitize)
        guard let run = session ?? RunResolver.resolve(flag: nil, environment: ctx.environment) else { return ok }
        let now = ctx.now()
        let agent = (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : agentKey($0) }
        let agentType = (payload["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let exists = TaskJournal.Stream.allCases.contains { FileManager.default.fileExists(atPath: TaskJournal.url(run: run, stream: $0, home: ctx.home).path) }
        var ops: [TaskEvent.Op] = []
        var blocking: String?
        switch name {
        case "Notification":
            guard let type = payload["notification_type"] as? String, inputNotifications.contains(type) else { return ok }
            ops = [.wait(task: nil, attempt: agent, reason: .input, note: (payload["message"] as? String).map { String($0.prefix(160)) } ?? type)]
        case "PermissionRequest":
            ops = [.wait(task: nil, attempt: agent, reason: .input, note: (payload["tool_name"] as? String).map { "permission for \($0)" } ?? "permission")]
        case "UserPromptSubmit":
            ops = [.resume]
        case "SubagentStart":
            guard let agent else { return ok }
            // No title: the observer's (the agent's description) is better, and the fold falls back to the type.
            ops = [.attempt(.init(key: agent, kind: .agent, agentType: agentType))]
        case "SubagentStop":
            // The harness's own helpers (prompt suggestions, /btw) stop with no agent type.
            guard let agent, agentType != nil else { return ok }
            ops = [.attemptEnd(attempt: agent, outcome: .ok)]
        case "Stop":
            if a?.has("--enforce") == true, payload["stop_hook_active"] as? Bool != true, exists {
                blocking = enforcement(run: run, ctx: ctx, now: now)
            }
            ops = [.stop(blocked: blocking != nil)]
        case "SessionEnd":
            ops = [.end]
        default:
            return ok
        }
        // Lifecycle noise alone doesn't start a run: only agents, or a run already declared, do.
        let creates = ops.contains { if case .attempt = $0 { true } else { false } }
        guard exists || creates else { return ok }
        var events = ops.map { TaskEvent(at: now, run: run, source: .hook, op: $0) }
        if !exists {
            let project = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            events.insert(TaskEvent(at: now, run: run, source: .hook, op: .meta(title: nil, project: project, harness: a?["--harness"] ?? "claude-code")), at: 0)
        }
        try? ctx.append(events)
        if let reason = blocking {
            let out = try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": reason], options: [.sortedKeys, .withoutEscapingSlashes])
            ctx.output(out.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        return ok
    }

    /// The reason to send the agent back, when declared tasks are still running with nobody on
    /// them. Never twice in a row: not when the run's last event is a block already.
    static func enforcement(run: String, ctx: TaskContext, now: Date) -> String? {
        let events = TaskJournal.read(run: run, home: ctx.home)
        let last = events.enumerated().max { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }?.element
        if let last, case .stop(true) = last.op { return nil }
        guard let r = TaskFold.fold(events, now: now).first else { return nil }
        let open = r.nodes.filter { $0.declared && $0.leaf && $0.state == .running && $0.attempts.active == 0 }
        guard !open.isEmpty else { return nil }
        let ids = open.prefix(8).map(\.id).joined(separator: ", ") + (open.count > 8 ? " and \(open.count - 8) more" : "")
        return "Headroom: these tasks are still marked running: \(ids). Give each an outcome before stopping: "
            + "`headroom task done ID --evidence …`, `fail ID --reason …`, `skip ID`, `cancel ID`, or `wait ID --for input` if you need the user."
    }
}

/// `headroom hooks install|uninstall|status`: edits Claude Code's settings JSON (or Codex's
/// `hooks.json`, same layout) to run `headroom task hook`. Keeps every other key and hook, backs
/// the file up beside itself first, and writes atomically.
enum HooksCommand {
    struct Target {
        var url: URL
        var codex: Bool
    }

    /// Events and matchers per harness.
    static func events(codex: Bool) -> [(event: String, matcher: String?)] {
        if codex {
            return [("PermissionRequest", nil), ("UserPromptSubmit", nil), ("SubagentStart", nil), ("SubagentStop", nil), ("Stop", nil), ("SessionEnd", nil)]
        }
        return [("Notification", HookCommand.inputNotifications.sorted().joined(separator: "|")), ("UserPromptSubmit", nil),
                ("SubagentStart", nil), ("SubagentStop", nil), ("Stop", nil), ("SessionEnd", nil)]
    }

    static let help = """
    usage: headroom hooks install|uninstall|status [--settings PATH] [--project] [--codex] [--enforce]

    install    adds hooks that run `headroom task hook` on Notification, UserPromptSubmit,
               SubagentStart, SubagentStop, Stop and SessionEnd to ~/.claude/settings.json
               (--project: ./.claude/settings.json). --enforce makes Stop send the agent back,
               once, when tasks it declared are still running with no agent on them.
    --codex    Codex instead: ~/.codex/hooks.json (--project: ./.codex/hooks.json), with
               PermissionRequest for Notification. Codex asks you to trust new hooks in /hooks.
    uninstall  removes only the entries that run `headroom task hook`.
    status     shows what is installed.
    """

    static func run(_ args: [String], ctx: TaskContext, executable: String? = nil) -> Int32 {
        if args.first == "--help" || args.first == "-h" {
            ctx.output(help)
            return HeadroomCLI.Exit.ok.rawValue
        }
        let a: Args
        do { a = try Args(args, valued: ["--settings"], flags: ["--project", "--codex", "--enforce"]) } catch {
            ctx.error("headroom hooks: \(error.message)")
            return HeadroomCLI.Exit.usage.rawValue
        }
        guard a.positional.count == 1, let verb = a.positional.first, ["install", "uninstall", "status"].contains(verb) else {
            ctx.output(help)
            return HeadroomCLI.Exit.usage.rawValue
        }
        let home = URL(fileURLWithPath: ctx.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let cwd = URL(fileURLWithPath: ctx.environment["PWD"] ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let codex = a.has("--codex")
        let url = a["--settings"].map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
            ?? (a.has("--project") ? cwd : home).appendingPathComponent(codex ? ".codex/hooks.json" : ".claude/settings.json")
        let command = hookCommand(binary: executable ?? stableBinary(home: home), enforce: a.has("--enforce"), codex: codex)

        var root: [String: Any] = [:]
        let original = FileManager.default.contents(atPath: url.path)
        if let original, !original.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) {
            guard let obj = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
                ctx.error("headroom hooks: \(url.path) isn't a JSON object; left it alone")
                return HeadroomCLI.Exit.failure.rawValue
            }
            root = obj
        }
        switch verb {
        case "status":
            ctx.output(status(root, url: url, codex: codex))
            return HeadroomCLI.Exit.ok.rawValue
        case "install":
            var hooks = removingOurs(root["hooks"] as? [String: Any] ?? [:])
            // Appending to something that isn't a list would replace what the user wrote.
            if let odd = events(codex: codex).map(\.0).first(where: { hooks[$0] != nil && !(hooks[$0] is [Any]) }) {
                ctx.error("headroom hooks: hooks.\(odd) in \(url.path) isn't a list; left the file alone")
                return HeadroomCLI.Exit.failure.rawValue
            }
            for (event, matcher) in events(codex: codex) {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 10] as [String: Any]]]
                if let matcher { group["matcher"] = matcher }
                hooks[event] = (hooks[event] as? [Any] ?? []) + [group]
            }
            root["hooks"] = hooks
        default:
            guard let hooks = root["hooks"] as? [String: Any] else {
                ctx.output("No Headroom hooks in \(url.path).")
                return HeadroomCLI.Exit.ok.rawValue
            }
            let left = removingOurs(hooks)
            root["hooks"] = left.isEmpty && !hooks.isEmpty ? nil : left
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            ctx.error("headroom hooks: could not encode the settings")
            return HeadroomCLI.Exit.failure.rawValue
        }
        let before = original.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if let before, NSDictionary(dictionary: before).isEqual(to: root) {
            ctx.output(verb == "install" ? "Headroom hooks already installed in \(url.path)." : "No Headroom hooks in \(url.path).")
            return HeadroomCLI.Exit.ok.rawValue
        }
        // The backup is the file as it was before Headroom touched it: a later reinstall or
        // uninstall must not replace it with a copy that already has our hooks.
        let ours = (before?["hooks"] as? [String: Any]).map { !NSDictionary(dictionary: $0).isEqual(to: removingOurs($0)) } ?? false
        let backup = ours ? nil : original
        do {
            try write(data + Data("\n".utf8), to: url, backup: backup)
        } catch {
            ctx.error("headroom hooks: could not write \(url.path): \(error.localizedDescription)")
            return HeadroomCLI.Exit.failure.rawValue
        }
        if verb == "install" {
            ctx.output("Installed Headroom hooks in \(url.path)\(backup == nil ? "" : " (backup: \(url.lastPathComponent).headroom-backup)").")
            ctx.output(ctx.style.dim("  runs: \(command)"))
            if codex { ctx.output(ctx.style.dim("  Codex runs new hooks only once you trust them: open /hooks in Codex.")) }
        } else {
            ctx.output("Removed Headroom hooks from \(url.path).")
        }
        return HeadroomCLI.Exit.ok.rawValue
    }

    /// `~/.local/bin/headroom` or `/opt/homebrew/bin/headroom` when present (they survive app
    /// updates), else wherever this binary really lives.
    static func stableBinary(home: URL) -> String {
        for p in [home.appendingPathComponent(".local/bin/headroom").path, "/opt/homebrew/bin/headroom"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let me = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "headroom")
        return me.resolvingSymlinksInPath().path
    }

    static func hookCommand(binary: String, enforce: Bool, codex: Bool) -> String {
        let safe = binary.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@".contains($0) }
        let quoted = safe ? binary : "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quoted + " task hook" + (enforce ? " --enforce" : "") + (codex ? " --harness codex" : "")
    }

    /// Whether a hook command runs `headroom task hook`, from any path.
    static func isOurs(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespaces)
        var bin: Substring, rest: Substring
        if let q = c.first, q == "'" || q == "\"", let close = c.dropFirst().firstIndex(of: q) {
            bin = c[c.index(after: c.startIndex)..<close]
            rest = c[c.index(after: close)...]
        } else {
            let sp = c.firstIndex(of: " ") ?? c.endIndex
            bin = c[..<sp]
            rest = c[sp...]
        }
        let words = rest.split(separator: " ")
        return (bin == "headroom" || bin.hasSuffix("/headroom")) && words.count >= 2 && words[0] == "task" && words[1] == "hook"
    }

    /// The hooks object without our handlers, dropping groups and events left empty by that.
    static func removingOurs(_ hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for g in groups {
                guard var group = g as? [String: Any], let handlers = group["hooks"] as? [Any] else { kept.append(g); continue }
                let left = handlers.filter { h in !(((h as? [String: Any])?["command"] as? String).map(isOurs) ?? false) }
                if left.count == handlers.count { kept.append(g); continue }
                if left.isEmpty { continue }
                group["hooks"] = left
                kept.append(group)
            }
            if kept.isEmpty && !groups.isEmpty { out[event] = nil } else { out[event] = kept }
        }
        return out
    }

    static func status(_ root: [String: Any], url: URL, codex: Bool) -> String {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var lines = ["Headroom hooks in \(url.path):"]
        var installed = 0
        for (event, _) in events(codex: codex) {
            let commands = (hooks[event] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.flatMap { ($0["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String } }
            if let ours = commands.first(where: isOurs) {
                installed += 1
                lines.append("  ✓ \(event.padding(toLength: 18, withPad: " ", startingAt: 0)) \(ours)")
            } else {
                lines.append("  ✗ \(event.padding(toLength: 18, withPad: " ", startingAt: 0)) not installed")
            }
        }
        let total = events(codex: codex).count
        lines.append(installed == total ? "All \(total) installed." : installed == 0 ? "Not installed: run `headroom hooks install\(codex ? " --codex" : "")`." : "\(installed) of \(total) installed: run `headroom hooks install\(codex ? " --codex" : "")` again.")
        return lines.joined(separator: "\n")
    }

    /// Backup first, then a temporary file renamed over the original, keeping its permissions.
    static func write(_ data: Data, to url: URL, backup: Data?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
        if let backup {
            let b = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".headroom-backup")
            try backup.write(to: b, options: .atomic)
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: b.path)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).headroom-\(getpid())")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
