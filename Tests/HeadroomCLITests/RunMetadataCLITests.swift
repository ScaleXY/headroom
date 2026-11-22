import HeadroomKit
import Testing

@Suite struct RunMetadataCLITests {
    @Test func tasksShowsTheSessionTitleAndGitDetails() throws {
        let h = Home()
        try TaskJournal.append([
            .init(at: h.now, run: "r1", source: .harness, op: .meta(title: nil, project: "project-folder", harness: "codex",
                                                                 sessionTitle: "Improve run titles", repo: "ScaleXY/headroom", branch: "topic/titles")),
            .init(at: h.now, run: "r1", source: .harness, op: .attempt(.init(key: "session:r1", kind: .session))),
        ], stream: .observed, home: h.url)
        let (code, output) = h.run(["tasks", "--run", "r1"])
        #expect(code == 0 && output.split(separator: "\n").first?.contains("Improve run titles") == true)
        #expect(output.contains("project-folder") && output.contains("ScaleXY/headroom") && output.contains("topic/titles"))
        #expect(h.run(["task", "status"]).1.contains("run r1 \"Improve run titles\""))
    }
}
