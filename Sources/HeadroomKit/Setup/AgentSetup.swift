import Foundation

// The in-app setup (Settings › Runs) and `headroom hooks` share this: the app and the CLI both
// call these. `userHome` is the person's home folder (where `.claude` and `.codex` live); `store`
// is Headroom's own folder (`SnapshotFile.directory`), where the hook heartbeat is kept.

/// The agent harnesses Headroom can set up.
public enum AgentHarness: String, CaseIterable, Sendable, Hashable {
    case claudeCode = "claude-code"
    case codex

    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
}

/// What `headroom hooks` has installed for one harness, and whether it is firing.
public struct HookInstallStatus: Sendable, Hashable {
    /// The settings file the hooks live in.
    public var path: String
    /// Hook events with Headroom's handler, out of the ones it installs.
    public var installedEvents: Int
    public var totalEvents: Int
    /// The Stop hook sends unfinished tasks back (`--enforce`).
    public var enforcing: Bool
    /// When a Headroom hook last ran for this harness (the heartbeat), if ever.
    public var lastEventAt: Date?
    /// The settings file exists but isn't JSON Headroom can edit safely.
    public var unreadable: Bool
    /// Claude Code only: `permissions.allow` lets `headroom task …` run without a prompt.
    public var allowsReports: Bool = false

    public init(path: String, installedEvents: Int = 0, totalEvents: Int = 0, enforcing: Bool = false, lastEventAt: Date? = nil, unreadable: Bool = false) {
        self.path = path; self.installedEvents = installedEvents; self.totalEvents = totalEvents; self.enforcing = enforcing
        self.lastEventAt = lastEventAt; self.unreadable = unreadable
    }

    public var installed: Bool { totalEvents > 0 && installedEvents == totalEvents }
}

/// Edits the harness's hook settings (Claude Code's `settings.json`, Codex's `hooks.json`, same
/// layout) to run `headroom task hook`. Keeps every other key, hook and the file's key order;
/// writes only when something changes, through symlinks, after backing the original up beside it.
public enum HookInstaller {
    public struct Failure: Error, Sendable { public var message: String; public init(_ message: String) { self.message = message } }

    /// Notification types that mean a person has to act (Claude Code's `Notification` matcher).
    public static let inputNotifications = ["agent_needs_input", "elicitation_dialog", "elicitation_url_dialog", "idle_prompt", "permission_prompt"]

    /// Lets the agent report without a permission prompt (Claude Code).
    public static let permissionRule = "Bash(headroom task:*)"

    /// The hook events Headroom installs, with their matchers.
    public static func events(_ harness: AgentHarness) -> [(event: String, matcher: String?)] {
        switch harness {
        case .codex:
            return [("PermissionRequest", nil), ("UserPromptSubmit", nil), ("SubagentStart", nil), ("SubagentStop", nil), ("Stop", nil), ("SessionEnd", nil),
                    ("SessionStart", nil)]
        case .claudeCode:
            return [("Notification", inputNotifications.joined(separator: "|")), ("UserPromptSubmit", nil), ("SubagentStart", nil), ("SubagentStop", nil),
                    ("Stop", nil), ("SessionEnd", nil), ("SessionStart", "resume|clear|compact")]
        }
    }

    /// Where the harness keeps its hooks: honours `CLAUDE_CONFIG_DIR` and `CODEX_HOME`. With
    /// `project`, that folder's `.claude/settings.json` or `.codex/hooks.json`.
    public static func settingsURL(_ harness: AgentHarness, userHome: URL, environment: [String: String], project: URL? = nil) -> URL {
        if let project { return project.appendingPathComponent(harness == .codex ? ".codex/hooks.json" : ".claude/settings.json") }
        return configDirectory(harness, userHome: userHome, environment: environment).appendingPathComponent(harness == .codex ? "hooks.json" : "settings.json")
    }

    /// `$CLAUDE_CONFIG_DIR` or `~/.claude`; `$CODEX_HOME` or `~/.codex`.
    public static func configDirectory(_ harness: AgentHarness, userHome: URL, environment: [String: String]) -> URL {
        let variable = harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        if let dir = environment[variable], !dir.isEmpty { return SetupFiles.expand(dir, userHome: userHome) }
        return userHome.appendingPathComponent(harness == .codex ? ".codex" : ".claude", isDirectory: true)
    }

    public static func status(_ harness: AgentHarness, userHome: URL, store: URL, environment: [String: String]) -> HookInstallStatus {
        status(harness, settings: settingsURL(harness, userHome: userHome, environment: environment), store: store)
    }

    /// The status of the hooks in a given settings file.
    public static func status(_ harness: AgentHarness, settings url: URL, store: URL?) -> HookInstallStatus {
        var s = HookInstallStatus(path: url.path, totalEvents: events(harness).count, lastEventAt: store.flatMap { lastEvent(harness, store: $0) })
        guard let root = try? read(url) else { s.unreadable = true; return s }
        let commands = installedCommands(harness, root: root)
        s.installedEvents = commands.filter { $0.command != nil }.count
        s.enforcing = commands.first { $0.event == "Stop" }?.command?.contains(" --enforce") ?? false
        s.allowsReports = root["permissions"]?["allow"]?.elements?.contains(.string(permissionRule)) ?? false
        return s
    }

    /// Each installed event and Headroom's command on it (nil where missing); nil when the file
    /// isn't JSON Headroom can read.
    public static func installedCommands(_ harness: AgentHarness, settings url: URL) -> [(event: String, command: String?)]? {
        guard let root = try? read(url) else { return nil }
        return installedCommands(harness, root: root)
    }

    static func installedCommands(_ harness: AgentHarness, root: OrderedJSON) -> [(event: String, command: String?)] {
        let hooks = root["hooks"]
        return events(harness).map { e in
            let commands = (hooks?[e.event]?.elements ?? []).flatMap { ($0["hooks"]?.elements ?? []).compactMap { $0["command"]?.string } }
            return (e.event, commands.first(where: isOurs))
        }
    }

    /// Installs (or updates) Headroom's hooks, backing the file up first. Returns what it did, in a sentence.
    @discardableResult
    public static func install(_ harness: AgentHarness, enforce: Bool, binary: String, userHome: URL, environment: [String: String]) throws(Failure) -> String {
        try install(harness, enforce: enforce, binary: binary, settings: settingsURL(harness, userHome: userHome, environment: environment))
    }

    @discardableResult
    public static func uninstall(_ harness: AgentHarness, userHome: URL, environment: [String: String]) throws(Failure) -> String {
        try uninstall(harness, settings: settingsURL(harness, userHome: userHome, environment: environment))
    }

    /// Installs into a given settings file (`--settings`, `--project`).
    @discardableResult
    public static func install(_ harness: AgentHarness, enforce: Bool, binary: String, settings url: URL) throws(Failure) -> String {
        let command = hookCommand(binary: binary, enforce: enforce, harness: harness)
        let backup = try edit(url) { (root: inout OrderedJSON) throws(Failure) in
            var hooks = removingOurs(root["hooks"] ?? .object([]))
            for (event, matcher) in events(harness) {
                var group: [OrderedJSON.Member] = []
                if let matcher { group.append(.init("matcher", .string(matcher))) }
                group.append(.init("hooks", .array([.object([.init("type", .string("command")), .init("command", .string(command)), .init("timeout", .number("10"))])])))
                hooks[event] = .array((hooks[event]?.elements ?? []) + [.object(group)])
            }
            root["hooks"] = hooks
            if harness == .claudeCode { addPermission(&root) }
        }
        guard let backup else { return "Headroom hooks already installed in \(url.path)." }
        return "Installed Headroom hooks in \(url.path)" + (backup.isEmpty ? "." : " (backup: \(backup)).")
    }

    /// Removes only Headroom's entries (and its permission rule) from a given settings file.
    @discardableResult
    public static func uninstall(_ harness: AgentHarness, settings url: URL) throws(Failure) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "No Headroom hooks in \(url.path)." }
        let changed = try edit(url) { (root: inout OrderedJSON) throws(Failure) in
            if let hooks = root["hooks"] {
                let left = removingOurs(hooks)
                root["hooks"] = left.members?.isEmpty == true && hooks.members?.isEmpty == false ? nil : left
            }
            removePermission(&root)
        }
        return changed == nil ? "No Headroom hooks in \(url.path)." : "Removed Headroom hooks from \(url.path)."
    }

    /// `~/.local/bin/headroom`, `/opt/homebrew/bin/headroom` or `/usr/local/bin/headroom` when
    /// present (they survive app updates), else nil.
    public static func defaultBinary(userHome: URL) -> String? {
        [userHome.appendingPathComponent(".local/bin/headroom").path, "/opt/homebrew/bin/headroom", "/usr/local/bin/headroom"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Notes that a hook for `harness` just ran (called by `headroom task hook`).
    public static func recordHeartbeat(_ harness: AgentHarness, at: Date, store: URL) {
        HookHeartbeat.record(harness, at: at, store: store)
    }

    /// When a Headroom hook last ran for `harness`, if ever.
    public static func lastEvent(_ harness: AgentHarness, store: URL) -> Date? {
        HookHeartbeat.read(store: store)[harness.rawValue]
    }

    /// The command a hook runs: the binary (quoted when it needs to be), `task hook`, the flags.
    public static func hookCommand(binary: String, enforce: Bool, harness: AgentHarness) -> String {
        let safe = binary.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@".contains($0) }
        let quoted = safe ? binary : "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quoted + " task hook" + (enforce ? " --enforce" : "") + (harness == .codex ? " --harness codex" : "")
    }

    /// Whether a hook command runs `headroom task hook`, from any path.
    public static func isOurs(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespaces)
        var bin: Substring, rest: Substring
        if let q = c.first, q == "'" || q == "\"", var close = c.dropFirst().firstIndex(of: q) {
            // `hookCommand` writes a quote inside the path as `'\''`: the path goes on after it.
            while q == "'", c[close...].hasPrefix("'\\''"), let next = c[c.index(close, offsetBy: 4)...].firstIndex(of: q) { close = next }
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

    // MARK: Editing

    /// The settings as an ordered object; an empty or missing file is an empty object.
    static func read(_ url: URL) throws(Failure) -> OrderedJSON {
        guard let data = FileManager.default.contents(atPath: url.path),
              !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) else { return .object([]) }
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(data) } catch {
            throw Failure("\(url.path) isn't valid JSON (\(error.message) at byte \(error.offset)); left it alone. Fix the file, then run this again.")
        }
        guard root.members != nil else { throw Failure("\(url.path) isn't a JSON object; left it alone.") }
        return root
    }

    /// Applies `change` and writes the file if it changed. Returns nil when nothing changed, else
    /// the backup's file name ("" when none was made: a new file, or one Headroom had edited already).
    static func edit(_ url: URL, _ change: (inout OrderedJSON) throws(Failure) -> Void) throws(Failure) -> String? {
        let original = FileManager.default.contents(atPath: url.path)
        let before = try read(url)
        if let hooks = before["hooks"] {
            guard hooks.members != nil else {
                throw Failure("\"hooks\" in \(url.path) isn't an object; left the file alone. Fix it by hand (it should be {\"Stop\": [ … ], …}), then run this again.")
            }
            for (event, _) in events(.claudeCode) + events(.codex) where hooks[event] != nil && hooks[event]?.elements == nil {
                throw Failure("hooks.\(event) in \(url.path) isn't a list; left the file alone. Fix it by hand, then run this again.")
            }
        }
        var after = before
        try change(&after)
        guard after != before else { return nil }
        // The backup is the file as it was before Headroom touched it: a later reinstall or
        // uninstall must not replace it with a copy that already has Headroom's entries.
        let hadOurs = before["hooks"].map { removingOurs($0) != $0 } ?? false
            || before["permissions"]?["allow"]?.elements?.contains(.string(permissionRule)) == true
        let backup = hadOurs ? nil : original.flatMap { $0.isEmpty ? nil : $0 }
        do {
            let written = try SetupFiles.write(Data((after.serialized() + "\n").utf8), to: url, backup: backup)
            return written?.lastPathComponent ?? ""
        } catch {
            throw Failure("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// The hooks object without Headroom's handlers, dropping groups and events left empty by that.
    static func removingOurs(_ hooks: OrderedJSON) -> OrderedJSON {
        guard let members = hooks.members else { return hooks }
        var out: [OrderedJSON.Member] = []
        for m in members {
            guard let groups = m.value.elements else { out.append(m); continue }
            var kept: [OrderedJSON] = []
            for g in groups {
                guard let handlers = g["hooks"]?.elements else { kept.append(g); continue }
                let left = handlers.filter { !($0["command"]?.string.map(isOurs) ?? false) }
                if left.count == handlers.count { kept.append(g); continue }
                if left.isEmpty { continue }
                var group = g
                group["hooks"] = .array(left)
                kept.append(group)
            }
            if kept.isEmpty && !groups.isEmpty { continue }
            out.append(.init(m.key, .array(kept)))
        }
        return .object(out)
    }

    static func addPermission(_ root: inout OrderedJSON) {
        var perms = root["permissions"] ?? .object([])
        // Someone else's odd shapes are left alone: the rule is a convenience.
        guard perms.members != nil else { return }
        let allow = perms["allow"] ?? .array([])
        guard var list = allow.elements else { return }
        if !list.contains(.string(permissionRule)) { list.append(.string(permissionRule)) }
        perms["allow"] = .array(list)
        root["permissions"] = perms
    }

    static func removePermission(_ root: inout OrderedJSON) {
        guard var perms = root["permissions"], perms.members != nil, let list = perms["allow"]?.elements,
              list.contains(.string(permissionRule)) else { return }
        let left = list.filter { $0 != .string(permissionRule) }
        perms["allow"] = left.isEmpty ? nil : .array(left)
        root["permissions"] = perms.members?.isEmpty == true ? nil : perms
    }
}

/// The few lines that ask an agent to report progress (`headroom task guide`), kept in the
/// harness's global instructions file: `~/.claude/CLAUDE.md` (or `$CLAUDE_CONFIG_DIR/CLAUDE.md`)
/// for Claude Code, `~/.codex/AGENTS.md` (or `$CODEX_HOME/AGENTS.md`) for Codex. The block sits
/// between `<!-- headroom:begin -->` and `<!-- headroom:end -->`; everything else is left as it is.
public enum AgentInstructions {
    public struct Status: Sendable, Hashable {
        public var path: String
        public var present: Bool
        public init(path: String, present: Bool) { self.path = path; self.present = present }
    }

    public static let begin = "<!-- headroom:begin -->"
    public static let end = "<!-- headroom:end -->"

    public static let snippet = """
    \(begin)
    ## Progress reporting (Headroom)
    Before long multi-step work (3 or more steps, or any subagents), run `headroom task guide` once and follow it.
    If your prompt carries a tag like `[hr:RUN:PATH]`, report on that task with its full id instead of planning.
    After a context compaction, `headroom task status` shows where you are.
    \(end)
    """

    public static func fileURL(_ harness: AgentHarness, userHome: URL, environment: [String: String]) -> URL {
        HookInstaller.configDirectory(harness, userHome: userHome, environment: environment).appendingPathComponent(harness == .codex ? "AGENTS.md" : "CLAUDE.md")
    }

    public static func status(_ harness: AgentHarness, userHome: URL, environment: [String: String]) -> Status {
        let url = fileURL(harness, userHome: userHome, environment: environment)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Status(path: url.path, present: block(in: text) != nil)
    }

    /// Adds the block, or brings an older one up to date. Creates the file if it is missing.
    @discardableResult
    public static func add(_ harness: AgentHarness, userHome: URL, environment: [String: String]) throws(HookInstaller.Failure) -> String {
        let url = fileURL(harness, userHome: userHome, environment: environment)
        let text = try read(url)
        var out: String
        if let r = block(in: text) {
            guard String(text[r]) != snippet else { return "Headroom's instructions are already in \(url.path)." }
            out = text
            out.replaceSubrange(r, with: snippet)
        } else {
            out = text
            if !out.isEmpty { out += out.hasSuffix("\n\n") ? "" : out.hasSuffix("\n") ? "\n" : "\n\n" }
            out += snippet + "\n"
        }
        try write(out, to: url)
        return "Added Headroom's instructions to \(url.path)."
    }

    @discardableResult
    public static func remove(_ harness: AgentHarness, userHome: URL, environment: [String: String]) throws(HookInstaller.Failure) -> String {
        let url = fileURL(harness, userHome: userHome, environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return "No Headroom instructions in \(url.path)." }
        let text = try read(url)
        guard var r = block(in: text) else { return "No Headroom instructions in \(url.path)." }
        // Take the line break after the block, and one blank line before it, with it.
        if r.upperBound < text.endIndex, text[r.upperBound] == "\n" { r = r.lowerBound..<text.index(after: r.upperBound) }
        if text[..<r.lowerBound].hasSuffix("\n\n") { r = text.index(r.lowerBound, offsetBy: -1)..<r.upperBound }
        var out = text
        out.removeSubrange(r)
        try write(out, to: url)
        return "Removed Headroom's instructions from \(url.path)."
    }

    /// The block from its begin marker to the end of its end marker.
    static func block(in text: String) -> Range<String.Index>? {
        guard let first = text.range(of: begin), let e = text.range(of: end, range: first.upperBound..<text.endIndex) else { return nil }
        // The begin nearest that end: an earlier one left without its end isn't part of the block,
        // and what follows it is the person's own text.
        let b = text.range(of: begin, options: .backwards, range: first.lowerBound..<e.lowerBound) ?? first
        return b.lowerBound..<e.upperBound
    }

    static func read(_ url: URL) throws(HookInstaller.Failure) -> String {
        guard let data = FileManager.default.contents(atPath: url.path) else { return "" }
        guard let s = String(data: data, encoding: .utf8) else { throw HookInstaller.Failure("\(url.path) isn't UTF-8 text; left it alone.") }
        return s
    }

    static func write(_ text: String, to url: URL) throws(HookInstaller.Failure) {
        do { try SetupFiles.write(Data(text.utf8), to: url) } catch {
            throw HookInstaller.Failure("Could not write \(url.path): \(error.localizedDescription)")
        }
    }
}
