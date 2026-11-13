import Foundation
import Testing
@testable import HeadroomKit

/// Builds event lists on a clock in seconds from `t0`.
struct TL {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    var events: [TaskEvent] = []
    var run = "r1"

    mutating func at(_ s: TimeInterval, _ op: TaskEvent.Op, _ src: TaskSource = .agent) { events.append(TaskEvent(at: TL.t(s), run: run, source: src, op: op)) }
    mutating func add(_ s: TimeInterval, _ id: String, effort: Double? = nil, importance: TaskImportance? = nil, steps: Int? = nil, title: String? = nil) {
        at(s, .add(.init(id: id, title: title, effort: effort, importance: importance, steps: steps)))
    }
    mutating func attempt(_ s: TimeInterval, _ key: String, tag: String? = nil, parent: String? = nil, kind: TaskAttemptKind = .agent, title: String? = nil) {
        at(s, .attempt(.init(key: key, kind: kind, agentType: "general-purpose", tag: tag, parentKey: parent, title: title)), .harness)
    }

    /// The orchestrator's session, then its activity every `every` seconds over `from…to`.
    mutating func session(_ from: TimeInterval, _ to: TimeInterval, every: TimeInterval = 60, key: String = "session:1", tokens: ((TimeInterval) -> Int64)? = nil) {
        if !events.contains(where: { if case .attempt(let a) = $0.op { a.key == key } else { false } }) {
            at(from, .attempt(.init(key: key, kind: .session)), .harness)
        }
        var s = from
        while s <= to {
            at(s, .activity(attempt: key, at: nil, tokens: tokens?(s)), .harness)
            s += every
        }
    }

    func fold(_ now: TimeInterval, stale: TimeInterval = TaskFold.defaultStaleAfter, tpu: Double? = nil,
              abandon: TimeInterval = TaskFold.defaultAbandonAfter) -> TaskRun {
        TaskFold.fold(events, now: TL.t(now), staleAfter: stale, tokensPerEffortUnit: tpu, abandonAfter: abandon).first { $0.id == run }!
    }
}

extension TaskRun {
    func node(_ id: String) -> TaskNode { nodes.first { $0.id == id }! }
}

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

@Suite struct TaskIDTests {
    @Test func pathsAndImplicitParents() {
        #expect(TaskPath.parent("api/tests/unit") == "api/tests")
        #expect(TaskPath.parent("api") == nil)
        #expect(TaskPath.ancestors("api/tests/unit") == ["api", "api/tests"])
        #expect(TaskPath.isValid("api/tests") && TaskPath.isValid("phase-1.b/x_y") && TaskPath.isValid("~agent-a1"))
        #expect(!TaskPath.isValid("") && !TaskPath.isValid("api//x") && !TaskPath.isValid("a b") && !TaskPath.isValid("a:b") && !TaskPath.isValid("~"))

        var tl = TL()
        tl.add(0, "api/tests/unit", title: "Unit tests")
        let run = tl.fold(1)
        #expect(run.nodes.map(\.id) == ["api", "api/tests", "api/tests/unit"])
        #expect(run.node("api").title == "api" && !run.node("api").declared)
        #expect(run.node("api/tests").title == "tests" && run.node("api/tests").parent == "api")
        #expect(run.node("api/tests/unit").declared && run.node("api/tests/unit").depth == 2)
        #expect(run.node("api/tests/unit").title == "Unit tests")
    }

    @Test func runIDsAreSanitized() {
        #expect(TaskRunID.sanitize("abc-123_X.y") == "abc-123_X.y")
        #expect(TaskRunID.sanitize("a b/c:d") == "a-b-c-d")
        #expect(TaskRunID.sanitize(String(repeating: "x", count: 100))?.count == 64)
        #expect(TaskRunID.sanitize("") == nil && TaskRunID.sanitize("..") == nil)
        #expect(TaskPath.implicit(forAttempt: "agent:a49c") == "~agent-a49c")
    }

    @Test func tagsParse() {
        let ref = TaskRef(run: "7f3a", path: "api/tests")
        #expect(ref.tag == "[hr:7f3a:api/tests]")
        #expect(TaskRef("7f3a:api/tests") == ref)
        #expect(TaskRef("api/tests") == nil && TaskRef("r:") == nil && TaskRef("r r:x") == nil)
        #expect(TaskRef.firstTag(in: "Write tests [hr:bad] for it [hr:7f3a:api/tests] then [hr:other:x]") == ref)
        #expect(TaskRef.firstTag(in: "no tag [hr:7f3a:") == nil)
        #expect(TaskRef.firstTag(in: "[hr:a:b c]") == nil)
        #expect(TaskEvent.AttemptSpec(key: "k", tag: "Fix it [hr:r1:api]").taggedPath == "api")
        #expect(TaskEvent.AttemptSpec(key: "k", tag: "r1:api/x").taggedPath == "api/x")
        #expect(TaskEvent.AttemptSpec(key: "k", tag: "api").taggedPath == "api")
    }
}

@Suite struct TaskLeafStateTests {
    @Test func plannedStartedAndDeclaredStates() {
        var tl = TL()
        for id in ["a", "b", "c", "d", "e", "f"] { tl.add(0, id) }
        tl.at(1, .start(task: "b"))
        tl.at(1, .done(task: "c", evidence: "tests pass"))
        tl.at(1, .fail(task: "d", reason: "flaky"))
        tl.at(1, .skip(task: "e", reason: nil))
        tl.at(1, .cancel(task: "f", reason: nil))
        let r = tl.fold(2)
        #expect(r.node("a").state == .planned)
        #expect(r.node("b").state == .running && r.node("b").startedAt == TL.t(1))
        #expect(r.node("c").state == .done && r.node("c").evidence == "tests pass" && r.node("c").confirmed && r.node("c").endedAt == TL.t(1))
        #expect(r.node("d").state == .failed && r.node("d").failure == "flaky")
        #expect(r.node("e").state == .skipped)
        #expect(r.node("f").state == .cancelled)
    }

    @Test func activeAttemptRunsUnlessALaterWaitHolds() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.at(1, .wait(task: "a", attempt: nil, reason: .dependency, note: "needs b"))
        tl.attempt(2, "agent:1", tag: "a")
        tl.attempt(2, "agent:2", tag: "b")
        tl.at(3, .wait(task: "b", attempt: nil, reason: .limit, note: nil))
        let r = tl.fold(4)
        #expect(r.node("a").state == .running) // the wait came before the attempt
        #expect(r.node("b").state == .waiting && r.node("b").waitReason == .limit)
    }

    @Test func endedAttemptsGiveUnconfirmedOutcome() {
        var tl = TL()
        tl.add(0, "ok"); tl.add(0, "bad"); tl.add(0, "retried")
        tl.attempt(1, "k1", tag: "ok"); tl.at(5, .attemptEnd(attempt: "k1", outcome: .ok), .harness)
        tl.attempt(1, "k2", tag: "bad"); tl.at(5, .attemptEnd(attempt: "k2", outcome: .error), .harness)
        tl.attempt(1, "k3", tag: "retried"); tl.at(2, .attemptEnd(attempt: "k3", outcome: .error), .harness)
        tl.attempt(3, "k4", tag: "retried"); tl.at(6, .attemptEnd(attempt: "k4", outcome: .ok), .harness)
        let r = tl.fold(7)
        #expect(r.node("ok").state == .done && !r.node("ok").confirmed && r.node("ok").endedAt == TL.t(5))
        #expect(r.node("bad").state == .failed && !r.node("bad").confirmed)
        #expect(r.node("retried").state == .done && r.node("retried").attempts.count == 2 && r.node("retried").attempts.retries == 1)
    }

    @Test func declaredTerminalWinsAndANewAttemptReopens() {
        var tl = TL()
        tl.add(0, "a")
        tl.attempt(1, "k1", tag: "a")
        tl.at(2, .done(task: "a", evidence: nil))
        #expect(tl.fold(3).node("a").state == .done) // the attempt is still open
        tl.attempt(4, "k2", tag: "a")
        var r = tl.fold(5)
        #expect(r.node("a").state == .running && r.node("a").attempts.retries == 1)
        tl.at(6, .fail(task: "a", reason: "no"))
        tl.at(7, .start(task: "a"))
        r = tl.fold(8)
        #expect(r.node("a").state == .running && r.node("a").attempts.retries == 2)
    }

    @Test func inputWaitClearsOnActivityOthersHold() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.attempt(1, "k1", tag: "a"); tl.attempt(1, "k2", tag: "b")
        tl.at(2, .wait(task: nil, attempt: "k1", reason: .input, note: "permission"), .hook)
        tl.at(2, .wait(task: "b", attempt: nil, reason: .dependency, note: nil))
        var r = tl.fold(3)
        #expect(r.node("a").state == .waiting && r.node("a").waitReason == .input)
        #expect(r.run_needsAttention)
        tl.at(4, .activity(attempt: "k1", at: nil, tokens: 100), .harness)
        tl.at(4, .activity(attempt: "k2", at: nil, tokens: 100), .harness)
        r = tl.fold(5)
        #expect(r.node("a").state == .running)
        #expect(r.node("b").state == .waiting && r.node("b").waitReason == .dependency)
    }

    @Test func staleIsAnOverlayOnRunningWork() {
        var tl = TL()
        tl.add(0, "g/a"); tl.add(0, "g/b")
        tl.attempt(0, "k1", tag: "g/a")
        tl.at(0, .start(task: "g/b"))
        tl.at(600, .activity(attempt: "k1", at: nil, tokens: 10), .harness)
        let r = tl.fold(1200)
        #expect(r.node("g/b").state == .running && r.node("g/b").stale)
        #expect(r.node("g/a").state == .running && !r.node("g/a").stale)
        #expect(!r.node("g").stale) // a descendant is active
        #expect(!r.stale)
        #expect(tl.fold(1200, stale: 300).node("g").stale)
        #expect(tl.fold(1200, stale: 300).stale)
        #expect(tl.fold(1200, stale: 300).attention == .stale)
        // Only running work goes stale.
        var p = TL()
        p.add(0, "x")
        #expect(!p.fold(100_000).node("x").stale)
    }
}

extension TaskRun {
    var run_needsAttention: Bool { attention <= .stale || nodes.contains { $0.attention == .needsInput } }
}

@Suite struct TaskParentAndRunStateTests {
    func run(_ states: [(String, TaskImportance, TaskState)]) -> TaskRun {
        var tl = TL()
        for (id, imp, state) in states {
            tl.add(0, "p/\(id)", importance: imp)
            switch state {
            case .running: tl.at(1, .start(task: "p/\(id)"))
            case .done: tl.at(1, .done(task: "p/\(id)", evidence: nil))
            case .failed: tl.at(1, .fail(task: "p/\(id)", reason: nil))
            case .skipped: tl.at(1, .skip(task: "p/\(id)", reason: nil))
            case .cancelled: tl.at(1, .cancel(task: "p/\(id)", reason: nil))
            case .waiting: tl.at(1, .wait(task: "p/\(id)", attempt: nil, reason: .limit, note: nil))
            default: break
            }
        }
        return tl.fold(2)
    }

    @Test func parentStatesDerive() {
        #expect(run([("a", .normal, .done), ("b", .normal, .running)]).node("p").state == .running)
        #expect(run([("a", .normal, .done), ("b", .normal, .done)]).node("p").state == .done)
        #expect(run([("a", .critical, .failed), ("b", .normal, .done)]).node("p").state == .failed)
        #expect(run([("a", .critical, .cancelled), ("b", .normal, .done)]).node("p").state == .failed)
        #expect(run([("a", .normal, .failed), ("b", .normal, .done)]).node("p").state == .partial)
        #expect(run([("a", .normal, .cancelled), ("b", .normal, .done)]).node("p").state == .partial)
        #expect(run([("a", .optional, .failed), ("b", .normal, .done)]).node("p").state == .done)
        #expect(run([("a", .optional, .cancelled), ("b", .optional, .skipped), ("c", .normal, .done)]).node("p").state == .done)
        #expect(run([("a", .normal, .skipped), ("b", .normal, .skipped)]).node("p").state == .skipped)
        #expect(run([("a", .normal, .planned), ("b", .normal, .planned)]).node("p").state == .planned)
        #expect(run([("a", .normal, .planned), ("b", .normal, .done)]).node("p").state == .parked)
        let w = run([("a", .normal, .waiting), ("b", .normal, .done)]).node("p")
        #expect(w.state == .waiting && w.waitReason == .limit)
    }

    @Test func mostUrgentWaitWins() {
        var tl = TL()
        tl.add(0, "p/a"); tl.add(0, "p/b"); tl.add(0, "p/c")
        tl.at(1, .wait(task: "p/a", attempt: nil, reason: .dependency, note: nil))
        tl.at(1, .wait(task: "p/b", attempt: nil, reason: .input, note: nil))
        tl.at(1, .wait(task: "p/c", attempt: nil, reason: .limit, note: nil))
        let r = tl.fold(2)
        #expect(r.node("p").waitReason == .input)
        #expect(r.state == .waiting && r.waitReason == .input && r.attention == .needsInput)
    }

    @Test func criticalFailureFailsTheRunAndCascades() {
        var tl = TL()
        tl.add(0, "api/a", importance: .critical); tl.add(0, "api/b"); tl.add(0, "docs", importance: .optional)
        tl.add(0, "api", importance: .critical)
        tl.at(1, .fail(task: "api/a", reason: "broken"))
        tl.at(2, .done(task: "api/b", evidence: nil))
        tl.at(3, .cancel(task: "docs", reason: nil))
        let r = tl.fold(4)
        #expect(r.node("api").state == .failed)
        #expect(r.state == .failed && r.attention == .failed)
        // A terminal op on a parent closes its open children.
        var c = TL()
        c.add(0, "g/a"); c.add(0, "g/b")
        c.at(1, .done(task: "g/a", evidence: nil))
        c.at(2, .skip(task: "g", reason: "not needed"))
        let rc = c.fold(3)
        #expect(rc.node("g/a").state == .done && rc.node("g/b").state == .skipped && rc.node("g").state == .done)
    }

    @Test func runStates() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.at(1, .start(task: "a"))
        #expect(tl.fold(2).state == .running)
        tl.at(2, .stop(blocked: true), .hook)
        #expect(tl.fold(3).state == .running) // an enforcing hook sent the agent back
        tl.at(2, .stop(blocked: false), .hook)
        #expect(tl.fold(3).state == .stopped)
        tl.at(4, .resume, .hook)
        #expect(tl.fold(5).state == .running)
        // A background agent keeps the run running past the orchestrator's stop.
        tl.attempt(6, "bg", tag: "b")
        tl.at(7, .stop(blocked: false), .hook)
        #expect(tl.fold(8).state == .running)
        tl.at(9, .attemptEnd(attempt: "bg", outcome: .ok), .harness)
        #expect(tl.fold(10).state == .stopped)
        // The orchestrator asking a person.
        tl.at(11, .wait(task: nil, attempt: nil, reason: .input, note: "idle"), .hook)
        #expect(tl.fold(12).state == .waiting && tl.fold(12).waitReason == .input)
        tl.at(13, .resume, .hook)
        tl.at(14, .done(task: "a", evidence: nil))
        #expect(tl.fold(15).state == .done)
        // Finished work ignores a later idle notification.
        tl.at(16, .wait(task: nil, attempt: nil, reason: .input, note: "idle"), .hook)
        #expect(tl.fold(17).state == .done)
        // An agent's report after the stop (a background agent's) doesn't clear it; the
        // orchestrator working again, or a person, does.
        var s = TL()
        s.add(0, "a"); s.at(1, .start(task: "a")); s.at(2, .stop(blocked: false), .hook)
        s.at(3, .progress(task: "a", step: 1, total: 3, fraction: nil, note: nil))
        #expect(s.fold(4).state == .stopped)
        var o = s
        o.session(4, 4)
        #expect(o.fold(5).state == .running)
        s.at(4, .progress(task: "a", step: 2, total: nil, fraction: nil, note: nil), .user)
        #expect(s.fold(5).state == .running)
        s.at(5, .end, .hook)
        #expect(s.fold(6).state == .stopped)
    }

    @Test func partialRunAndAttentionOrder() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.at(1, .done(task: "a", evidence: nil)); tl.at(1, .fail(task: "b", reason: nil))
        #expect(tl.fold(2).state == .partial)
        #expect(TaskAttention.allCases == [.needsInput, .failed, .stale, .limit, .running, .planned, .done])
        #expect(TaskAttention(state: .waiting, waitReason: .limit, stale: false) == .limit)
        #expect(TaskAttention(state: .parked, waitReason: nil, stale: false) == .planned)
    }
}

@Suite struct TaskProgressTests {
    @Test func leafProgressByState() {
        var tl = TL()
        tl.add(0, "done"); tl.add(0, "planned"); tl.add(0, "failed"); tl.add(0, "cancelled")
        tl.add(0, "steps", steps: 4); tl.add(0, "frac"); tl.add(0, "bare"); tl.add(0, "wait")
        tl.at(1, .done(task: "done", evidence: nil))
        tl.at(1, .fail(task: "failed", reason: nil))
        tl.at(1, .cancel(task: "cancelled", reason: nil))
        tl.at(1, .progress(task: "steps", step: 1, total: nil, fraction: nil, note: "one down"))
        tl.at(1, .progress(task: "frac", step: nil, total: nil, fraction: 0.3, note: nil))
        tl.at(1, .start(task: "bare"))
        tl.at(1, .progress(task: "wait", step: nil, total: nil, fraction: 0.5, note: nil))
        tl.at(2, .wait(task: "wait", attempt: nil, reason: .dependency, note: nil))
        let r = tl.fold(3)
        #expect(r.node("done").progress == .complete)
        #expect(r.node("planned").progress == .zero && r.node("planned").counted)
        #expect(r.node("failed").progress == .zero && r.node("failed").counted)
        #expect(r.node("cancelled").progress == .zero && r.node("cancelled").counted)
        #expect(r.node("steps").progress == TaskProgress(done: 0.25, inFlight: 0.75, estimate: 0.25) && r.node("steps").note == "one down")
        #expect(r.node("steps").steps == TaskSteps(done: 1, total: 4))
        #expect(r.node("frac").progress == TaskProgress(done: 0.3, inFlight: 0.7, estimate: 0.3))
        #expect(r.node("bare").progress == TaskProgress(done: 0, inFlight: 1, estimate: 0))
        #expect(r.node("wait").progress.done == 0.5 && r.node("wait").state == .waiting)
        // 8 equal leaves: 1 + 0.25 + 0.3 + 0.5 done.
        #expect(near(r.progress.done, 2.05 / 8))
    }

    @Test func stepsOverrideFractionAndTotalsCanArriveWithTheStep() {
        var tl = TL()
        tl.add(0, "a")
        tl.at(1, .progress(task: "a", step: 3, total: 5, fraction: 0.9, note: nil))
        #expect(tl.fold(2).node("a").progress.done == 0.6)
    }

    @Test func tokensDriveTheEstimate() {
        var tl = TL()
        tl.add(0, "a", effort: 4); tl.add(0, "b", effort: 4)
        tl.attempt(1, "k1", tag: "a"); tl.attempt(1, "k2", tag: "b")
        tl.at(2, .activity(attempt: "k1", at: nil, tokens: 2_000), .harness)
        tl.at(2, .activity(attempt: "k2", at: nil, tokens: 1_000_000), .harness)
        tl.at(2, .progress(task: "b", step: nil, total: nil, fraction: 0.95, note: nil))
        let r = tl.fold(3, tpu: 1_000)
        #expect(near(r.node("a").progress.estimate, 0.5)) // 2000 / (1000 × 4)
        #expect(r.node("a").progress.done == 0)
        #expect(near(r.node("b").progress.estimate, 0.95)) // capped at 0.9, then never below done
        #expect(tl.fold(3).node("a").progress.estimate == 0) // no calibration: estimate is done
        #expect(r.tokens == 1_002_000)
    }

    @Test func skippedAndFailedOptionalLeaveTheDenominator() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b"); tl.add(0, "c", importance: .optional); tl.add(0, "d"); tl.add(0, "e")
        tl.at(1, .done(task: "a", evidence: nil))
        tl.at(1, .skip(task: "b", reason: nil))
        tl.at(1, .fail(task: "c", reason: nil))
        tl.at(1, .cancel(task: "e", reason: nil))
        let r = tl.fold(2)
        #expect(!r.node("b").counted && !r.node("c").counted && r.node("e").counted)
        // a done, d planned, e cancelled (normal: keeps its weight).
        #expect(near(r.progress.done, 1.0 / 3))
    }

    @Test func effortWeighsSiblingsAndParentsKeepTheirOwnWeight() {
        var tl = TL()
        tl.add(0, "big", effort: 8); tl.add(0, "small", effort: 2)
        tl.add(0, "big/x", effort: 1); tl.add(0, "big/y", effort: 1)
        tl.at(1, .done(task: "small", evidence: nil))
        tl.at(1, .done(task: "big/x", evidence: nil))
        let r = tl.fold(2)
        #expect(r.node("big").progress.done == 0.5)
        #expect(r.node("big").effort == 8) // never the sum of its children
        #expect(near(r.progress.done, (8 * 0.5 + 2 * 1) / 10))
        #expect(TaskEffort.parse("xs") == 1 && TaskEffort.parse("XL") == 16 && TaskEffort.parse("2.5") == 2.5)
        #expect(TaskEffort.parse("0") == nil && TaskEffort.parse("-1") == nil && TaskEffort.parse("huge") == nil)
        #expect(TaskEffort.label(4) == "m" && TaskEffort.label(3) == "3" && TaskEffort.label(2.5) == "2.5")
    }

    @Test func scalingWeightsByAConstantChangesNothing() {
        func run(scale: Double) -> TaskRun {
            var tl = TL()
            tl.add(0, "a", effort: 1 * scale); tl.add(0, "b", effort: 3 * scale); tl.add(0, "c", effort: 4 * scale)
            tl.add(0, "c/x", effort: 2 * scale); tl.add(0, "c/y", effort: 5 * scale)
            tl.at(1, .done(task: "a", evidence: nil))
            tl.at(1, .progress(task: "b", step: nil, total: nil, fraction: 0.4, note: nil))
            tl.at(1, .done(task: "c/x", evidence: nil))
            tl.attempt(1, "k", tag: "c/y"); tl.at(2, .activity(attempt: "k", at: nil, tokens: 5_000), .harness)
            return tl.fold(3, tpu: 1_000 / scale)
        }
        let a = run(scale: 1), b = run(scale: 7.5)
        for (x, y) in zip(a.nodes, b.nodes) {
            #expect(near(x.progress.done, y.progress.done) && near(x.progress.inFlight, y.progress.inFlight) && near(x.progress.estimate, y.progress.estimate))
        }
        #expect(near(a.progress.estimate, b.progress.estimate))
    }

    @Test func splittingALeafLeavesAncestorsAlone() {
        var before = TL()
        before.add(0, "root/a", effort: 4); before.add(0, "root/b", effort: 2)
        before.at(1, .done(task: "root/b", evidence: nil))
        var after = before
        // Split a planned leaf into planned children: nothing above it moves.
        after.add(2, "root/a/one", effort: 1); after.add(2, "root/a/two", effort: 9)
        let x = before.fold(3), y = after.fold(3)
        #expect(x.node("root").progress == y.node("root").progress && x.progress == y.progress)
        #expect(y.node("root/a").effort == 4)
        // A running leaf declaring steps vs. the same work split into children at the same progress.
        var steps = TL()
        steps.add(0, "p/a", effort: 4); steps.add(0, "p/b")
        steps.at(1, .progress(task: "p/a", step: 1, total: 2, fraction: nil, note: nil))
        var split = TL()
        split.add(0, "p/a", effort: 4); split.add(0, "p/b")
        split.add(1, "p/a/1"); split.add(1, "p/a/2")
        split.at(1, .done(task: "p/a/1", evidence: nil))
        #expect(steps.fold(2).node("p").progress.done == split.fold(2).node("p").progress.done)
    }

    @Test func randomSequencesKeepTheInvariants() {
        var rng = SplitMix(seed: 42)
        let ids = ["a", "a/x", "a/y", "b", "b/z/q", "c", "d"]
        for _ in 0..<200 {
            var tl = TL()
            var keys: [String] = []
            for step in 0..<Int.random(in: 5...60, using: &rng) {
                let s = Double(step) * 30
                let id = ids.randomElement(using: &rng)!
                switch Int.random(in: 0..<14, using: &rng) {
                case 0: tl.add(s, id, effort: [nil, 1, 4, 16, 0.5].randomElement(using: &rng)!, importance: TaskImportance.allCases.randomElement(using: &rng), steps: [nil, 3].randomElement(using: &rng)!)
                case 1: tl.at(s, .start(task: id))
                case 2: tl.at(s, .progress(task: id, step: Int.random(in: 0...6, using: &rng), total: [nil, 4].randomElement(using: &rng)!, fraction: Double.random(in: -0.5...1.5, using: &rng), note: nil))
                case 3: tl.at(s, .wait(task: id, attempt: nil, reason: TaskWaitReason.allCases.randomElement(using: &rng)!, note: nil))
                case 4: tl.at(s, .done(task: id, evidence: nil))
                case 5: tl.at(s, .fail(task: id, reason: nil))
                case 6: tl.at(s, .skip(task: id, reason: nil))
                case 7: tl.at(s, .cancel(task: id, reason: nil))
                case 8:
                    let k = "k\(keys.count)"
                    keys.append(k)
                    tl.attempt(s, k, tag: Bool.random(using: &rng) ? id : nil, parent: keys.randomElement(using: &rng))
                case 9: if let k = keys.randomElement(using: &rng) { tl.at(s, .activity(attempt: k, at: nil, tokens: Int64.random(in: 0...200_000, using: &rng)), .harness) }
                case 10: if let k = keys.randomElement(using: &rng) { tl.at(s, .attemptEnd(attempt: k, outcome: TaskAttemptOutcome.allCases.randomElement(using: &rng)), .harness) }
                case 11: tl.at(s, .stop(blocked: false), .hook)
                case 12: tl.at(s, .resume, .hook)
                default: tl.at(s, .wait(task: nil, attempt: keys.randomElement(using: &rng), reason: .input, note: nil), .hook)
                }
            }
            for tpu in [nil, 5_000.0] {
                let r = tl.fold(Double(tl.events.count) * 30 + 60, tpu: tpu)
                for p in r.nodes.map(\.progress) + [r.progress] {
                    #expect(p.done >= 0 && p.done <= 1 && p.inFlight >= 0 && p.inFlight <= 1 && p.estimate >= 0 && p.estimate <= 1)
                    #expect(p.done <= p.estimate + 1e-12)
                    #expect(p.done + p.inFlight <= 1 + 1e-12)
                }
                if let eta = r.etaSeconds { #expect(eta >= 0 && eta.isFinite) }
                #expect(r.mustHaves.done <= r.mustHaves.total)
            }
        }
    }
}

/// Deterministic generator for the property test.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct TaskAttemptBindingTests {
    @Test func taggedAttemptsBindToTheirTask() {
        var tl = TL()
        tl.add(0, "api/tests")
        tl.at(1, .attempt(.init(key: "agent:a1", kind: .agent, agentType: "general-purpose", model: "claude-opus-5-5", provider: "anthropic",
                                tag: "Write the tests [hr:r1:api/tests]", title: "Write tests")), .harness)
        let r = tl.fold(2)
        #expect(r.nodes.count == 2)
        let n = r.node("api/tests")
        #expect(n.state == .running && n.attempts.count == 1 && n.attempts.active == 1)
        #expect(n.attempts.last?.model == "claude-opus-5-5" && n.attempts.last?.agentType == "general-purpose")
    }

    @Test func untaggedAttemptsGetImplicitTasks() {
        var tl = TL()
        tl.add(0, "api")
        tl.attempt(1, "agent:lead", tag: "api")
        tl.attempt(2, "agent:helper", parent: "agent:lead", title: "Explore the schema")
        tl.attempt(3, "agent:stray", title: "Look around")
        let r = tl.fold(4)
        let helper = r.node("~agent-helper")
        #expect(helper.parent == "api" && helper.title == "Explore the schema" && !helper.declared && !helper.counted)
        #expect(r.node("api").leaf) // a helper never turns a declared task into a group
        #expect(r.node("~agent-stray").parent == nil && !r.node("~agent-stray").counted)
        #expect(r.nodes.map(\.id) == ["api", "~agent-helper", "~agent-stray"])
        // With nothing declared, the agents are the plan.
        var bare = TL()
        bare.attempt(0, "agent:1", title: "one"); bare.attempt(0, "agent:2", title: "two")
        bare.at(5, .attemptEnd(attempt: "agent:1", outcome: .ok), .harness)
        let b = bare.fold(6)
        #expect(b.node("~agent-1").counted && b.node("~agent-1").state == .done && !b.node("~agent-1").confirmed)
        // An agent ending isn't a confirmed outcome: it counts in the estimate, not in done.
        #expect(b.progress.estimate == 0.5 && b.progress.done == 0 && b.state == .running)
    }

    @Test func aLateTagMovesTheAttempt() {
        var tl = TL()
        tl.add(0, "api/tests")
        tl.attempt(1, "agent:a1") // the hook sees the agent before the observer reads its prompt
        #expect(tl.fold(2).nodes.contains { $0.id == "~agent-a1" })
        tl.attempt(2, "agent:a1", tag: "[hr:r1:api/tests]")
        let r = tl.fold(3)
        #expect(!r.nodes.contains { $0.id == "~agent-a1" })
        #expect(r.node("api/tests").attempts.count == 1 && r.node("api/tests").state == .running)
        // A parent key that arrives late places the implicit task too.
        var p = TL()
        p.add(0, "api"); p.attempt(0, "lead", tag: "api")
        p.attempt(1, "child")
        p.attempt(2, "child", parent: "lead")
        #expect(p.fold(3).node("~child").parent == "api")
    }

    @Test func spawnCyclesFallBackToTheRoot() {
        var tl = TL()
        tl.attempt(0, "x", parent: "y"); tl.attempt(0, "y", parent: "x")
        let r = tl.fold(1)
        #expect(r.nodes.count == 2)
        #expect(r.nodes.allSatisfy { $0.parent == nil })
    }

    @Test func resumedAgentReopensItsTask() {
        var tl = TL()
        tl.add(0, "a")
        tl.attempt(1, "k", tag: "a")
        tl.at(2, .attemptEnd(attempt: "k", outcome: .ok), .harness)
        tl.at(3, .done(task: "a", evidence: nil))
        tl.attempt(4, "k", tag: "a") // SubagentStart again: the agent was resumed
        let r = tl.fold(5)
        #expect(r.node("a").state == .running && r.node("a").attempts.retries == 1)
    }

    @Test func sessionEndInterruptsOpenAttempts() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.attempt(1, "k1", tag: "a"); tl.attempt(1, "k2", tag: "b")
        tl.at(2, .end, .hook)
        let r = tl.fold(3)
        // Quitting mid-task isn't finishing: both are cut short, and the run stopped with work left.
        #expect(r.node("a").attempts.active == 0 && r.node("a").attempts.last?.outcome == .interrupted)
        #expect(r.node("a").state == .parked && !r.node("a").confirmed && r.node("b").state == .parked)
        #expect(r.state == .stopped && r.progress.done == 0 && r.progress.estimate < 1)
        // The same with no plan: two agents mid-task and the session ends.
        var bare = TL()
        bare.session(0, 0)
        bare.attempt(1, "agent:1", parent: "session:1"); bare.attempt(1, "agent:2", parent: "session:1")
        bare.at(2, .end, .hook)
        let b = bare.fold(3)
        #expect(b.state == .stopped && b.progress.estimate == 0)
        // An attempt ended as interrupted reads the same.
        var i = TL()
        i.add(0, "a"); i.attempt(1, "k", tag: "a"); i.at(2, .attemptEnd(attempt: "k", outcome: .interrupted), .harness)
        #expect(i.fold(3).node("a").state == .parked && i.fold(3).progress.estimate == 0)
    }
}

@Suite struct TaskForecastTests {
    @Test func etaFromTheRecentRateOfWorkingTime() throws {
        var tl = TL()
        for id in ["a", "b", "c", "d"] { tl.add(0, id) }
        tl.session(0, 1200)
        tl.at(600, .done(task: "a", evidence: nil))
        #expect(tl.fold(900).etaSeconds == nil) // one leaf done
        tl.at(1200, .done(task: "b", evidence: nil))
        // Half done in 20 minutes of work: the other half takes 20 more, somewhere in 10-40.
        var r = tl.fold(1200)
        #expect(near(r.etaSeconds ?? -1, 1200, 1e-6))
        #expect(near(r.etaLowSeconds ?? -1, 600, 1e-6) && near(r.etaHighSeconds ?? -1, 2400, 1e-6))
        // Half an hour idle, then work again: c and d close and four tasks join.
        tl.session(3000, 5400)
        tl.at(3600, .done(task: "c", evidence: nil))
        tl.add(3600, "e"); tl.add(3600, "f"); tl.add(3600, "g"); tl.add(3600, "h")
        tl.at(5400, .done(task: "d", evidence: nil))
        r = tl.fold(5400)
        #expect(near(r.time.working, 3600, 1e-6) && near(r.time.idle, 1800, 1e-6) && near(r.time.total, 5400, 1e-6))
        // The last 45 minutes of working time saw b, c and d close (3 of 8): 0.375 per 2700 s,
        // with half left. The idle half hour isn't in it.
        #expect(near(r.etaSeconds ?? -1, 0.5 / (0.375 / 2700), 1e-6))
        #expect(r.scopeChanges == 4)
        let low = try #require(r.etaLowSeconds), mid = try #require(r.etaSeconds), high = try #require(r.etaHighSeconds)
        #expect(low <= mid && mid <= high)
    }

    @Test func idleTimeDoesntSlowTheForecast() {
        var tl = TL()
        for id in ["a", "b", "c", "d"] { tl.add(0, id) }
        tl.session(0, 1800)
        tl.at(900, .done(task: "a", evidence: nil))
        tl.at(1800, .done(task: "b", evidence: nil))
        tl.session(5400, 6300) // an hour away, then 15 minutes more
        let r = tl.fold(6300)
        // Half done in 45 minutes of work: 45 more, not the wall clock's 105.
        #expect(near(r.etaSeconds ?? -1, 2700, 1e-6))
        var all = tl
        all.at(6300, .done(task: "c", evidence: nil)); all.at(6300, .done(task: "d", evidence: nil))
        #expect(all.fold(6301).etaSeconds == nil) // finished
    }

    @Test func noForecastUnlessRunning() {
        var tl = TL()
        for id in ["a", "b", "c", "d"] { tl.add(0, id) }
        tl.session(0, 1200)
        tl.at(600, .done(task: "a", evidence: nil)); tl.at(1200, .done(task: "b", evidence: nil))
        #expect(tl.fold(1200).etaSeconds != nil)
        var stopped = tl
        stopped.at(1201, .stop(blocked: false), .hook)
        let s = stopped.fold(1300)
        #expect(s.state == .stopped && s.etaSeconds == nil && s.etaLowSeconds == nil && s.etaHighSeconds == nil)
        var waiting = tl
        waiting.at(1201, .wait(task: nil, attempt: nil, reason: .input, note: "Which database?"), .hook)
        #expect(waiting.fold(1300).state == .waiting && waiting.fold(1300).etaSeconds == nil)
        // The forecast doesn't grow while the run sits: an hour later it says the same.
        #expect(tl.fold(1200).etaSeconds == tl.fold(1200 + 3600).etaSeconds)
    }

    @Test func theRangeNarrowsAsTasksClose() throws {
        var tl = TL()
        for i in 0..<20 { tl.add(0, "t\(i)") }
        tl.session(0, 6000)
        for i in 0..<10 { tl.at(Double(i + 1) * 600, .done(task: "t\(i)", evidence: nil)) }
        let r = tl.fold(6000)
        let eta = try #require(r.etaSeconds)
        // Ten closed: 1.25 either way.
        let low = try #require(r.etaLowSeconds), high = try #require(r.etaHighSeconds)
        #expect(near(low, eta / 1.25, 1e-6) && near(high, eta * 1.25, 1e-6))
    }

    @Test func tokensPerEffortUnitIsTheMedian() {
        var tl = TL()
        for (i, (effort, tokens)) in [(4.0, 4_000), (2.0, 6_000), (1.0, 10_000), (4.0, 0)].enumerated() {
            tl.add(0, "t\(i)", effort: effort)
            tl.attempt(0, "k\(i)", tag: "t\(i)")
            tl.at(1, .activity(attempt: "k\(i)", at: nil, tokens: Int64(tokens)), .harness)
            tl.at(2, .attemptEnd(attempt: "k\(i)", outcome: .ok), .harness)
        }
        tl.add(0, "open", effort: 1); tl.attempt(0, "ko", tag: "open"); tl.at(1, .activity(attempt: "ko", at: nil, tokens: 1_000_000), .harness)
        let runs = TaskFold.fold(tl.events, now: TL.t(3))
        // 1000, 3000, 10000 per unit: the median is 3000. The running leaf and the one with no tokens don't count.
        #expect(TaskFold.tokensPerEffortUnit(runs) == 3_000)
        var other = TL(); other.run = "r2"
        other.add(0, "z", effort: 1); other.attempt(0, "kz", tag: "z")
        other.at(1, .activity(attempt: "kz", at: nil, tokens: 5_000), .harness); other.at(2, .done(task: "z", evidence: nil))
        #expect(TaskFold.tokensPerEffortUnit(TaskFold.fold(tl.events + other.events, now: TL.t(3))) == 4_000)
        #expect(TaskFold.tokensPerEffortUnit([]) == nil)
        let calibrated = TaskFold.foldCalibrated(tl.events, now: TL.t(3)).first!
        #expect(calibrated.node("open").progress.estimate == 0.9)
    }

    @Test func mustHavesAndScope() {
        var tl = TL()
        tl.add(0, "a", importance: .critical); tl.add(0, "b", importance: .critical); tl.add(0, "c", importance: .critical); tl.add(0, "d")
        tl.at(1, .done(task: "a", evidence: nil))
        tl.at(1, .skip(task: "c", reason: nil))
        tl.add(2, "a", effort: 8) // effort change after work began
        tl.add(2, "a", effort: 8) // no change
        tl.add(2, "e")
        let r = tl.fold(3)
        #expect(r.mustHaves == TaskMustHaves(done: 1, total: 2))
        #expect(r.scopeChanges == 2)
    }
}

@Suite struct TaskCodingTests {
    static let allOps: [TaskEvent.Op] = [
        .meta(title: "Refactor", project: "headroom", harness: "claude-code"),
        .add(.init(id: "api/tests", title: "Tests", effort: 8, importance: .critical, steps: 5)),
        .add(.init(id: "x")),
        .start(task: "api/tests"),
        .progress(task: "api/tests", step: 2, total: 5, fraction: 0.4, note: "halfway"),
        .wait(task: "api/tests", attempt: nil, reason: .input, note: "permission"),
        .wait(task: nil, attempt: "agent:a", reason: .limit, note: nil),
        .wait(task: nil, attempt: nil, reason: .dependency, note: nil),
        .done(task: "api/tests", evidence: "42 pass"),
        .fail(task: "api", reason: "broken"),
        .skip(task: "docs", reason: nil),
        .cancel(task: "docs", reason: "dropped"),
        .attempt(.init(key: "agent:a", kind: .delegate, agentType: "Explore", model: "m", provider: "openai", tag: "api", parentKey: "session:1", title: "Look")),
        .activity(attempt: "agent:a", at: TL.t(5), tokens: 1234),
        .activity(attempt: "agent:a", at: nil, tokens: nil),
        .attemptEnd(attempt: "agent:a", outcome: .error),
        .stop(blocked: true), .stop(blocked: false), .resume, .end,
    ]

    @Test func eventsRoundTrip() throws {
        let events = Self.allOps.enumerated().map { TaskEvent(at: TL.t(Double($0.offset) + 0.125), run: "r1", source: .hook, op: $0.element) }
        let data = try events.reduce(into: Data()) { $0.append(try TaskJournal.line($1)) }
        #expect(TaskJournal.decode(data) == events)
        let first = String(decoding: try TaskJournal.line(events[1]), as: UTF8.self)
        #expect(first == #"{"effort":8,"importance":"critical","op":"task.add","run":"r1","src":"hook","steps":5,"task":"api/tests","title":"Tests","ts":"2027-01-15T08:00:01.125Z","v":1}"# + "\n")
    }

    @Test func unknownLinesAreSkippedOneByOne() {
        let text = """
        {"v":1,"ts":"2027-01-15T08:00:00Z","run":"r1","src":"agent","op":"task.add","task":"a","title":"A"}
        {"v":2,"ts":"2027-01-15T08:00:01.000Z","run":"r1","src":"agent","op":"task.teleport","task":"a"}
        not json at all
        {"v":2,"ts":"2027-01-15T08:00:02.000Z","run":"r1","src":"robot","op":"task.start","task":"a","colour":"blue","nested":{"x":[1,2]}}

        {"v":1,"ts":"2027-01-15T08:00:03.000Z","run":"r1","op":"task.done","task":"a"}
        {"v":1,"ts":"2027-01-15T08:00:04.000Z","run":"r1","op":"task.progr
        """
        let events = TaskJournal.decode(Data(text.utf8))
        #expect(events.map(\.op.name) == ["task.add", "task.start", "task.done"])
        #expect(events[1].source == .agent) // an unknown source falls back
        #expect(TaskFold.fold(events, now: TL.t(1e8)).first?.node("a").state == .done)
    }

    @Test func foldedOutputRoundTrips() throws {
        var tl = TL()
        tl.at(0, .meta(title: "Refactor", project: "headroom", harness: "claude-code"))
        tl.add(0, "api", importance: .critical); tl.add(0, "api/a", steps: 3)
        tl.attempt(1, "k", tag: "api/a"); tl.at(2, .progress(task: "api/a", step: 1, total: nil, fraction: nil, note: "n"))
        tl.at(3, .activity(attempt: "k", at: nil, tokens: 99), .harness)
        let feed = TasksFeed(generatedAt: TL.t(4), writerPID: 123, runs: [tl.fold(4)])
        let data = try TasksFile.encoder().encode(feed)
        let back = try TasksFile.decoder().decode(TasksFeed.self, from: data)
        #expect(back == feed)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["schema"] as? Int == 1 && obj["writer_pid"] as? Int == 123 && obj["generated_at"] as? String == "2027-01-15T08:00:04Z")
        let run = try #require((obj["runs"] as? [[String: Any]])?.first)
        #expect(run["must_haves"] != nil && run["scope_changes"] != nil && run["started_at"] != nil)
        let node = try #require((run["nodes"] as? [[String: Any]])?.last)
        #expect((node["progress"] as? [String: Any])?["in_flight"] != nil)
        #expect((node["attempts"] as? [String: Any])?["count"] as? Int == 1)
        // Unknown enum values from a newer writer don't break the read.
        let future = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""state":"running""#, with: #""state":"teleporting""#)
        #expect(try TasksFile.decoder().decode(TasksFeed.self, from: Data(future.utf8)).runs.first?.state == .running)
        #expect(!TasksFile.writerIsAlive(TasksFeed(generatedAt: TL.t(0), writerPID: 999_999, runs: [])))
        #expect(TasksFile.writerIsAlive(TasksFeed(generatedAt: TL.t(0), writerPID: getpid(), runs: [])))
    }

    @Test func journalFilesAppendConcurrently() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let note = String(repeating: "x", count: 3000)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<50 {
                let e = TaskEvent(at: TL.t(Double(i)), run: "r1", source: .agent, op: .progress(task: "w\(worker)", step: i, total: 50, fraction: nil, note: note))
                try? TaskJournal.append([e], stream: .journal, home: home)
            }
        }
        let events = TaskJournal.read(run: "r1", home: home)
        #expect(events.count == 400)
        let file = TaskJournal.url(run: "r1", stream: .journal, home: home)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: TaskJournal.directory(.journal, home: home).path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        try TaskJournal.append([TaskEvent(at: TL.t(0), run: "r2", source: .harness, op: .end)], stream: .observed, home: home)
        #expect(TaskJournal.runs(home: home) == ["r1", "r2"])
        #expect(TaskJournal.runs(home: home, modifiedSince: Date().addingTimeInterval(3600)).isEmpty)
        #expect(TaskJournal.readAll(home: home).count == 401)
        #expect(throws: TaskJournal.BadRunID.self) { try TaskJournal.append([TaskEvent(at: TL.t(0), run: "../x", source: .agent, op: .end)], stream: .journal, home: home) }
    }
}
