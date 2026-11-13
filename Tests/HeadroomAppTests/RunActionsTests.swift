import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit

@Suite struct RunActionsTests {
    let session = "2f6c1a3e-8d1b-4c55-9a43-0e6f4b9d7a21"

    func run(id: String? = nil, harness: String? = "claude-code", cwd: String? = "/Users/me/code/storefront", host: String? = nil) -> TaskRun {
        TaskRun(id: id ?? session, title: "Move checkout", harness: harness, startedAt: Date(), updatedAt: Date(), state: .stopped, host: host, cwd: cwd)
    }

    @Test func resumeCommands() {
        #expect(RunActions.resumeCommand(run()) == "cd '/Users/me/code/storefront' && claude --resume \(session)")
        #expect(RunActions.resumeCommand(run(harness: "codex")) == "cd '/Users/me/code/storefront' && codex resume \(session)")
        #expect(RunActions.resumeCommand(run(harness: "claude")) == "cd '/Users/me/code/storefront' && claude --resume \(session)")
        // No folder: the command alone.
        #expect(RunActions.resumeCommand(run(cwd: nil)) == "claude --resume \(session)")
        // Not a session id, or a harness Headroom doesn't know.
        #expect(RunActions.resumeCommand(run(id: "nightly-release")) == nil)
        #expect(RunActions.resumeCommand(run(harness: "aider")) == nil)
        #expect(RunActions.resumeCommand(run(harness: nil)) == nil)
    }

    @Test func foldersAreQuotedSafely() {
        let odd = "/Users/me/it's $HOME; `rm -rf` \"x\""
        let command = RunActions.resumeCommand(run(cwd: odd))
        #expect(command == #"cd '/Users/me/it'\''s $HOME; `rm -rf` "x"' && claude --resume "# + session)
        #expect(RunActions.shellQuote("") == "''")
        #expect(RunActions.shellQuote("a b") == "'a b'")
    }

    @Test func hostsMapToApps() {
        #expect(RunHost.candidates("Apple_Terminal") == ["com.apple.Terminal"])
        #expect(RunHost.candidates("iTerm.app") == ["com.googlecode.iterm2"])
        #expect(RunHost.candidates("WarpTerminal").first == "dev.warp.Warp-Stable")
        #expect(RunHost.candidates("ghostty") == ["com.mitchellh.ghostty"])
        #expect(RunHost.candidates("vscode").first == "com.microsoft.VSCode")
        #expect(RunHost.candidates("com.googlecode.iterm2") == ["com.googlecode.iterm2"])
        #expect(RunHost.candidates("tmux") == RunHost.terminals)
        #expect(RunHost.candidates("something odd").isEmpty && RunHost.candidates(nil).isEmpty)
    }

    @Test func openPlans() {
        let all: (String) -> Bool = { _ in true }
        let folder = "/Users/me/code/storefront"
        func plan(_ host: String?, cwd: String? = folder, running: [String] = [], installed: @escaping (String) -> Bool = all, exists: Bool = true) -> RunHost.Plan {
            RunHost.plan(host: host, cwd: cwd, running: running, installed: installed, folderExists: { _ in exists })
        }
        // The host is running: bring it forward.
        #expect(plan("iTerm.app", running: ["com.googlecode.iterm2"]) == .activate("com.googlecode.iterm2"))
        // `vscode` from Cursor: whichever of the VS Code family is running.
        #expect(plan("vscode", running: ["com.todesktop.230313mzl4w4u92"]) == .activate("com.todesktop.230313mzl4w4u92"))
        // tmux: the terminal that's open.
        #expect(plan("tmux", running: ["com.mitchellh.ghostty"]) == .activate("com.mitchellh.ghostty"))
        // Not running any more: a terminal or editor opens the folder, other apps just launch.
        #expect(plan("ghostty") == .openFolder(folder, app: "com.mitchellh.ghostty"))
        #expect(plan("com.anthropic.claudefordesktop") == .launch("com.anthropic.claudefordesktop"))
        // Unknown host: the folder in the terminal that's open, else Terminal, else Finder.
        #expect(plan(nil, running: ["com.googlecode.iterm2"]) == .openFolder(folder, app: "com.googlecode.iterm2"))
        #expect(plan(nil) == .openFolder(folder, app: "com.apple.Terminal"))
        #expect(plan(nil, installed: { _ in false }) == .reveal(folder))
        #expect(plan(nil, exists: false) == .nothing)
    }

    @Test func hideAndAbandonGoToTheJournalAsTheUser() throws {
        let h = TaskHome()
        try h.add(session, 0, .add(.init(id: "a")))
        #expect(RunActions.record(.hide(true), run: session, home: h.url, notify: false))
        #expect(RunActions.record(.abandon(reason: nil), run: session, home: h.url, notify: false))
        #expect(!RunActions.record(.hide(true), run: "../escape", home: h.url, notify: false))
        let events = TaskJournal.read(run: session, home: h.url)
        #expect(events.suffix(2).map(\.op.name) == ["run.hide", "run.abandon"])
        #expect(events.suffix(2).allSatisfy { $0.source == .user })
    }
}
