import Foundation

// Contract stubs for the in-app setup (Settings › Runs) and `headroom hooks`. The CLI workstream
// moves the installer here from `HeadroomCLI/Hooks.swift` and fills these in; the app calls them.
// `userHome` is the person's home folder (where `.claude` and `.codex` live); `store` is
// Headroom's own folder (`SnapshotFile.directory`), where the hook heartbeat is kept.

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

    public init(path: String, installedEvents: Int = 0, totalEvents: Int = 0, enforcing: Bool = false, lastEventAt: Date? = nil, unreadable: Bool = false) {
        self.path = path; self.installedEvents = installedEvents; self.totalEvents = totalEvents; self.enforcing = enforcing
        self.lastEventAt = lastEventAt; self.unreadable = unreadable
    }

    public var installed: Bool { totalEvents > 0 && installedEvents == totalEvents }
}

public enum HookInstaller {
    public struct Failure: Error, Sendable { public var message: String; public init(_ message: String) { self.message = message } }

    /// Where the harness keeps its hooks: honours `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
    public static func settingsURL(_ harness: AgentHarness, userHome: URL, environment: [String: String], project: URL? = nil) -> URL {
        let base = project ?? userHome
        return base.appendingPathComponent(harness == .codex ? ".codex/hooks.json" : ".claude/settings.json")
    }

    public static func status(_ harness: AgentHarness, userHome: URL, store: URL, environment: [String: String]) -> HookInstallStatus {
        HookInstallStatus(path: settingsURL(harness, userHome: userHome, environment: environment).path)
    }

    /// Installs (or updates) Headroom's hooks, backing the file up first. Returns what it did, in a sentence.
    @discardableResult
    public static func install(_ harness: AgentHarness, enforce: Bool, binary: String, userHome: URL, environment: [String: String]) throws(Failure) -> String {
        throw Failure("not implemented")
    }

    @discardableResult
    public static func uninstall(_ harness: AgentHarness, userHome: URL, environment: [String: String]) throws(Failure) -> String {
        throw Failure("not implemented")
    }

    /// The `headroom` binary hooks should run: one on the PATH that survives app updates, else nil.
    public static func defaultBinary(userHome: URL) -> String? { nil }

    /// Notes that a hook for `harness` just ran (called by `headroom task hook`).
    public static func recordHeartbeat(_ harness: AgentHarness, at: Date, store: URL) {}
}

/// The few lines that ask an agent to report progress (`headroom task guide`), kept in the
/// harness's global instructions file: `~/.claude/CLAUDE.md` for Claude Code, `~/.codex/AGENTS.md` for Codex.
public enum AgentInstructions {
    public struct Status: Sendable, Hashable {
        public var path: String
        public var present: Bool
        public init(path: String, present: Bool) { self.path = path; self.present = present }
    }

    public static let snippet = ""

    public static func status(_ harness: AgentHarness, userHome: URL, environment: [String: String]) -> Status {
        Status(path: userHome.appendingPathComponent(harness == .codex ? ".codex/AGENTS.md" : ".claude/CLAUDE.md").path, present: false)
    }

    @discardableResult
    public static func add(_ harness: AgentHarness, userHome: URL, environment: [String: String]) throws(HookInstaller.Failure) -> String {
        throw HookInstaller.Failure("not implemented")
    }

    @discardableResult
    public static func remove(_ harness: AgentHarness, userHome: URL, environment: [String: String]) throws(HookInstaller.Failure) -> String {
        throw HookInstaller.Failure("not implemented")
    }
}
