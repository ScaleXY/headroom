import Foundation
import Testing
@testable import HeadroomKit

@Suite struct UndeclaredRunTests {
    /// An orchestrator with agents a and b, and c spawned by a; nothing declared.
    func spawned() -> TL {
        var tl = TL()
        tl.at(0, .attempt(.init(key: "session:1", kind: .session)), .harness)
        tl.attempt(1, "agent:a", parent: "session:1")
        tl.attempt(2, "agent:b", parent: "session:1")
        tl.attempt(3, "agent:c", parent: "agent:a")
        return tl
    }

    @Test func agentsCountAsThePlan() {
        var tl = spawned()
        var run = tl.fold(10)
        #expect(!run.hasDeclaredTasks)
        // The session is no task: its agents sit at the top.
        #expect(run.nodes.map(\.id) == ["~agent-a", "~agent-c", "~agent-b"])
        #expect(run.node("~agent-a").parent == nil && run.node("~agent-c").parent == "~agent-a")
        #expect(run.state == .running && run.progress.done == 0)

        tl.at(20, .attemptEnd(attempt: "agent:b", outcome: .ok), .harness)
        tl.at(21, .attemptEnd(attempt: "agent:c", outcome: .ok), .harness)
        run = tl.fold(30)
        // Finished agents over spawned agents: b and c of a, b, c. A weighs its own unit and c's.
        #expect(near(run.node("~agent-a").progress.estimate, 0.5) && run.node("~agent-a").effort == 8)
        #expect(near(run.progress.estimate, 2.0 / 3))
        // Agents ending on their own are a guess, not a confirmed outcome.
        #expect(run.progress.done == 0)
        #expect(run.state == .running && run.node("~agent-a").state == .running)
        #expect(near(run.node("~agent-b").share + run.node("~agent-c").share, 2.0 / 3))

        tl.at(40, .attemptEnd(attempt: "agent:a", outcome: .ok), .harness)
        run = tl.fold(50)
        // Every agent has ended but the orchestrator's turn hasn't: still running, not done.
        #expect(run.state == .running && run.progress.estimate < 1)
        tl.at(45, .stop(blocked: false), .hook)
        run = tl.fold(50)
        #expect(run.state == .done && run.progress == .complete)
        #expect(run.nodes.allSatisfy { $0.counted })
    }

    @Test func aRunWithNoPlanIsntDoneBetweenBatches() {
        var tl = spawned()
        for (s, k) in [(20.0, "agent:c"), (21, "agent:a"), (22, "agent:b")] { tl.at(s, .attemptEnd(attempt: k, outcome: .ok), .harness) }
        // The orchestrator keeps working after its agents: not done, so no "finished" alert...
        tl.session(23, 300)
        #expect(tl.fold(300).state == .running)
        // ...and the next batch carries on the same run.
        tl.attempt(310, "agent:d", parent: "session:1")
        #expect(tl.fold(320).state == .running)
        tl.at(400, .attemptEnd(attempt: "agent:d", outcome: .ok), .harness)
        // A stop from before the last agent ended doesn't finish it either.
        var early = tl
        early.at(350, .stop(blocked: false), .hook)
        #expect(early.fold(410).state == .running)
        tl.at(410, .stop(blocked: false), .hook)
        #expect(tl.fold(420).state == .done)
        // A session that ended for good finishes it too.
        var ended = spawned()
        for (s, k) in [(20.0, "agent:c"), (21, "agent:a"), (22, "agent:b")] { ended.at(s, .attemptEnd(attempt: k, outcome: .ok), .harness) }
        ended.at(30, .end, .hook)
        #expect(ended.fold(40).state == .done)
    }

    @Test func aFailedAgentMakesTheRunPartial() {
        var tl = spawned()
        for (s, k) in [(20.0, "agent:c"), (21, "agent:a")] { tl.at(s, .attemptEnd(attempt: k, outcome: .ok), .harness) }
        tl.at(22, .attemptEnd(attempt: "agent:b", outcome: .error), .harness)
        tl.at(23, .stop(blocked: false), .hook)
        let run = tl.fold(30)
        #expect(run.state == .partial && run.node("~agent-b").state == .failed)
    }

    @Test func declaringLateKeepsEarlierAgentsCounting() {
        var tl = spawned()
        tl.attempt(3, "agent:d", parent: "session:1")
        for (s, k) in [(4.0, "agent:b"), (4, "agent:c"), (4, "agent:a")] { tl.at(s, .attemptEnd(attempt: k, outcome: .ok), .harness) }
        // Three of four agents done, then one task declared: the agents stay as earlier work.
        let before = tl.fold(6).progress.estimate
        tl.add(5, "api")
        tl.attempt(20, "agent:late", parent: "session:1")
        tl.at(25, .attemptEnd(attempt: "agent:late", outcome: .ok), .harness)
        let run = tl.fold(30)
        #expect(run.hasDeclaredTasks && !run.mirrored)
        #expect(run.nodes.map(\.id) == [TaskFold.earlierID, "~agent-a", "~agent-c", "~agent-b", "~agent-d", "api", "~agent-late"])
        #expect(run.node(TaskFold.earlierID).title == TaskFold.earlierTitle && run.node("~agent-b").parent == TaskFold.earlierID)
        #expect(run.node("~agent-b").counted && run.node("api").counted)
        // An agent spawned after the plan is a helper.
        #expect(!run.node("~agent-late").counted && run.node("~agent-late").share == 0)
        // Four agents (16) beside one task (4): three quarters of 16 of 20.
        #expect(near(before, 0.75) && near(run.progress.estimate, 0.6))
        // Shares: the counted leaves, plus a's own unit beside the agent it spawned, make the whole.
        let leaves = run.nodes.filter { $0.leaf && $0.counted }.reduce(0) { $0 + $1.share }
        #expect(near(run.node(TaskFold.earlierID).share, 0.8) && near(run.node("api").share, 0.2))
        #expect(near(leaves + run.node("~agent-a").share - run.node("~agent-c").share, 1))
    }

    @Test func observedWaitsDontDeclare() {
        var tl = spawned()
        tl.at(5, .wait(task: nil, attempt: "agent:b", reason: .input, note: nil), .harness)
        let run = tl.fold(6)
        #expect(!run.hasDeclaredTasks && !run.node("~agent-b").declared)
        #expect(run.node("~agent-b").state == .waiting && run.node("~agent-b").waitReason == .input)
        // A wait naming the orchestrator is the run's own.
        var tl2 = spawned()
        tl2.at(5, .wait(task: nil, attempt: "session:1", reason: .input, note: nil), .harness)
        #expect(tl2.fold(6).needsInput)
    }

    @Test func aLaterLabelNamesTheAgentsTask() {
        var tl = TL()
        tl.at(1, .attempt(.init(key: "agent:a", agentType: "Explore")), .hook)
        #expect(tl.fold(2).node("~agent-a").title == "Explore")
        tl.attempt(3, "agent:a", parent: "session:1", title: "Survey the API")
        #expect(tl.fold(4).node("~agent-a").title == "Survey the API")
    }

    @Test func sessionActivityKeepsTheRunFreshAndCountsTokens() {
        var tl = spawned()
        tl.at(900, .activity(attempt: "session:1", at: nil, tokens: 500), .harness)
        let run = tl.fold(1000, stale: 300)
        #expect(!run.stale && run.tokens == 500)
    }

    @Test func feedsWithoutTheFieldStillDecode() throws {
        var tl = spawned()
        tl.add(5, "api")
        let feed = TasksFeed(generatedAt: TL.t(10), writerPID: 1, runs: [tl.fold(10), spawned().fold(10)])
        var obj = try #require(try JSONSerialization.jsonObject(with: TasksFile.encoder().encode(feed)) as? [String: Any])
        obj["runs"] = (obj["runs"] as! [[String: Any]]).map { r in var r = r; r["has_declared_tasks"] = nil; return r }
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(!String(decoding: old, as: UTF8.self).contains("has_declared_tasks"))
        let decoded = try TasksFile.decoder().decode(TasksFeed.self, from: old)
        #expect(decoded.runs.map(\.hasDeclaredTasks) == [true, false])
        // And a current feed round-trips.
        let again = try TasksFile.decoder().decode(TasksFeed.self, from: TasksFile.encoder().encode(feed))
        #expect(again.runs.map(\.hasDeclaredTasks) == [true, false] && again.runs.map(\.id) == feed.runs.map(\.id))
    }
}

@Suite struct TaskLimitTests {
    let now = TL.t(0)
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let locale = Locale(identifier: "en_US")

    func run(eta: Double?, provider: String = "claude") -> TaskRun {
        let attempt = TaskAttempt(key: "agent:a", provider: provider, startedAt: now)
        return TaskRun(id: "r", title: "Run", harness: "claude-code", startedAt: now, updatedAt: now, state: .running, etaSeconds: eta,
                       nodes: [TaskNode(id: "~agent-a", title: "a", state: .running, attempts: TaskAttemptsSummary(count: 1, active: 1, last: attempt))])
    }

    @Test func aBlockedProviderMakesTheRunWaitForTheLimit() {
        let until = now.addingTimeInterval(5400)
        let blocked = ProviderSnapshot(id: .claude, blocked: BlockedSnapshot(by: "session", detail: nil, until: until))
        let r = TaskLimits.adjust(run(eta: nil), providers: [blocked], now: now, calendar: calendar, locale: locale)
        #expect(r.state == .waiting && r.waitReason == .limit)
        #expect(r.warning == "Claude 5-hour limit reached, back today 9:30 AM.")
        // A provider the run doesn't use, or a block already over, changes nothing.
        let other = ProviderSnapshot(id: .codex, blocked: BlockedSnapshot(by: "weekly", detail: nil, until: until))
        #expect(TaskLimits.adjust(run(eta: nil), providers: [other], now: now, calendar: calendar, locale: locale).warning == nil)
        let over = ProviderSnapshot(id: .claude, blocked: BlockedSnapshot(by: "session", detail: nil, until: now.addingTimeInterval(-1)))
        #expect(TaskLimits.adjust(run(eta: nil), providers: [over], now: now, calendar: calendar, locale: locale).state == .running)
    }

    @Test func aSessionThatRunsOutBeforeTheFinishWarns() {
        let session = SessionSnapshot(used: 0.8, left: 0.2, resetsAt: now.addingTimeInterval(4 * 3600), level: "rose", runsOutAt: now.addingTimeInterval(1800))
        let s = ProviderSnapshot(id: .codex, session: session)
        let r = TaskLimits.adjust(run(eta: 3600, provider: "codex"), providers: [s], now: now, calendar: calendar, locale: locale)
        #expect(r.state == .running)
        #expect(r.warning == "Codex 5-hour limit will likely run out first: around 8:30 AM, finish around 9 AM.")
        // Finishing first, or no forecast: no warning.
        #expect(TaskLimits.adjust(run(eta: 600, provider: "codex"), providers: [s], now: now, calendar: calendar, locale: locale).warning == nil)
        #expect(TaskLimits.adjust(run(eta: nil, provider: "codex"), providers: [s], now: now, calendar: calendar, locale: locale).warning == nil)
        // A finished run spends nothing.
        var done = run(eta: 3600, provider: "codex")
        done.state = .done
        #expect(TaskLimits.adjust(done, providers: [s], now: now, calendar: calendar, locale: locale).warning == nil)
    }
}
