import Foundation
import HeadroomKit

/// `headroom task hook`: turns a harness hook payload on standard input into task events.
/// Always exits 0 and prints nothing, except the blocking JSON an enforcing Stop hook sends and
/// the context a SessionStart hook hands back. Unknown events and missing or odd fields are
/// ignored, never an error. Every call records the harness's heartbeat.
///
/// Claude Code payloads (code.claude.com/docs/en/hooks): every event has `session_id`,
/// `transcript_path`, `cwd`, `hook_event_name`; `Notification` adds `notification_type`, `message`,
/// `title`; `SubagentStart` adds `agent_id`, `agent_type`; `SubagentStop` adds those plus
/// `agent_transcript_path`, `stop_hook_active`, `last_assistant_message`; `Stop` adds
/// `stop_hook_active`, `background_tasks`; `SessionStart` adds `source` (`startup`, `resume`,
/// `clear`, `compact`); `SessionEnd` adds `reason`. Codex sends the same names (plus `turn_id`,
/// `model`) and has `PermissionRequest` where Claude Code has `Notification`.
enum HookCommand {
    /// Notification types that mean a person has to act.
    static let inputNotifications = Set(HookInstaller.inputNotifications)

    /// Claude Code names subagent transcripts `agent-<agentId>.jsonl`; the observer keys attempts
    /// `agent:<agentId>`, so the hook does too.
    static func agentKey(_ id: String) -> String { "agent:" + (id.hasPrefix("agent-") ? String(id.dropFirst(6)) : id) }

    static func run(_ args: [String], ctx: TaskContext) -> Int32 {
        let ok = HeadroomCLI.Exit.ok.rawValue
        let a = try? Args(args, valued: ["--harness", "--run"], flags: ["--enforce"])
        guard let data = ctx.input.readPiped(timeout: 2000), let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = payload["hook_event_name"] as? String else { return ok }
        let now = ctx.now()
        HookInstaller.recordHeartbeat(AgentHarness(rawValue: a?["--harness"] ?? "") ?? .claudeCode, at: now, store: ctx.home)
        // The same order as every `headroom task` command, so both name the same run.
        guard let run = RunResolver.resolve(flag: a?["--run"], environment: ctx.environment, session: payload["session_id"] as? String, home: ctx.home) else { return ok }
        if name == "SessionStart" {
            if let text = sessionStart(payload, run: run, ctx: ctx, now: now) {
                let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": text]]
                if let json = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]) { ctx.output(String(decoding: json, as: UTF8.self)) }
            }
            return ok
        }
        let agent = (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : agentKey($0) }
        let agentType = (payload["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let exists = RunResolver.exists(run, home: ctx.home)
        var ops: [TaskEvent.Op] = []
        var blocking: String?
        switch name {
        case "Notification":
            guard let type = payload["notification_type"] as? String, inputNotifications.contains(type) else { return ok }
            ops = [.wait(task: nil, attempt: agent, reason: .input, note: TaskText.clean(payload["message"] as? String, limit: 160) ?? type)]
        case "PermissionRequest":
            ops = [.wait(task: nil, attempt: agent, reason: .input, note: TaskText.clean(payload["tool_name"] as? String, limit: 80).map { "permission for \($0)" } ?? "permission")]
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
            // Work still running in the background (agents, shells) is a fine reason to stop.
            let background = (payload["background_tasks"] as? [Any]).map { !$0.isEmpty } ?? false
            if a?.has("--enforce") == true, payload["stop_hook_active"] as? Bool != true, exists, !background {
                blocking = enforcement(TaskJournal.read(run: run, home: ctx.home), now: now)
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
        let cwd = (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let host = RunResolver.host(environment: ctx.environment)
        if !exists {
            events.insert(TaskEvent(at: now, run: run, source: .hook, op: .meta(title: nil, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                                                                                 harness: a?["--harness"] ?? "claude-code", host: host, cwd: cwd)), at: 0)
        } else if host != nil || cwd != nil {
            let journal = (try? Data(contentsOf: TaskJournal.url(run: run, stream: .journal, home: ctx.home))).map(TaskJournal.decode) ?? []
            let last = TaskOps.lastPlace(journal)
            if (host != nil && host != last.host) || (cwd != nil && cwd != last.cwd) {
                events.insert(TaskEvent(at: now, run: run, source: .hook, op: .meta(title: nil, project: nil, harness: nil, host: host ?? last.host, cwd: cwd ?? last.cwd)), at: 0)
            }
        }
        try? ctx.append(events)
        if let reason = blocking {
            let out = try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": reason], options: [.sortedKeys, .withoutEscapingSlashes])
            ctx.output(out.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        return ok
    }

    /// The reason to send the agent back, when declared tasks are still running with nobody on
    /// them. Never twice in a row (not when the run's last event is a block already), and a task
    /// reported on since the last block, in the same turn, has been answered for.
    static func enforcement(_ events: [TaskEvent], now: Date) -> String? {
        let ordered = events.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        func isBlock(_ e: TaskEvent) -> Bool { if case .stop(true) = e.op { true } else { false } }
        if let last = ordered.last, isBlock(last) { return nil }
        let block = ordered.last(where: isBlock)?.at
        let resume = ordered.last { $0.op == .resume }?.at
        let answeredAfter = block.flatMap { b in (resume.map { $0 <= b } ?? true) ? b : nil }
        guard let r = TaskFold.fold(events, now: now).first else { return nil }
        let open = r.nodes.filter { n in
            n.declared && n.leaf && n.state == .running && n.attempts.active == 0
                && !(answeredAfter.map { since in (n.lastActivityAt ?? .distantPast) > since } ?? false)
        }
        guard !open.isEmpty else { return nil }
        let ids = open.prefix(8).map(\.id).joined(separator: ", ") + (open.count > 8 ? " and \(open.count - 8) more" : "")
        return "Headroom: these tasks are still marked running: \(ids). Give each an outcome before stopping: "
            + "`headroom task done ID --evidence …`, `fail ID --reason …`, `skip ID` or `cancel ID` (several ids per call are fine). "
            + "If one is still being worked on in the background (a subagent or a command you started), say so instead and stop: "
            + "`headroom task progress ID --note \"running in the background\"`. If you need the user: `headroom task wait ID --for input --note …`."
    }

    /// After a compaction, resume or /clear: the run's tree for the agent, or, for a new session
    /// with no plan, a pointer to an unfinished run in the same folder it could adopt.
    static func sessionStart(_ payload: [String: Any], run: String, ctx: TaskContext, now: Date) -> String? {
        guard let source = payload["source"] as? String, ["compact", "resume", "clear"].contains(source) else { return nil }
        let events = TaskJournal.read(run: run, home: ctx.home)
        if TaskOps.hasPlan(events), let r = TaskFold.fold(events, now: now).first {
            return (["Headroom: this session reports progress on run \(run) with `headroom task`. Where it stands:"]
                    + TaskEcho.status(r, now: now, titles: false)
                    + ["Keep reporting as you go (start, progress, done …) and give every task an outcome before you stop. `headroom task status` shows this again."])
                .joined(separator: "\n")
        }
        guard source != "compact", let cwd = payload["cwd"] as? String, !cwd.isEmpty, let (other, open) = earlierRun(cwd: cwd, excluding: run, ctx: ctx, now: now) else { return nil }
        return "Headroom: run \(other) in this folder still has open tasks (\(open.prefix(4).joined(separator: ", "))\(open.count > 4 ? " …" : "")). "
            + "If this session continues that work, run `headroom task adopt \(other)` and keep reporting into it; otherwise ignore this."
    }

    /// The most recent unfinished run with a plan whose metadata names `cwd`, from the last 12 hours.
    static func earlierRun(cwd: String, excluding run: String, ctx: TaskContext, now: Date) -> (String, [String])? {
        var best: (id: String, open: [String], at: Date)?
        for id in TaskJournal.runs(home: ctx.home, modifiedSince: now.addingTimeInterval(-12 * 3600)) where id != run {
            guard let data = try? Data(contentsOf: TaskJournal.url(run: id, stream: .journal, home: ctx.home)) else { continue }
            let events = TaskJournal.decode(data)
            guard TaskOps.lastPlace(events).cwd == cwd, TaskOps.hasPlan(events), let r = TaskFold.fold(events, now: now).first, !r.state.isTerminal else { continue }
            let open = TaskEcho.open(r).map(\.id)
            if !open.isEmpty, best.map({ r.updatedAt > $0.at }) ?? true { best = (id, open, r.updatedAt) }
        }
        return best.map { ($0.id, $0.open) }
    }
}

/// `headroom hooks install|uninstall|status`: the CLI face of `HookInstaller` and
/// `AgentInstructions`, which the app's Settings call too.
enum HooksCommand {
    static let help = """
    usage: headroom hooks install|uninstall|status [--codex] [--enforce] [--instructions] [--settings PATH] [--project]

    install         adds hooks that run `headroom task hook` on Notification, UserPromptSubmit,
                    SubagentStart, SubagentStop, Stop, SessionEnd and SessionStart to
                    ~/.claude/settings.json ($CLAUDE_CONFIG_DIR; --project: ./.claude/settings.json),
                    and lets `headroom task …` run without a permission prompt. --enforce makes
                    Stop send the agent back, once, when tasks it declared are still running with
                    nothing working on them.
    --codex         Codex instead: ~/.codex/hooks.json ($CODEX_HOME), with PermissionRequest for
                    Notification. Codex asks you to trust new hooks in /hooks.
    --instructions  also adds (or removes) a few lines asking the agent to run `headroom task guide`
                    to ~/.claude/CLAUDE.md (Codex: ~/.codex/AGENTS.md).
    uninstall       removes only Headroom's entries.
    status          shows what is installed and when a hook last ran.
    Files are backed up beside themselves before the first change and written through symlinks.
    """

    static func run(_ args: [String], ctx: TaskContext, executable: String? = nil) -> Int32 {
        if args.first == "--help" || args.first == "-h" {
            ctx.output(help)
            return HeadroomCLI.Exit.ok.rawValue
        }
        let a: Args
        do { a = try Args(args, valued: ["--settings"], flags: ["--project", "--codex", "--enforce", "--instructions", "--help", "-h"]) } catch {
            ctx.error("headroom hooks: \(error.message)")
            return HeadroomCLI.Exit.usage.rawValue
        }
        if a.has("--help") || a.has("-h") {
            ctx.output(help)
            return HeadroomCLI.Exit.ok.rawValue
        }
        guard a.positional.count == 1, let verb = a.positional.first, ["install", "uninstall", "status"].contains(verb) else {
            ctx.output(help)
            return HeadroomCLI.Exit.usage.rawValue
        }
        let env = ctx.environment
        let userHome = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let cwd = URL(fileURLWithPath: env["PWD"] ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let harness: AgentHarness = a.has("--codex") ? .codex : .claudeCode
        let url = a["--settings"].map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
            ?? HookInstaller.settingsURL(harness, userHome: userHome, environment: env, project: a.has("--project") ? cwd : nil)
        let flag = harness == .codex ? " --codex" : ""
        switch verb {
        case "status":
            ctx.output(status(harness, settings: url, userHome: userHome, ctx: ctx, flag: flag))
            return HeadroomCLI.Exit.ok.rawValue
        case "install":
            let binary = executable ?? HookInstaller.defaultBinary(userHome: userHome) ?? ownPath()
            do {
                ctx.output(try HookInstaller.install(harness, enforce: a.has("--enforce"), binary: binary, settings: url))
                if a.has("--instructions") { ctx.output(try AgentInstructions.add(harness, userHome: userHome, environment: env)) }
            } catch {
                ctx.error("headroom hooks: \(error.message)")
                return HeadroomCLI.Exit.failure.rawValue
            }
            ctx.output(ctx.style.dim("  runs: \(HookInstaller.hookCommand(binary: binary, enforce: a.has("--enforce"), harness: harness))"))
            if harness == .codex { ctx.output(ctx.style.dim("  Codex runs new hooks only once you trust them: open /hooks in Codex.")) }
        default:
            do {
                ctx.output(try HookInstaller.uninstall(harness, settings: url))
                if a.has("--instructions") { ctx.output(try AgentInstructions.remove(harness, userHome: userHome, environment: env)) }
            } catch {
                ctx.error("headroom hooks: \(error.message)")
                return HeadroomCLI.Exit.failure.rawValue
            }
        }
        return HeadroomCLI.Exit.ok.rawValue
    }

    /// Wherever this binary really lives.
    static func ownPath() -> String {
        let me = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "headroom")
        return me.resolvingSymlinksInPath().path
    }

    static func status(_ harness: AgentHarness, settings url: URL, userHome: URL, ctx: TaskContext, flag: String) -> String {
        let s = HookInstaller.status(harness, settings: url, store: ctx.home)
        var lines = ["\(harness.displayName) hooks in \(url.path):"]
        guard let commands = HookInstaller.installedCommands(harness, settings: url) else {
            return (lines + ["  The file isn't JSON Headroom can read; fix it, then run `headroom hooks install\(flag)`."]).joined(separator: "\n")
        }
        for (event, command) in commands {
            lines.append("  " + (command.map { "✓ \(event.padding(toLength: 18, withPad: " ", startingAt: 0)) \($0)" } ?? "✗ \(event.padding(toLength: 18, withPad: " ", startingAt: 0)) not installed"))
        }
        let beat = s.lastEventAt.map { "last hook event \(TimeFormat.compact(max(0, ctx.now().timeIntervalSince($0)))) ago" } ?? "no hook has run yet"
        if s.installed {
            lines.append("All \(s.totalEvents) installed · \(beat).")
        } else if s.installedEvents == 0 {
            lines.append("Not installed: run `headroom hooks install\(flag)`.")
        } else {
            lines.append("\(s.installedEvents) of \(s.totalEvents) installed: run `headroom hooks install\(flag)` again · \(beat).")
        }
        if s.enforcing { lines.append("Stop sends unfinished tasks back (--enforce).") }
        if harness == .claudeCode, s.installedEvents > 0 {
            lines.append(s.allowsReports ? "`headroom task …` runs without a permission prompt." : "`headroom task …` may ask for permission: run `headroom hooks install` again to allow it.")
        }
        let i = AgentInstructions.status(harness, userHome: userHome, environment: ctx.environment)
        lines.append(i.present ? "Agent instructions: in \(i.path)." : "Agent instructions: not in \(i.path); `headroom hooks install\(flag) --instructions` adds them.")
        return lines.joined(separator: "\n")
    }
}
