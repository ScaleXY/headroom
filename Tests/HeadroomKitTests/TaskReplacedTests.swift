import Foundation
import Testing
@testable import HeadroomKit

/// Outcomes an agent reported correctly must not read as failures: a failed approach another task
/// took over from, a failure fixed later, work cancelled because the plan changed.
@Suite struct TaskReplacedTests {
    func node(_ r: TaskRun, _ id: String) -> TaskNode? { r.nodes.first { $0.id == id } }

    /// The real run that prompted this: root access failed, non-root tuning took over and finished.
    @Test func aFailureTheAgentWorkedAroundIsNotAFailure() throws {
        var tl = TL()
        tl.add(0, "app", importance: .critical); tl.add(0, "root", effort: 4)
        tl.at(1, .done(task: "app", evidence: "built"))
        tl.at(2, .start(task: "root"))
        tl.at(90, .fail(task: "root", reason: "locked bootloader, no exploit. Doing non-root shell-level tuning instead."))
        tl.add(90, "tune", effort: 4)
        tl.at(91, .start(task: "tune"))
        tl.at(300, .done(task: "tune", evidence: "14 apps disabled"))
        let r = tl.fold(400)
        #expect(r.state == .done && r.progress.estimate == 1)
        let root = try #require(node(r, "root"))
        #expect(root.state == .failed && root.replacedBy == "tune" && !root.counted)
        #expect(root.failure?.hasPrefix("locked bootloader") == true)
    }

    @Test func aPivotNeedsItsWordsAndANewTaskSoon() {
        // No pivot words: an ordinary failure, even with a task added right after.
        var plain = TL()
        plain.add(0, "a"); plain.at(1, .fail(task: "a", reason: "timed out")); plain.add(2, "b"); plain.at(3, .done(task: "b", evidence: nil))
        #expect(plain.fold(10).state == .partial)
        // Pivot words, but the next task comes much later: not taken as its replacement.
        var late = TL()
        late.add(0, "a"); late.at(1, .fail(task: "a", reason: "no root; trying another way instead")); late.add(600, "b")
        late.at(601, .done(task: "b", evidence: nil))
        #expect(late.fold(700).state == .partial)
    }

    @Test func anExplicitInsteadLinksEvenWithoutTheWords() throws {
        var tl = TL()
        tl.add(0, "a", importance: .critical)
        tl.at(1, .fail(task: "a", reason: "timed out", instead: "b"))
        tl.add(2, "b")
        // The replacement of a must-have is one.
        #expect(node(tl.fold(3), "b")?.importance == .critical)
        #expect(tl.fold(3).state == .running || tl.fold(3).state == .stopped)
        tl.at(4, .done(task: "b", evidence: nil))
        let r = tl.fold(10)
        #expect(r.state == .done && r.mustHaves == TaskMustHaves(done: 1, total: 1))
    }

    @Test func ifTheReplacementFailsTheOriginalCountsAgain() {
        var tl = TL()
        tl.add(0, "a", importance: .critical)
        tl.at(1, .fail(task: "a", reason: "nope", instead: "b")); tl.add(1, "b")
        tl.at(2, .fail(task: "b", reason: "nope either"))
        let r = tl.fold(10)
        #expect(r.state == .failed && node(r, "a")?.replacedBy == nil)
    }

    @Test func aFailureFixedLaterIsDoneAndForgetsWhyItFailed() throws {
        var tl = TL()
        tl.add(0, "test")
        tl.at(1, .fail(task: "test", reason: "5 tests timed out"))
        tl.at(5, .start(task: "test"))
        tl.at(9, .done(task: "test", evidence: "all pass"))
        let r = tl.fold(10)
        let t = try #require(node(r, "test"))
        #expect(r.state == .done && t.state == .done && t.failure == nil && t.attempts.retries == 1)
    }

    @Test func cancelledWorkIsAPlanChangeNotAFailure() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.at(1, .done(task: "a", evidence: nil))
        tl.at(2, .cancel(task: "b", reason: "not needed after the redesign"))
        var r = tl.fold(10)
        #expect(r.state == .done && r.progress.estimate == 1)
        // A must-have dropped leaves the run short, though not failed.
        var must = TL()
        must.add(0, "a"); must.add(0, "b", importance: .critical)
        must.at(1, .done(task: "a", evidence: nil)); must.at(2, .cancel(task: "b", reason: nil))
        r = must.fold(10)
        #expect(r.state == .partial)
    }

    @Test func anAbandonedRunIsNeverDone() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.at(1, .done(task: "a", evidence: nil))
        tl.at(2, .abandon(reason: nil), .user)
        let r = tl.fold(10)
        #expect(r.abandoned && r.state == .partial)
    }

    @Test func insteadRoundTripsOnTheWire() throws {
        let e = TaskEvent(at: TL.t(0), run: "r", source: .agent, op: .fail(task: "a", reason: "x", instead: "b"))
        let back = try TaskJournal.decoder().decode(TaskEvent.self, from: TaskJournal.line(e))
        #expect(back.op == e.op)
    }
}
