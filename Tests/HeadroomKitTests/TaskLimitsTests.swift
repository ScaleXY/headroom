import Foundation
import Testing
@testable import HeadroomKit

/// The limit outlook and the room line, on fixed snapshots (8:00 AM UTC).
@Suite struct TaskLimitOutlookTests {
    let now = TL.t(0)
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let locale = Locale(identifier: "en_US")

    func h(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    /// A live Claude Code run burning `rate` tokens an hour with `need` still to go.
    func run(_ state: TaskRunState = .running, rate: Double? = 400_000, need: Int64? = 1_100_000, eta: Double? = nil) -> TaskRun {
        TaskRun(id: "r", title: "Move checkout", harness: "claude-code", startedAt: now, updatedAt: now, state: state, etaSeconds: eta,
                recentTokensPerHour: rate, tokensToFinish: need)
    }

    func claude(used: Double, resetsIn: Double = 1.5, runsOutIn: Double? = nil, blocked: BlockedSnapshot? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: .claude, session: SessionSnapshot(used: used, left: 1 - used, resetsAt: h(resetsIn), level: "normal",
                                                               runsOutAt: runsOutIn.map(h)), blocked: blocked)
    }

    func adjust(_ r: TaskRun, _ s: ProviderSnapshot, spend: ProviderSpend? = nil) -> TaskRun {
        TaskLimits.adjust(r, providers: [s], spend: spend.map { [.claude: $0] } ?? [:], now: now, calendar: calendar, locale: locale)
    }

    @Test func aRunThatOutlastsTheWindowPausesAndFinishesAfterTheReset() {
        // 1.1M tokens at 400K an hour: 2h 45m of work. The window gives out in 30 minutes, resets in 1h 30m.
        let r = adjust(run(), claude(used: 0.62, runsOutIn: 0.5), spend: ProviderSpend(tokensPerHour: 640_000, windowTokens: 2_480_000))
        let o = try! #require(r.limitOutlook)
        #expect(o.provider == .claude && o.pauseAt == h(0.5) && o.resumeAt == h(1.5))
        // The 2h 15m left after the pause start again at the reset.
        #expect(o.finishAt == h(1.5 + 2.25))
        #expect(o.tokensNeeded == 1_100_000)
        // 2.48M tokens were 62% of the window: 4M in all, 1.52M left.
        #expect(o.roomTokens == 1_520_000)
        #expect(o.share == 0.625)
        #expect(r.state == .running)
        #expect(r.warning == "Claude 5-hour limit will likely run out first: around 8:30 AM, finish around 10:45 AM.")
    }

    @Test func fromTheFirstMinuteWithoutAForecast() {
        // No task has closed (no ETA), but the burn rate says enough.
        let r = adjust(run(eta: nil), claude(used: 0.2, runsOutIn: 1.0), spend: ProviderSpend(tokensPerHour: 400_000))
        #expect(r.limitOutlook?.pauseAt == h(1.0) && r.limitOutlook?.share == 1)
    }

    @Test func withNoPercentRunOutTheWindowIsWorkedOutInTokens() {
        // No runs-out time from the samples: 0.6M of room at 1.2M an hour is 30 minutes.
        let r = adjust(run(), claude(used: 0.85), spend: ProviderSpend(tokensPerHour: 1_200_000, windowTokens: 3_400_000))
        #expect(r.limitOutlook?.roomTokens == 600_000)
        #expect(r.limitOutlook?.pauseAt == h(0.5))
        // Too little used to size the window: nothing in tokens, and no pause.
        let early = adjust(run(), claude(used: 0.02), spend: ProviderSpend(tokensPerHour: 1_200_000, windowTokens: 10_000))
        #expect(early.limitOutlook?.roomTokens == nil && early.limitOutlook?.pauseAt == nil)
        #expect(early.limitOutlook?.finishAt == h(2.75))
    }

    @Test func finishingBeforeTheWindowGivesOutHasNoPause() {
        let r = adjust(run(need: 200_000), claude(used: 0.4, runsOutIn: 1.0))
        #expect(r.limitOutlook?.pauseAt == nil && r.limitOutlook?.finishAt == h(0.5) && r.warning == nil)
        // A window that lasts to its reset doesn't pause anything.
        let lasts = adjust(run(), claude(used: 0.4, runsOutIn: 2.0))
        #expect(lasts.limitOutlook?.pauseAt == nil)
    }

    @Test func aBlockedProviderPausesNow() {
        let block = BlockedSnapshot(by: "session", detail: nil, until: h(1))
        let r = adjust(run(), claude(used: 1, blocked: block))
        #expect(r.state == .waiting && r.waitReason == .limit)
        #expect(r.limitOutlook?.pauseAt == now && r.limitOutlook?.resumeAt == h(1) && r.limitOutlook?.finishAt == h(1 + 2.75))
    }

    @Test func aStoppedRunIsNotWaitingOnTheLimit() {
        let block = BlockedSnapshot(by: "session", detail: nil, until: h(1))
        let r = adjust(run(.stopped), claude(used: 1, blocked: block))
        #expect(r.state == .stopped && r.waitReason == nil && r.limitOutlook == nil)
        // It still says why nothing can go on.
        #expect(r.warning == "Claude 5-hour limit reached, back today 9 AM.")
        #expect(adjust(run(.stopped), claude(used: 0.4, runsOutIn: 0.5)).limitOutlook == nil)
    }

    @Test func waitingOnAPersonStaysThatWay() {
        var asking = run(.waiting)
        asking.waitReason = .input
        let r = adjust(asking, claude(used: 1, blocked: BlockedSnapshot(by: "session", detail: nil, until: h(1))))
        #expect(r.waitReason == .input && r.limitOutlook?.pauseAt == now)
    }

    @Test func nothingKnownMeansNoOutlook() {
        #expect(adjust(run(rate: nil, need: nil), claude(used: 0.4)).limitOutlook == nil)
    }

    @Test func theRoomLine() {
        let line = { TaskLimits.roomLine(.claude, providers: [$0], now: self.now, calendar: self.calendar, locale: self.locale) }
        #expect(line(claude(used: 0.62, resetsIn: 7)) == "5-hour window 38% left, resets 3 PM")
        #expect(line(claude(used: 0.8, resetsIn: 2, runsOutIn: 0.5)) == "5-hour window 20% left, resets 10 AM; at this rate it runs out around 8:30 AM")
        #expect(line(claude(used: 1, blocked: BlockedSnapshot(by: "session", detail: nil, until: h(1)))) == "5-hour window used up, back today 9 AM")
        #expect(TaskLimits.roomLine(.codex, providers: [claude(used: 0.5)], now: now) == nil)
        #expect(TaskLimits.roomLine(.claude, providers: [ProviderSnapshot(id: .claude)], now: now) == nil)
    }
}
