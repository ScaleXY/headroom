import Foundation
import HeadroomKit

/// Where in-app setup reads and writes: the person's home (where `.claude` and `.codex` live),
/// Headroom's own folder (the hook heartbeat) and the environment (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
struct AgentSetupContext: Sendable {
    var userHome: URL
    var store: URL
    var environment: [String: String]

    static var current: AgentSetupContext {
        AgentSetupContext(userHome: FileManager.default.homeDirectoryForCurrentUser, store: SnapshotFile.directory,
                          environment: ProcessInfo.processInfo.environment)
    }
}

/// What Settings › Runs › Connect your agents knows about this Mac: each harness, its hooks and
/// instructions, and the `headroom` binary hooks would run.
struct AgentSetupState: Equatable, Sendable {
    struct Harness: Equatable, Sendable {
        var harness: AgentHarness
        /// The harness's folder exists: it's set up on this Mac.
        var present: Bool
        var hooks: HookInstallStatus
        var instructions: AgentInstructions.Status
    }

    var harnesses: [Harness]
    /// The `headroom` hooks run: one on the PATH that survives app updates, else the one inside
    /// Headroom.app; nil when there's neither.
    var binary: String?

    static func read(_ c: AgentSetupContext, bundledCLI: String?) -> AgentSetupState {
        let harnesses = AgentHarness.allCases.map { h in
            let settings = HookInstaller.settingsURL(h, userHome: c.userHome, environment: c.environment)
            return Harness(harness: h, present: FileManager.default.fileExists(atPath: settings.deletingLastPathComponent().path),
                           hooks: HookInstaller.status(h, userHome: c.userHome, store: c.store, environment: c.environment),
                           instructions: AgentInstructions.status(h, userHome: c.userHome, environment: c.environment))
        }
        return AgentSetupState(harnesses: harnesses, binary: HookInstaller.defaultBinary(userHome: c.userHome) ?? bundledCLI)
    }

    var present: [Harness] { harnesses.filter(\.present) }
    /// Harnesses with any Headroom hook in place.
    var hooked: [Harness] { present.filter { $0.hooks.installedEvents > 0 } }
    var enforcing: Bool { !hooked.isEmpty && hooked.allSatisfy(\.hooks.enforcing) }
}

/// One row of "Connect your agents": what it is, what it will change, and its control.
struct ConnectRow: Equatable {
    enum Kind: Hashable { case hooks(AgentHarness), instructions, enforce }
    enum Health: Equatable { case good, partial, off, unavailable }

    var kind: Kind
    var title: String
    var detail: String
    var health: Health
    /// The button; nil for the switch row.
    var button: String?
    /// The switch, for the switch row.
    var on = false
    var enabled = true

    /// "~/.claude/settings.json" for paths under the home folder.
    static func tilde(_ path: String, home: URL) -> String {
        let h = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }

    static func rows(_ s: AgentSetupState, home: URL, now: Date) -> [ConnectRow] {
        var out = s.harnesses.map { hooksRow($0, binary: s.binary, home: home, now: now) }
        out.append(instructionsRow(s, home: home))
        let hooked = !s.hooked.isEmpty
        out.append(ConnectRow(kind: .enforce, title: "Send back unfinished tasks",
                              detail: hooked ? "Once per stop, while a task is still marked running." : "Needs the alerts above.",
                              health: s.enforcing ? .good : .off, button: nil, on: s.enforcing, enabled: hooked && s.binary != nil))
        return out
    }

    static func hooksRow(_ h: AgentSetupState.Harness, binary: String?, home: URL, now: Date) -> ConnectRow {
        let name = h.harness.displayName
        let path = tilde(h.hooks.path, home: home)
        let file = (h.hooks.path as NSString).lastPathComponent
        var row = ConnectRow(kind: .hooks(h.harness), title: "\(name) alerts", detail: "", health: .off, button: "Install")
        let st = h.hooks
        if !h.present {
            row.detail = "\(name) isn't set up on this Mac."
            row.health = .unavailable
            row.enabled = false
        } else if st.unreadable {
            row.detail = "\(path) isn't JSON Headroom can safely edit."
            row.health = .partial
            row.enabled = false
        } else if st.installed {
            let heard = st.lastEventAt.map { at -> String in
                let ago = TimeFormat.freshness(since: at, now: now)
                return ago == "now" ? "last event just now" : "last event \(ago) ago"
            } ?? "no events yet"
            row.detail = "Hooks in \(path) · \(heard)"
            row.health = st.lastEventAt == nil ? .partial : .good
            row.button = "Remove"
        } else if binary == nil {
            row.detail = "Needs the headroom command (Advanced)."
            row.enabled = false
        } else if st.installedEvents > 0 {
            row.detail = "\(st.installedEvents) of \(st.totalEvents) hooks in \(path)"
            row.health = .partial
            row.button = "Repair"
        } else {
            row.detail = "Adds hooks to \(path), backup in \(file).headroom-backup"
        }
        return row
    }

    static func instructionsRow(_ s: AgentSetupState, home: URL) -> ConnectRow {
        let present = s.present
        var row = ConnectRow(kind: .instructions, title: "Have agents report progress", detail: "", health: .off, button: "Add")
        guard !present.isEmpty else {
            row.detail = "Needs Claude Code or Codex on this Mac."
            row.health = .unavailable
            row.enabled = false
            return row
        }
        // File names only: the harness folders are the ones the alerts rows name.
        let files = { (list: [AgentSetupState.Harness]) in list.map { ($0.instructions.path as NSString).lastPathComponent }.joined(separator: " and ") }
        let have = present.filter(\.instructions.present), missing = present.filter { !$0.instructions.present }
        let lines = AgentInstructions.snippet.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let what = lines > 0 ? "\(lines) line\(lines == 1 ? "" : "s")" : "a few lines"
        if missing.isEmpty {
            row.detail = "In \(files(have)): agents report as they go."
            row.health = .good
            row.button = "Remove"
        } else if have.isEmpty {
            row.detail = "Adds \(what) to \(files(missing)), asking agents to report."
        } else {
            row.detail = "In \(files(have)); adds \(what) to \(files(missing))."
            row.health = .partial
        }
        return row
    }
}

/// What the Connect rows do, on the main actor (small file edits in the person's agent settings).
@MainActor
enum AgentSetupActions {
    /// Runs `kind`'s action against `state`. Returns the sentences the installers wrote, or the error.
    static func perform(_ kind: ConnectRow.Kind, state s: AgentSetupState, context c: AgentSetupContext) -> (message: String, failed: Bool) {
        var done: [String] = []
        do throws(HookInstaller.Failure) {
            switch kind {
            case .hooks(let h):
                guard let harness = s.harnesses.first(where: { $0.harness == h }) else { return ("", false) }
                if harness.hooks.installed {
                    done.append(try HookInstaller.uninstall(h, userHome: c.userHome, environment: c.environment))
                } else {
                    guard let binary = s.binary else { throw HookInstaller.Failure("Install the headroom command first (Advanced › Command line).") }
                    // A new harness follows the others' choice on sending tasks back.
                    done.append(try HookInstaller.install(h, enforce: s.enforcing, binary: binary, userHome: c.userHome, environment: c.environment))
                }
            case .instructions:
                let present = s.present
                if present.allSatisfy(\.instructions.present) {
                    for p in present { done.append(try AgentInstructions.remove(p.harness, userHome: c.userHome, environment: c.environment)) }
                } else {
                    for p in present where !p.instructions.present {
                        done.append(try AgentInstructions.add(p.harness, userHome: c.userHome, environment: c.environment))
                    }
                }
            case .enforce:
                guard let binary = s.binary else { throw HookInstaller.Failure("Install the headroom command first (Advanced › Command line).") }
                let enforce = !s.enforcing
                for h in s.hooked {
                    done.append(try HookInstaller.install(h.harness, enforce: enforce, binary: binary, userHome: c.userHome, environment: c.environment))
                }
            }
        } catch {
            return ((done + [error.message]).filter { !$0.isEmpty }.joined(separator: " "), true)
        }
        return (done.filter { !$0.isEmpty }.joined(separator: " "), false)
    }
}
