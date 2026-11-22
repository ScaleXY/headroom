import Foundation
import HeadroomKit
import Testing

@Suite struct RunMetadataTests {
    @Test func journalRoundTripPreservesTheOldWireFormat() throws {
        let old = #"""
        {"harness":"codex","op":"run.meta","project":"headroom","run":"run1","src":"harness","ts":"2026-11-12T10:00:00.000Z","v":1}
        """# + "\n"
        let original = try #require(TaskJournal.decode(Data(old.utf8)).first)
        #expect(original.op == .meta(title: nil, project: "headroom", harness: "codex"))
        #expect(String(decoding: try TaskJournal.line(original), as: UTF8.self) == old)

        var event = original
        event.op = .meta(title: nil, project: "headroom", harness: "codex", sessionTitle: "Improve run titles",
                         repo: "ScaleXY/headroom", branch: "main")
        let bytes = try TaskJournal.line(event)
        let json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(json["session_title"] as? String == "Improve run titles")
        #expect(json["repo"] as? String == "ScaleXY/headroom" && json["branch"] as? String == "main")
        #expect(TaskJournal.decode(bytes) == [event])
    }

    @Test func metadataFoldsFieldByFieldAndDeclaredTitlesWin() throws {
        let now = Date(timeIntervalSince1970: 100)
        func event(_ offset: Double, _ op: TaskEvent.Op, source: TaskSource = .harness) -> TaskEvent {
            .init(at: now.addingTimeInterval(offset), run: "run1", source: source, op: op)
        }
        let repo = "ScaleXY/" + String(repeating: "r", count: 450)
        let base = [
            event(0, .meta(title: nil, project: "headroom", harness: "codex", sessionTitle: "Initial",
                           repo: "old/repo", branch: "old-branch")),
            event(2, .meta(title: nil, project: nil, harness: nil, sessionTitle: "Fix\ttitles", repo: repo)),
            event(3, .meta(title: nil, project: nil, harness: nil, branch: " main\n")),
        ]
        let run = try #require(TaskFold.fold(base, now: now.addingTimeInterval(8)).first)
        #expect(run.bestTitle == "Fix titles" && run.agentTitle == nil)
        #expect(run.repo?.count == 400 && run.repo?.hasPrefix("ScaleXY/") == true && run.branch == "main")
        let declared = event(1, .meta(title: "Declared title", project: nil, harness: nil), source: .agent)
        let named = try #require(TaskFold.fold(base + [declared], now: now.addingTimeInterval(8)).first)
        #expect(named.bestTitle == "Declared title" && named.sessionTitle == "Fix titles")
        let feedBytes = try TasksFile.encoder().encode(named)
        #expect(try TasksFile.decoder().decode(TaskRun.self, from: feedBytes) == named)
    }

    @Test func oldTaskRunJSONDecodesAndIdentifiersArentTitles() throws {
        let old = #"""
        {"id":"run1","title":"run1","project":"headroom","started_at":"2026-11-12T10:00:00Z",
         "updated_at":"2026-11-12T10:00:00Z","state":"running","stale":false,
         "progress":{"done":0,"in_flight":0,"estimate":0},"must_haves":{"done":0,"total":0},"tokens":0,"scope_changes":0,"nodes":[]}
        """#
        var run = try TasksFile.decoder().decode(TaskRun.self, from: Data(old.utf8))
        #expect(run.sessionTitle == nil && run.repo == nil && run.branch == nil && run.bestTitle == nil)
        run.sessionTitle = run.id
        #expect(run.bestTitle == nil)
        run.sessionTitle = UUID().uuidString
        #expect(run.bestTitle == nil)
    }
}
