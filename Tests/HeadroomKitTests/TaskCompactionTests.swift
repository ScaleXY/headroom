import Foundation
import Testing
@testable import HeadroomKit

@Suite struct TaskCompactionTests {
    /// Three agents spawned two days ago (one of them spawning two more), and one still running.
    func longRun() -> TL {
        var tl = TL()
        tl.at(0, .attempt(.init(key: "session:1", kind: .session)), .harness)
        tl.attempt(1, "agent:a", parent: "session:1")
        tl.attempt(2, "agent:b", parent: "session:1")
        tl.attempt(3, "agent:c", parent: "agent:a")
        tl.attempt(4, "agent:d", parent: "agent:a")
        tl.attempt(5, "agent:e", parent: "session:1")
        for (s, k) in [(10.0, "agent:c"), (11, "agent:d"), (12, "agent:a")] { tl.at(s, .attemptEnd(attempt: k, outcome: .ok), .harness) }
        tl.at(13, .attemptEnd(attempt: "agent:e", outcome: .error), .harness)
        tl.attempt(2 * 86400, "agent:f", parent: "session:1")
        return tl
    }

    @Test func dropsOldFinishedLeavesDeepestFirst() {
        let run = longRun().fold(2 * 86400 + 60)
        let now = TL.t(2 * 86400 + 60)
        let c = TaskCompaction.compact(run, now: now)
        // a went with its two agents; the failed e stays; b (running) and f (new) stay.
        #expect(c.nodes.map(\.id) == ["~agent-b", "~agent-e", "~agent-f"])
        #expect(c.finishedEarlier == 3)
        #expect(c.progress == run.progress && c.state == run.state && c.tokens == run.tokens && c.etaSeconds == run.etaSeconds)
        // Compacting again keeps the count.
        #expect(TaskCompaction.compact(c, now: now) == c)
        // Within a day nothing goes.
        #expect(TaskCompaction.compact(run, now: TL.t(3600)).finishedEarlier == nil)
    }

    @Test func aParentWithAnAgentLeftStays() {
        var tl = longRun()
        tl.attempt(2 * 86400, "agent:g", parent: "agent:a")
        let c = TaskCompaction.compact(tl.fold(2 * 86400 + 60), now: TL.t(2 * 86400 + 60))
        #expect(c.nodes.map(\.id).contains("~agent-a") && c.nodes.map(\.id).contains("~agent-g"))
        #expect(c.finishedEarlier == 2)
    }

    @Test func declaredRunsAreLeftAlone() {
        var tl = TL()
        tl.add(0, "a")
        tl.at(1, .done(task: "a", evidence: nil))
        tl.add(2, "b")
        let run = tl.fold(3 * 86400)
        #expect(TaskCompaction.compact(run, now: TL.t(3 * 86400)) == run)
    }

    @Test func theCountRoundTripsAndIsOptional() throws {
        let c = TaskCompaction.compact(longRun().fold(2 * 86400 + 60), now: TL.t(2 * 86400 + 60))
        let data = try TasksFile.encoder().encode(c)
        #expect(String(decoding: data, as: UTF8.self).contains("\"finished_earlier\""))
        #expect(try TasksFile.decoder().decode(TaskRun.self, from: data) == c)
        var plain = c
        plain.finishedEarlier = nil
        let old = try TasksFile.encoder().encode(plain)
        #expect(!String(decoding: old, as: UTF8.self).contains("finished_earlier"))
        #expect(try TasksFile.decoder().decode(TaskRun.self, from: old).finishedEarlier == nil)
    }

    @Test func agentTitleSkipsTheID() {
        var r = TaskRun(id: "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60", title: "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60", startedAt: TL.t0, updatedAt: TL.t0, state: .running)
        #expect(r.agentTitle == nil)
        r.title = "  "
        #expect(r.agentTitle == nil)
        r.title = "8D2F4A6B-91C3-4E7D-A5B0-C4D3E2F1A0B9"
        #expect(r.agentTitle == nil)
        r.title = "Fix the build"
        #expect(r.agentTitle == "Fix the build")
    }
}
