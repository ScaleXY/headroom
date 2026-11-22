import AppKit
import HeadroomKit
import notify

/// What a person can do to a run from the Mac: bring its session forward, copy a resume command,
/// hide it, close it. The Runs tab and the notification actions call these.
@MainActor
enum RunActions {
    /// Brings the app hosting the run's session to the front (its terminal, editor or the desktop
    /// app). Without one, opens the run's folder in the default terminal, else in Finder.
    static func openSession(_ run: TaskRun) {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications.compactMap(\.bundleIdentifier)
        let plan = RunHost.plan(host: run.host, cwd: run.cwd, running: running,
                                installed: { ws.urlForApplication(withBundleIdentifier: $0) != nil },
                                folderExists: isFolder)
        switch plan {
        case .activate(let id):
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
        case .launch(let id):
            guard let url = ws.urlForApplication(withBundleIdentifier: id) else { return }
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .openFolder(let path, let id):
            guard let app = ws.urlForApplication(withBundleIdentifier: id) else { ws.open(URL(fileURLWithPath: path, isDirectory: true)); return }
            ws.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .reveal(let path):
            ws.open(URL(fileURLWithPath: path, isDirectory: true))
        case .nothing:
            NSSound.beep()
        }
    }

    /// A folder, not a file by that name: opening a file would run a script or launch an app.
    nonisolated static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// `cd '<folder>' && claude --resume <id>` (or `codex resume <id>`), when the run can be resumed:
    /// its id is a session id and its harness is one Headroom knows.
    nonisolated static func resumeCommand(_ run: TaskRun) -> String? {
        guard UUID(uuidString: run.id) != nil else { return nil }
        let command: String
        switch TaskLimits.provider(named: run.harness) {
        case .claude?: command = "claude --resume \(run.id)"
        case .codex?: command = "codex resume \(run.id)"
        case nil: return nil
        }
        guard let cwd = run.cwd, !cwd.isEmpty else { return command }
        return "cd \(shellQuote(cwd)) && \(command)"
    }

    /// Single quotes, with any single quote inside closed, escaped and reopened.
    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func copyResumeCommand(_ run: TaskRun) {
        guard let command = resumeCommand(run) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
    }

    /// Writes `run.hide` to the run's journal as the user.
    static func hide(_ runID: String, hidden: Bool = true) {
        record(.hide(hidden), run: runID)
    }

    /// Closes the run: `run.abandon` in its journal, as the user (the event keeps its old name on disk).
    static func close(_ runID: String) {
        record(.abandon(reason: nil), run: runID)
    }

    /// Appends the event and tells the tracker to fold again. False when the id isn't a run id or
    /// the journal can't be written.
    @discardableResult
    nonisolated static func record(_ op: TaskEvent.Op, run: String, home: URL = SnapshotFile.directory, at: Date = Date(), notify: Bool = true) -> Bool {
        guard TaskRunID.sanitize(run) == run else { return false }
        do {
            try TaskJournal.append([TaskEvent(at: at, run: run, source: .user, op: op)], stream: .journal, home: home)
        } catch {
            return false
        }
        if notify { notify_post(TaskJournal.notification) }
        return true
    }
}

/// The app a session runs in, from what the hook recorded: a bundle id, or `$TERM_PROGRAM`.
enum RunHost {
    /// What `openSession` does.
    enum Plan: Equatable, Sendable {
        case activate(String)
        case launch(String)
        /// Open the folder with the app (a new terminal window there, or the editor's project).
        case openFolder(String, app: String)
        /// Show the folder in Finder.
        case reveal(String)
        case nothing
    }

    static let terminal = "com.apple.Terminal"

    /// Terminals by bundle id, most common first; the fallback for tmux and unknown hosts.
    static let terminals = [
        terminal, "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.alacritty", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
    ]

    /// `$TERM_PROGRAM` (lowercased) to the apps it may mean, most likely first.
    static let termPrograms: [String: [String]] = [
        "apple_terminal": [terminal],
        "iterm.app": ["com.googlecode.iterm2"],
        "ghostty": ["com.mitchellh.ghostty"],
        "warpterminal": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        "wezterm": ["com.github.wez.wezterm"],
        "kitty": ["net.kovidgoyal.kitty"],
        "alacritty": ["org.alacritty"],
        "hyper": ["co.zeit.hyper"],
        "tabby": ["org.tabby"],
        "rio": ["com.raphaelamorim.rio"],
        // VS Code and the editors built on it all say `vscode`; whichever is running wins.
        "vscode": ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.VSCodeInsiders", "com.vscodium"],
        "cursor": ["com.todesktop.230313mzl4w4u92"],
        "windsurf": ["com.exafunction.windsurf"],
        "zed": ["dev.zed.Zed", "dev.zed.Zed-Preview"],
        "claude": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex"],
    ]

    /// The apps `host` may mean, most likely first. `tmux` and `screen` say nothing about the
    /// terminal around them: any terminal will do.
    static func candidates(_ host: String?) -> [String] {
        guard let h = host?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return [] }
        let key = h.lowercased()
        if key == "tmux" || key == "screen" { return terminals }
        if let known = termPrograms[key] { return known }
        // A bundle id: reverse-DNS, no spaces.
        if h.contains("."), !h.contains(" "), !h.hasSuffix(".app") { return [h] }
        return []
    }

    static func plan(host: String?, cwd: String?, running: [String], installed: (String) -> Bool, folderExists: (String) -> Bool) -> Plan {
        let folder = cwd.flatMap { !$0.isEmpty && folderExists($0) ? $0 : nil }
        let options = candidates(host)
        if let id = options.first(where: running.contains) { return .activate(id) }
        if let id = options.first(where: installed) {
            // The session isn't there any more: start the app where the run worked, if it can take a folder.
            if let folder, terminals.contains(id) || isEditor(id) { return .openFolder(folder, app: id) }
            return .launch(id)
        }
        guard let folder else { return .nothing }
        let term = terminals.first(where: running.contains) ?? (installed(terminal) ? terminal : nil)
        return term.map { .openFolder(folder, app: $0) } ?? .reveal(folder)
    }

    static func isEditor(_ id: String) -> Bool {
        ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.VSCodeInsiders", "com.vscodium",
         "dev.zed.Zed", "dev.zed.Zed-Preview"].contains(id)
    }
}
