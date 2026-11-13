import Foundation
import Testing
@testable import HeadroomKit

/// The setup the app's Settings and `headroom hooks` share: always against temporary folders.
@Suite struct AgentSetupTests {
    final class Folder: @unchecked Sendable {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-setup-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func text(_ path: String) -> String? { try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
        func write(_ path: String, _ text: String) throws {
            let u = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
    }

    @Test func settingsURLHonoursTheHarnessVariables() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(HookInstaller.settingsURL(.claudeCode, userHome: home, environment: [:]).path == "/Users/me/.claude/settings.json")
        #expect(HookInstaller.settingsURL(.codex, userHome: home, environment: [:]).path == "/Users/me/.codex/hooks.json")
        #expect(HookInstaller.settingsURL(.claudeCode, userHome: home, environment: ["CLAUDE_CONFIG_DIR": "/cfg/claude"]).path == "/cfg/claude/settings.json")
        #expect(HookInstaller.settingsURL(.claudeCode, userHome: home, environment: ["CLAUDE_CONFIG_DIR": "~/alt"]).path == "/Users/me/alt/settings.json")
        #expect(HookInstaller.settingsURL(.codex, userHome: home, environment: ["CODEX_HOME": "/cfg/codex"]).path == "/cfg/codex/hooks.json")
        #expect(HookInstaller.settingsURL(.codex, userHome: home, environment: ["CODEX_HOME": "/x"], project: URL(fileURLWithPath: "/p")).path == "/p/.codex/hooks.json")
        #expect(AgentInstructions.fileURL(.codex, userHome: home, environment: ["CODEX_HOME": "/cfg/codex"]).path == "/cfg/codex/AGENTS.md")
        #expect(AgentInstructions.status(.claudeCode, userHome: home, environment: ["CLAUDE_CONFIG_DIR": "/nowhere"]).path == "/nowhere/CLAUDE.md")
    }

    @Test func installStatusAndUninstall() throws {
        let f = Folder()
        let home = f.url, store = f.url.appendingPathComponent("store")
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
          },
          "env": {"A": 1.50}
        }
        """
        try f.write(".claude/settings.json", original)
        var s = HookInstaller.status(.claudeCode, userHome: home, store: store, environment: [:])
        #expect(!s.installed && s.installedEvents == 0 && s.totalEvents == 7 && !s.unreadable && s.lastEventAt == nil)
        let said = try HookInstaller.install(.claudeCode, enforce: true, binary: "/bin/headroom", userHome: home, environment: [:])
        #expect(said.hasPrefix("Installed Headroom hooks in") && said.contains("backup: settings.json.headroom-backup"))
        #expect(f.text(".claude/settings.json.headroom-backup") == original)
        let written = try #require(f.text(".claude/settings.json"))
        // Key order, number text and two-space indentation survive.
        #expect(written.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"say done\""))
        #expect(written.contains("\"env\": {\n    \"A\": 1.50\n  }"))
        s = HookInstaller.status(.claudeCode, userHome: home, store: store, environment: [:])
        #expect(s.installed && s.enforcing && s.allowsReports)
        // Again: nothing written.
        let before = try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent(".claude/settings.json").path)[.modificationDate] as? Date
        #expect(try HookInstaller.install(.claudeCode, enforce: true, binary: "/bin/headroom", userHome: home, environment: [:]).contains("already installed"))
        #expect(try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent(".claude/settings.json").path)[.modificationDate] as? Date == before)
        // Heartbeat.
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        HookInstaller.recordHeartbeat(.claudeCode, at: t, store: store)
        #expect(HookInstaller.status(.claudeCode, userHome: home, store: store, environment: [:]).lastEventAt == t)
        #expect(HookInstaller.lastEvent(.codex, store: store) == nil)
        // Uninstall restores the user's content exactly (formatting aside).
        #expect(try HookInstaller.uninstall(.claudeCode, userHome: home, environment: [:]).hasPrefix("Removed"))
        let back = try OrderedJSON.parse(Data(try #require(f.text(".claude/settings.json")).utf8))
        #expect(back == (try OrderedJSON.parse(Data(original.utf8))))
        #expect(try HookInstaller.uninstall(.claudeCode, userHome: home, environment: [:]).hasPrefix("No Headroom hooks"))
        #expect(try HookInstaller.uninstall(.codex, userHome: home, environment: [:]).hasPrefix("No Headroom hooks"))
        // The backup is still the file from before Headroom.
        #expect(f.text(".claude/settings.json.headroom-backup") == original)
    }

    @Test func refusesWhatItCannotEditSafely() throws {
        let f = Folder()
        for bad in ["{ nope", "[]", #"{"hooks": "x"}"#, #"{"hooks": {"Stop": {"command": "x"}}}"#] {
            try f.write(".claude/settings.json", bad)
            #expect(throws: HookInstaller.Failure.self) { try HookInstaller.install(.claudeCode, enforce: false, binary: "headroom", userHome: f.url, environment: [:]) }
            #expect(f.text(".claude/settings.json") == bad)
        }
        try f.write(".claude/settings.json", "{ nope")
        #expect(HookInstaller.status(.claudeCode, userHome: f.url, store: f.url, environment: [:]).unreadable)
        // An odd permissions value is left alone; the hooks still go in.
        try f.write(".claude/settings.json", #"{"permissions": ["x"]}"#)
        _ = try HookInstaller.install(.claudeCode, enforce: false, binary: "headroom", userHome: f.url, environment: [:])
        let root = try OrderedJSON.parse(Data(try #require(f.text(".claude/settings.json")).utf8))
        #expect(root["permissions"] == .array([.string("x")]) && root["hooks"]?["SessionStart"] != nil)
    }

    @Test func writesThroughASymlink() throws {
        let f = Folder()
        try f.write("dotfiles/settings.json", "{}")
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent(".claude/settings.json").path,
                                                   withDestinationPath: f.url.appendingPathComponent("dotfiles/settings.json").path)
        _ = try HookInstaller.install(.claudeCode, enforce: false, binary: "headroom", userHome: f.url, environment: [:])
        let attrs = try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent(".claude/settings.json").path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(f.text("dotfiles/settings.json")?.contains("headroom task hook") == true)
        // The same for the instructions file.
        try f.write("dotfiles/CLAUDE.md", "# Mine\n")
        try FileManager.default.removeItem(at: f.url.appendingPathComponent(".claude/settings.json"))
        try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent(".claude/CLAUDE.md").path, withDestinationPath: "../dotfiles/CLAUDE.md")
        _ = try AgentInstructions.add(.claudeCode, userHome: f.url, environment: [:])
        #expect(f.text("dotfiles/CLAUDE.md")?.hasPrefix("# Mine\n\n<!-- headroom:begin -->") == true)
        #expect((try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent(".claude/CLAUDE.md").path))[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func instructionsAreIdempotent() throws {
        let f = Folder()
        let lines = AgentInstructions.snippet.split(separator: "\n")
        #expect(lines.first == "<!-- headroom:begin -->" && lines.last == "<!-- headroom:end -->" && lines.count - 2 <= 6)
        #expect(AgentInstructions.snippet.contains("headroom task guide"))
        // Created when missing.
        #expect(!AgentInstructions.status(.codex, userHome: f.url, environment: [:]).present)
        #expect(try AgentInstructions.add(.codex, userHome: f.url, environment: [:]).hasPrefix("Added"))
        #expect(f.text(".codex/AGENTS.md") == AgentInstructions.snippet + "\n")
        #expect(try AgentInstructions.add(.codex, userHome: f.url, environment: [:]).contains("already"))
        #expect(AgentInstructions.status(.codex, userHome: f.url, environment: [:]).present)
        #expect(try AgentInstructions.remove(.codex, userHome: f.url, environment: [:]).hasPrefix("Removed"))
        #expect(f.text(".codex/AGENTS.md") == "")
        #expect(try AgentInstructions.remove(.codex, userHome: f.url, environment: [:]).hasPrefix("No Headroom"))
        // Around the user's own text, which is left exactly; an older block is updated in place.
        let mine = "# Rules\n\nBe brief.\n"
        try f.write(".claude/CLAUDE.md", mine + "\n<!-- headroom:begin -->\nold words\n<!-- headroom:end -->\n\n## More\n")
        _ = try AgentInstructions.add(.claudeCode, userHome: f.url, environment: [:])
        #expect(f.text(".claude/CLAUDE.md") == mine + "\n" + AgentInstructions.snippet + "\n\n## More\n")
        _ = try AgentInstructions.remove(.claudeCode, userHome: f.url, environment: [:])
        #expect(f.text(".claude/CLAUDE.md") == mine + "\n## More\n")
        try f.write(".claude/CLAUDE.md", mine)
        _ = try AgentInstructions.add(.claudeCode, userHome: f.url, environment: [:])
        _ = try AgentInstructions.remove(.claudeCode, userHome: f.url, environment: [:])
        #expect(f.text(".claude/CLAUDE.md") == mine)
    }

    @Test func orderedJSONRoundTrips() throws {
        let text = #"{"z": [1, -2.5e3, true, null, "a\"b\\cé😀\n"], "a": {}, "m": []}"#
        let v = try OrderedJSON.parse(Data(text.utf8))
        #expect(v.members?.map(\.key) == ["z", "a", "m"])
        #expect(v["z"]?.elements?[4] == .string("a\"b\\cé😀\n"))
        #expect(v.serialized() == "{\n  \"z\": [\n    1,\n    -2.5e3,\n    true,\n    null,\n    \"a\\\"b\\\\cé😀\\n\"\n  ],\n  \"a\": {},\n  \"m\": []\n}")
        #expect(try OrderedJSON.parse(Data(v.serialized().utf8)) == v)
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "01x", "\"\u{01}\""] {
            #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(bad.utf8)) }
        }
        var o = OrderedJSON.object([.init("a", .number("1"))])
        o["b"] = .bool(true)
        o["a"] = .null
        #expect(o.members?.map(\.key) == ["a", "b"] && o["a"] == .null)
        o["a"] = nil
        #expect(o.members?.map(\.key) == ["b"])
    }
}
