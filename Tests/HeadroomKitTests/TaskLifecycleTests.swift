import Foundation
import Testing
@testable import HeadroomKit

/// The run lifecycle: a turn that ended is the person's move; a session that ended (or went quiet
/// for good) settles the run as left; resuming reopens it. Work only a person can do is theirs,
/// and a session can do several jobs.
@Suite struct TaskLifecycleTests {
    /// A plan of two tasks, one done, worked on for `work` seconds, then the turn ends.
    func turn(work: TimeInterval = 1200) -> TL {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.session(0, work)
        tl.at(0, .start(task: "a")); tl.at(work - 60, .done(task: "a", evidence: nil))
        tl.at(work + 1, .stop(blocked: false), .hook)
        return tl
    }

    @Test func aTurnThatEndedIsYourTurnNotLeft() {
        let r = turn().fold(1201 + 8 * 60)
        #expect(r.state == .stopped && r.yourTurn && !r.left && !r.isSettled)
        #expect(r.turnEndedAt == TL.t(1201))
        // The turn's own work: from its first sign of life to when it ended.
        #expect(near(r.turnSeconds ?? 0, 1200, 1))
        #expect(r.attention != .done)
    }

    @Test func twelveHoursAfterTheTurnEndedItIsLeft() {
        let tl = turn()
        #expect(!tl.fold(1201 + 11 * 3600).left)
        let r = tl.fold(1201 + 12 * 3600 + 60)
        #expect(r.state == .stopped && r.left && r.isSettled && !r.yourTurn && r.attention == .done)
        // Still `stopped` on disk and on the wire: an older reader never reads it as running.
        #expect(r.state.rawValue == "stopped")
    }

    @Test func aSessionThatEndsSettlesAndResumingReopens() {
        var tl = turn()
        tl.at(1300, .end, .hook)
        var r = tl.fold(1310)
        #expect(r.left && r.state == .stopped && r.turnSeconds == nil)
        // run.resume opens it again.
        var resumed = tl
        resumed.at(1400, .resume, .hook)
        r = resumed.fold(1410)
        #expect(!r.left && !r.isSettled)
        // So does the orchestrator working again.
        tl.session(1500, 1560)
        r = tl.fold(1570)
        #expect(r.state == .running && !r.left)
    }

    @Test func aSessionGoneSilentWithNothingActiveIsLeft() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.session(0, 600)
        tl.at(0, .start(task: "a"))
        // Killed: no stop, no end. Past the abandon threshold it settles.
        #expect(!tl.fold(600 + 3600).left)
        let r = tl.fold(600 + TaskFold.defaultAbandonAfter + 60)
        #expect(r.state == .stopped && r.left)
    }

    @Test func aRunPausedAtALimitIsNeverLeft() {
        var tl = TL()
        tl.add(0, "a"); tl.at(0, .start(task: "a")); tl.session(0, 300)
        tl.at(310, .wait(task: "a", attempt: nil, reason: .limit, note: nil))
        let r = tl.fold(310 + 5 * 3600)
        #expect(r.state == .waiting && r.waitReason == .limit && !r.left)
        // Even once the session ended: not left (the limit holds it).
        tl.at(400, .end, .hook)
        #expect(!tl.fold(500).left)
    }

    @Test func workThatIsYoursIsNeverAQuestion() {
        var tl = TL()
        tl.add(0, "build"); tl.add(0, "submit")
        tl.session(0, 600)
        tl.at(0, .start(task: "build")); tl.at(500, .done(task: "build", evidence: nil))
        tl.at(510, .wait(task: "submit", attempt: nil, reason: .you, note: "Submit it in App Store Connect"))
        // While the agent's turn goes on it is working, never "needs input".
        var r = tl.fold(560)
        #expect(r.state == .running && !r.needsInput && r.question == nil)
        #expect(r.node("submit").state == .waiting && r.node("submit").waitReason == .you && r.node("submit").attention == .planned)
        #expect(r.node("submit").progress == .zero)
        // Its turn ends with only yours left: your turn, never stuck.
        tl.at(601, .stop(blocked: false), .hook)
        r = tl.fold(700)
        #expect(r.yourTurn && !r.stale && r.waitReason == nil)
        // And it settles like any other once the session ends.
        tl.at(800, .end, .hook)
        #expect(tl.fold(810).left)
    }

    @Test func anOlderReaderReadsYoursAsADependency() throws {
        let data = Data(#"{"reason":"you"}"#.utf8)
        struct W: Decodable { var reason: TaskWaitReason }
        // This build knows it…
        #expect(try JSONDecoder().decode(W.self, from: data).reason == .you)
        // …and the fallback a build without it lands on is the calm "dependency".
        #expect(TaskWaitReason.fallback == .dependency)
        #expect(TaskWaitReason(rawValue: "someday") == nil)
    }

    @Test func aNewPlanAfterTheLastOneFinishedIsANewJob() {
        var tl = TL()
        tl.at(0, .meta(title: "Port the API", project: nil, harness: nil))
        tl.add(0, "api", title: "Port the API"); tl.add(0, "tests", title: "Tests")
        tl.session(0, 900, tokens: { Int64($0) * 10 })
        tl.at(0, .start(task: "api")); tl.at(800, .done(task: "api", evidence: nil)); tl.at(850, .done(task: "tests", evidence: nil))
        tl.at(901, .stop(blocked: false), .hook)
        // The person asks for something else: a new turn, then a new plan.
        tl.session(2000, 2600, tokens: { Int64($0) * 10 })
        tl.add(2010, "logo", title: "Draw the logo"); tl.add(2010, "ship", title: "Ship it")
        tl.at(2010, .start(task: "logo"))
        let r = tl.fold(2610)
        #expect(r.jobs == 2)
        // The run is about the job it's on: its name, its percent, its scope.
        #expect(r.title == "Draw the logo")
        #expect(r.state == .running && r.progress.done < 0.5)
        #expect(r.jobNodes.map(\.id).sorted() == ["logo", "ship"])
        #expect(r.earlierJobs.map(\.id) == ["api", "tests"] && r.earlierJobs.allSatisfy { !$0.counted })
        #expect(r.scopeChanges == 0)
        // Earlier work still counts in what the session spent.
        #expect(r.tokens == 26_000)
        // A title declared with the new plan names it.
        var named = tl
        named.at(2005, .meta(title: "Release with the new logo", project: nil, harness: nil))
        #expect(named.fold(2610).title == "Release with the new logo")
    }

    @Test func aPivotWithinATurnStaysOneJob() {
        var tl = TL()
        tl.add(0, "a"); tl.session(0, 300)
        tl.at(100, .fail(task: "a", reason: "doing it another way instead"))
        tl.add(110, "b")
        #expect(tl.fold(200).jobs == nil)
        // And a journal with no turns at all behaves as before.
        var plain = TL()
        plain.add(0, "a"); plain.at(10, .done(task: "a", evidence: nil)); plain.add(3600, "b")
        #expect(plain.fold(3700).jobs == nil && plain.fold(3700).nodes.count == 2)
    }

    @Test func tasksJSONFromBeforeTheLifecycleLoads() throws {
        let r = turn().fold(1300)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        var json = try #require(try JSONSerialization.jsonObject(with: e.encode(r)) as? [String: Any])
        for k in ["left", "turn_ended_at", "turn_seconds", "jobs"] { json[k] = nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let old = try d.decode(TaskRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.left && old.turnEndedAt == nil && old.jobs == nil && old.state == .stopped)
        // And a new one round-trips.
        let back = try d.decode(TaskRun.self, from: e.encode(r))
        #expect(back.turnEndedAt == r.turnEndedAt && back.left == r.left)
    }
}
