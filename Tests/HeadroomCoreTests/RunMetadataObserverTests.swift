import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

@Suite struct RunMetadataObserverTests {
    private func track(_ id: String, in h: ObserverHome) throws {
        try TaskJournal.append([.init(at: Fx.t0, run: id, source: .agent, op: .add(.init(id: "work")))],
                               stream: .journal, home: h.home)
    }

    @Test func claudeUsesTheLatestCustomTitleAndBranchOnTheMainSession() async throws {
        let h = try ObserverHome()
        try h.logs.write("work/.git/config", """
        [remote "upstream"]
            url = https://github.example/fallback/other.git
        [remote "origin"]
            url = https://github.example/ScaleXY/headroom.git
        """)
        try h.logs.write("work/sub/file", "")
        try h.write("titles.jsonl", [
            Fx.assistant(1, "titles", id: "main", [Fx.agentCall("tu", "Helper description", prompt: "p")],
                         extra: ["cwd": h.logs.path("work/sub"), "gitBranch": "initial"]),
            Fx.user(2, "titles", Fx.toolResult("tu", "launched"), result: ["status": "async_launched", "agentId": "a1"]),
            Fx.json(["type": "ai-title", "sessionId": "titles", "aiTitle": "Harness title"]),
        ])
        try h.write("titles/subagents/agent-a1.jsonl", [
            Fx.assistant(3, "titles", id: "child", [Fx.text("Child message")], agent: "a1", extra: ["gitBranch": "child-branch"]),
            Fx.json(["type": "custom-title", "sessionId": "titles", "customTitle": "Child title"]),
        ])
        let observer = h.observer()
        _ = await observer.scan(since: Fx.t0)
        #expect(h.fold("titles")?.bestTitle == "Harness title")
        #expect(h.fold("titles")?.repo == "ScaleXY/headroom" && h.fold("titles")?.branch == "initial")
        #expect(h.events("titles").attempt("agent:a1")?.title == "Helper description")

        try h.append("titles.jsonl", [
            Fx.assistant(0.5, "titles", id: "older", []),
            Fx.json(["type": "custom-title", "sessionId": "titles", "customTitle": "Temporary title"]),
            Fx.json(["type": "custom-title", "sessionId": "titles", "customTitle": "New custom title"]),
            Fx.json(["type": "user", "sessionId": "titles", "gitBranch": "feature/titles", "message": ["role": "user", "content": "secret prompt"]]),
        ])
        #expect(await observer.ingest(paths: [h.path("titles.jsonl")]).events == 1)
        try h.append("titles.jsonl", [
            Fx.json(["type": "ai-title", "sessionId": "titles", "aiTitle": "Later harness title"]),
            Fx.json(["type": "agent-name", "sessionId": "titles", "agentName": "Ignored title"]),
        ])
        #expect(await observer.ingest(paths: [h.path("titles.jsonl")]).events == 0)
        #expect(h.fold("titles")?.bestTitle == "New custom title" && h.fold("titles")?.branch == "feature/titles")
        #expect(h.events("titles").ops("run.meta").count == 2)
        #expect(!h.allBytes().contains("secret prompt"))
    }

    /// Claude Code rewrites its own title as the session goes on: the latest one names the run.
    @Test func theLatestAITitleWins() async throws {
        let h = try ObserverHome()
        try h.write("retitled.jsonl", [
            // A session that spawned an agent is a run.
            Fx.assistant(1, "retitled", id: "m1", [Fx.agentCall("tu", "Helper", prompt: "p")]),
            Fx.user(2, "retitled", Fx.toolResult("tu", "launched"), result: ["status": "async_launched", "agentId": "a1"]),
            Fx.json(["type": "ai-title", "sessionId": "retitled", "aiTitle": "First guess"]),
            Fx.json(["type": "ai-title", "sessionId": "retitled", "aiTitle": "Fix the refund webhook"]),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.fold("retitled")?.sessionTitle == "Fix the refund webhook")
    }

    /// A long line (a tool result) isn't scanned for the branch; a short one gives it.
    @Test func theBranchComesFromShortLines() async throws {
        let h = try ObserverHome()
        let big = String(repeating: "x", count: 70 * 1024)
        try h.write("branch.jsonl", [
            // A session that spawned an agent is a run.
            Fx.assistant(1, "branch", id: "m1", [Fx.agentCall("tu", "Helper", prompt: "p")]),
            Fx.user(2, "branch", Fx.toolResult("tu", "launched"), result: ["status": "async_launched", "agentId": "a1"]),
            Fx.json(["type": "user", "sessionId": "branch", "message": ["role": "user", "content": "ok"], "gitBranch": "feature/short"]),
            Fx.json(["type": "user", "sessionId": "branch", "message": ["role": "user", "content": big], "gitBranch": "from-a-huge-line"]),
        ])
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.fold("branch")?.branch == "feature/short")
    }

    @Test(arguments: [
        "https://user:password@github.example/group/ScaleXY/headroom.git",
        "git@github.example:ScaleXY/headroom.git",
        "ssh://git@github.example:2222/group/ScaleXY/headroom",
    ])
    func claudeReadsRemoteURLFormsAndCachesTheResult(_ remote: String) async throws {
        let h = try ObserverHome()
        let config = "work/.git/config"
        try h.logs.write(config, "[remote \"upstream\"]\nurl = \"\(remote)\"\n")
        try track("repo-test", in: h)
        try h.write("repo-test.jsonl", [
            Fx.assistant(1, "repo-test", id: "first", [], extra: ["cwd": h.logs.path("work")]),
        ])
        let observer = h.observer()
        _ = await observer.scan(since: Fx.t0)
        #expect(h.fold("repo-test")?.repo == "ScaleXY/headroom")
        #expect(!h.allBytes().contains(remote))

        try h.logs.write(config, "[remote \"origin\"]\nurl = git@github.example:other/repo.git\n")
        try h.append("repo-test.jsonl", [Fx.json(["type": "ai-title", "sessionId": "repo-test", "aiTitle": "Renamed"])])
        _ = await observer.ingest(paths: [h.path("repo-test.jsonl")])
        #expect(h.fold("repo-test")?.repo == "ScaleXY/headroom")
    }

    @Test func claudeFollowsWorktreeCommonDirectoriesAndHandlesNoGit() async throws {
        let h = try ObserverHome()
        try h.logs.write("primary/.git/config", "[remote \"origin\"]\nurl = git@github.example:ScaleXY/headroom.git\n")
        try h.logs.write("primary/.git/worktrees/feature/commondir", "../..\n")
        try h.logs.write("feature/.git", "gitdir: ../primary/.git/worktrees/feature\n")
        try h.logs.write("plain/file", "")
        for id in ["feature", "plain"] {
            try track(id, in: h)
            try h.write(id + ".jsonl", [Fx.assistant(1, id, id: "first", [], extra: ["cwd": h.logs.path(id)])])
        }
        _ = await h.observer().scan(since: Fx.t0)
        #expect(h.fold("feature")?.repo == "ScaleXY/headroom")
        let plain = try #require(h.fold("plain"))
        #expect(plain.repo == nil)
    }

    @Test func olderObserverCursorsBackfillMetadataWithoutReplayingActivity() async throws {
        let h = try ObserverHome()
        let id = "older"
        let file = id + ".jsonl"
        try track(id, in: h)
        try h.write(file, [Fx.assistant(1, id, id: "first", tokens: 10, [])])
        _ = await h.observer().scan(since: Fx.t0)
        let original = try #require(h.fold(id))

        // Simulate a v1 cursor already past metadata lines its reader ignored.
        try h.append(file, [Fx.json(["type": "ai-title", "sessionId": id, "aiTitle": "Existing session title"])])
        let url = TaskObserver.stateURL(home: h.home)
        var saved = try PropertyListDecoder().decode(ObserverState.self, from: Data(contentsOf: url))
        let path = try #require(saved.files.keys.first)
        saved.files[path]?.readRunMetadata = nil
        saved.files[path]?.offset = Int64(try Data(contentsOf: URL(fileURLWithPath: path)).count)
        try PropertyListEncoder().encode(saved).write(to: url)

        let report = await h.observer().scan(since: .distantFuture)
        let updated = try #require(h.fold(id))
        #expect(report.events == 1 && updated.bestTitle == "Existing session title")
        #expect(updated.tokens == original.tokens && updated.updatedAt == original.updatedAt)
    }

    @Test func codexReadsTitlesIncrementallyAcrossRestartsAndFileChanges() async throws {
        let h = try ObserverHome()
        let rollout = ".codex/sessions/2026/10/10/rollout-titles.jsonl"
        let index = ".codex/session_index.jsonl"
        let id = "codex-titles"
        func entry(_ name: String, id: String = "codex-titles") -> String {
            Fx.json(["id": id, "thread_name": name, "updated_at": Fx.ts(0)])
        }
        try h.logs.write(index, entry("Initial title") + entry("Other thread", id: "different"))
        let observer = h.observer()
        // The title can be indexed before the rollout is found.
        #expect(await observer.ingest(paths: []).events == 0)
        try track(id, in: h)
        try h.logs.write(rollout, #"{"timestamp":"\#(Fx.ts(1))","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/headroom","git":{"branch":"feature/titles","commit_hash":"abc","repository_url":"ssh://git@github.example/ScaleXY/headroom.git"}}}"# + "\n")
        _ = await observer.ingest(paths: [h.logs.path(rollout)])
        #expect(h.fold(id)?.bestTitle == "Initial title")
        #expect(h.fold(id)?.repo == "ScaleXY/headroom" && h.fold(id)?.branch == "feature/titles")
        await observer.flush()

        let restarted = h.observer()
        #expect(await restarted.ingest(paths: [h.logs.path(index)]).events == 0)
        try h.logs.append(index, String(entry("Newer title").dropLast()))
        #expect(await restarted.poll().events == 0)
        try h.logs.append(index, "\n")
        #expect(await restarted.poll().events == 1)
        #expect(h.fold(id)?.bestTitle == "Newer title")
        #expect(await restarted.ingest(paths: [h.logs.path(index)]).events == 0)

        // A shorter file on the same inode, then an atomic replacement with a larger file.
        try h.logs.write(index, entry("Short file title"))
        #expect(await restarted.poll().events == 1)
        let replacement = entry("Different thread in a larger replacement file", id: "other") + entry("Replaced file title")
        try Data(replacement.utf8).write(to: URL(fileURLWithPath: h.logs.path(index)), options: .atomic)
        #expect(await restarted.poll().events == 1)
        #expect(h.fold(id)?.bestTitle == "Replaced file title")
        #expect(h.events(id).ops("run.meta").count == 4)
        #expect(await restarted.poll().events == 0)
    }
}
