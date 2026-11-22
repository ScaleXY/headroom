import Foundation
import Testing
@testable import HeadroomKit

/// Efforts are any positive number (`--effort N`), so the fold's token sums must hold for all of
/// them: one absurd line in a journal used to trap every fold of it, in the CLI and the app.
@Suite struct TaskFoldExtremesTests {
    @Test func aHugeEffortGivesNoTokenForecastInsteadOfTrapping() {
        var tl = TL()
        tl.add(0, "big", effort: 1e15)
        tl.add(0, "small")
        tl.at(10, .start(task: "big"))
        // 100k tokens per unit × 1e15 units is past Int64.
        let r = tl.fold(60, tpu: 100_000)
        #expect(r.tokensToFinish == nil)
        #expect(r.state == .running && r.node("big").effort == 1e15)
        // An ordinary plan still gets its figure.
        var ok = TL()
        ok.add(0, "a", effort: 2)
        ok.at(10, .start(task: "a"))
        #expect(ok.fold(60, tpu: 100_000).tokensToFinish == 200_000)
    }

    @Test func sessionTokensSplitAcrossEffortsThatSumPastADouble() {
        var tl = TL()
        tl.add(0, "a", effort: 1e308)
        tl.add(0, "b", effort: 1e308)
        tl.at(10, .start(task: "a"))
        tl.at(10, .start(task: "b"))
        tl.session(20, 200, tokens: { Int64($0) * 1000 })
        let r = tl.fold(300)
        // Nothing is lost: what can't be split goes to the first task.
        #expect(r.tokens == 200_000)
        #expect(r.node("a").tokens + r.node("b").tokens == 200_000)
    }
}

@Suite struct TaskRetryCountTests {
    /// The guide's own retry: `fail`, `start` again, then the agent spawned for it. One retry,
    /// though both the start and the new agent come after the last attempt ended.
    @Test func aRestartAndTheAgentThatPicksItUpAreOneRetry() {
        var tl = TL()
        tl.add(0, "a")
        tl.at(1, .start(task: "a"))
        tl.attempt(2, "k1", tag: "a"); tl.at(5, .attemptEnd(attempt: "k1", outcome: .error), .harness)
        tl.at(6, .fail(task: "a", reason: "no"))
        tl.at(7, .start(task: "a"))
        #expect(tl.fold(8).node("a").attempts.retries == 1)
        tl.attempt(8, "k2", tag: "a")
        #expect(tl.fold(9).node("a").state == .running && tl.fold(9).node("a").attempts.retries == 1)
        // The agent after that one is a second retry, with or without a start.
        tl.at(10, .attemptEnd(attempt: "k2", outcome: .error), .harness)
        tl.attempt(11, "k3", tag: "a")
        #expect(tl.fold(12).node("a").attempts.retries == 2)
        // Reopened by an agent alone, after the orchestrator restarted and closed it itself.
        tl.at(13, .attemptEnd(attempt: "k3", outcome: .ok), .harness)
        tl.at(14, .fail(task: "a", reason: "still no"))
        tl.at(15, .start(task: "a"))
        tl.at(16, .done(task: "a", evidence: nil))
        tl.attempt(17, "k4", tag: "a")
        #expect(tl.fold(18).node("a").attempts.retries == 4)
    }
}
