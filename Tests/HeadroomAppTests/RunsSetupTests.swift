import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit

/// Settings › Runs › Connect your agents: what each row says it will change.
@Suite struct RunsSetupTests {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func harness(_ h: AgentHarness, present: Bool = true, installed: Int = 0, enforcing: Bool = false, heard: TimeInterval? = nil,
                 unreadable: Bool = false, instructions: Bool = false) -> AgentSetupState.Harness {
        let dir = h == .codex ? ".codex" : ".claude"
        return .init(harness: h, present: present,
                     hooks: HookInstallStatus(path: "/Users/me/\(dir)/\(h == .codex ? "hooks.json" : "settings.json")", installedEvents: installed,
                                              totalEvents: 6, enforcing: enforcing, lastEventAt: heard.map { now.addingTimeInterval(-$0) }, unreadable: unreadable),
                     instructions: .init(path: "/Users/me/\(dir)/\(h == .codex ? "AGENTS.md" : "CLAUDE.md")", present: instructions))
    }

    func rows(_ hs: [AgentSetupState.Harness], binary: String? = "/Users/me/.local/bin/headroom") -> [ConnectRow] {
        ConnectRow.rows(AgentSetupState(harnesses: hs, binary: binary), home: home, now: now)
    }

    @Test func freshMac() {
        let r = rows([harness(.claudeCode), harness(.codex, present: false)])
        #expect(r.map(\.title) == ["Claude Code alerts", "Codex alerts", "Have agents report progress", "Send back unfinished tasks"])
        #expect(r[0].button == "Install" && r[0].enabled)
        #expect(r[0].detail == "Adds hooks to ~/.claude/settings.json, backup in settings.json.headroom-backup")
        #expect(r[1].health == .unavailable && !r[1].enabled && r[1].detail == "Codex isn't set up on this Mac.")
        #expect(r[2].button == "Add" && r[2].detail.contains("CLAUDE.md") && !r[2].detail.contains("AGENTS.md"))
        // Nothing to send back without hooks.
        #expect(r[3].button == nil && !r[3].enabled && !r[3].on)
    }

    @Test func connectedAndHeardFrom() {
        let r = rows([harness(.claudeCode, installed: 6, enforcing: true, heard: 120, instructions: true),
                      harness(.codex, installed: 6, enforcing: true, heard: nil, instructions: true)])
        #expect(r[0].detail == "Hooks in ~/.claude/settings.json · last event 2m ago" && r[0].health == .good && r[0].button == "Remove")
        // Installed but never fired: worth a look.
        #expect(r[1].detail == "Hooks in ~/.codex/hooks.json · no events yet" && r[1].health == .partial)
        #expect(r[2].button == "Remove" && r[2].health == .good && r[2].detail.hasPrefix("In CLAUDE.md and AGENTS.md"))
        #expect(r[3].on && r[3].enabled)
    }

    @Test func partlyInstalledAndBroken() {
        let r = rows([harness(.claudeCode, installed: 4), harness(.codex, unreadable: true)])
        #expect(r[0].button == "Repair" && r[0].health == .partial && r[0].detail.hasPrefix("4 of 6 hooks in ~/.claude/settings.json"))
        #expect(!r[1].enabled && r[1].detail.contains("isn't JSON Headroom can safely edit"))
        // One harness enforcing and one not reads as off.
        let mixed = rows([harness(.claudeCode, installed: 6, enforcing: true), harness(.codex, installed: 6)])
        #expect(!mixed[3].on)
    }

    @Test func withoutTheCommand() {
        let r = rows([harness(.claudeCode), harness(.codex)], binary: nil)
        #expect(!r[0].enabled && r[0].detail.contains("headroom command"))
        // Removing still works without it.
        #expect(rows([harness(.claudeCode, installed: 6)], binary: nil)[0].enabled)
    }

    @Test func pathsOutsideHomeStayWhole() {
        #expect(ConnectRow.tilde("/Users/me/.claude/settings.json", home: home) == "~/.claude/settings.json")
        #expect(ConnectRow.tilde("/opt/claude/settings.json", home: home) == "/opt/claude/settings.json")
        #expect(ConnectRow.tilde("/Users/meg/.claude/settings.json", home: home) == "/Users/meg/.claude/settings.json")
    }

    @MainActor @Test func installerErrorsComeBackInline() {
        // The installer reports its own failures (here, a home with nothing to edit).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let context = AgentSetupContext(userHome: tmp, store: tmp, environment: [:])
        let state = AgentSetupState(harnesses: [harness(.claudeCode)], binary: nil)
        let result = AgentSetupActions.perform(.hooks(.claudeCode), state: state, context: context)
        #expect(result.failed && result.message.contains("headroom command"))
    }
}
