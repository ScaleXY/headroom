import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

/// The Runs tab's one list: the lead run, sections by who moves next, settled runs by calendar
/// day with totals that agree with their rows, time worked, and short sessions folded.
@MainActor @Suite struct RunListTests {
    let now = Demo.now
    var p: RunsPresenter { RunsPresenter(now: Demo.now, pricing: (try? PriceTable.bundled()).map(PricingEngine.init(table:))) }

    @Test func theLeadIsWhoeverMovesNextFirst() {
        let ask = Demo.inputRun(now: now), turn = Demo.yourTurnRun(now: now), work = Demo.declaredRun(now: now)
        #expect(p.page([work, turn, ask]).leadID == ask.id)
        #expect(p.page([work, turn]).leadID == turn.id)
        #expect(p.page([work, Demo.quietRun(now: now)]).live.map(\.phase) == [.working, .working])
        // Nothing live: no lead, and the day's receipt instead.
        let settled = p.page(Demo.settledRuns(now: now))
        #expect(settled.leadID == nil && settled.receipt != nil && settled.live.isEmpty)
    }

    @Test func liveNeverCountsYourTurnOrLeftAsWorking() {
        let page = p.page(Demo.mixedRuns(now: now))
        let phases = Dictionary(uniqueKeysWithValues: page.live.map { ($0.id, $0.phase) })
        #expect(phases[Demo.yourTurnRun(now: now).id] == .yourTurn)
        #expect(phases[Demo.leftRun(now: now).id] == nil)
        #expect(page.live.filter { $0.phase == .working }.count == 3)
        #expect(page.days.flatMap { $0.cards + $0.short }.contains { $0.id == Demo.leftRun(now: now).id })
    }

    @Test func daysAreCalendarDaysAndTheirTotalsCoverEveryRun() {
        let runs = Demo.settledRuns(now: now)
        let page = p.page(runs)
        #expect(page.days.map(\.title) == ["Today", "Yesterday"])
        let today = page.days[0], yesterday = page.days[1]
        let start = Display.calendar.startOfDay(for: now)
        let todays = runs.filter { $0.updatedAt >= start }
        // The header counts every settled run of the day: listed, past the cap, or folded short.
        #expect(today.runs == todays.count && today.runs == today.cards.count + today.more + today.short.count)
        #expect(today.outcomes.done + today.outcomes.failed + today.outcomes.left + today.outcomes.closed == today.runs)
        #expect(abs(today.worked - todays.reduce(0) { $0 + RunsPresenter.worked($1) }) < 1e-6)
        #expect(today.summary.hasPrefix("\(today.runs) runs · "))
        #expect(yesterday.cards.map(\.id) == [Demo.failedRun(now: now).id])
        // The receipt agrees with today's header.
        #expect(page.receipt?.costCaption == "API value across \(today.runs) runs" && page.receipt?.worked == RunsPresenter.duration(today.worked))
    }

    @Test func shortSessionsFoldButStillCount() {
        let day = p.page(Demo.settledRuns(now: now)).days[0]
        #expect(day.short.count == 3 && day.shortLine?.hasPrefix("3 short sessions · 12m") == true)
        // A short run the agent planned, or one with agents, is listed as usual.
        #expect(!day.short.contains { $0.id == Demo.shortRun(now: now).id })
        var withAgents = Demo.shortSessions(now: now)[0]
        withAgents.nodes[0].attempts = TaskAttemptsSummary(count: 1)
        #expect(!RunsPresenter.worthWatching(Demo.shortSessions(now: now)[0]) && RunsPresenter.worthWatching(withAgents))
    }

    @Test func rowsLeadWithTimeWorked() {
        var reopened = Demo.finishedRun(now: now)
        // Reopened days later: open for 128 hours, worked 1h 23m.
        reopened.startedAt = now.addingTimeInterval(-128 * 3600)
        reopened.time = TaskTimeSplit(working: 83 * 60, idle: 126 * 3600)
        let c = p.card(reopened)
        #expect(c.line.detail?.contains("1h 23m working") == true && c.receipt?.duration == "1h 23m" && c.receipt?.open == "5d 5h")
        #expect(c.worked == 83 * 60)
    }

    @Test func eachStateHasItsWordsAndColour() {
        let turn = p.card(Demo.yourTurnRun(now: now))
        #expect(turn.line.key == "Your turn · 8m" && turn.line.keyTone == .neutral && turn.tone == .neutral && turn.glyph == .yourTurn)
        #expect(turn.line.detail == "2 open · 1 for you")
        #expect(turn.lead?.badge == "Your turn" && turn.lead?.since == "8m ago · worked 24m this turn")
        // Yours first in what's left, and marked.
        #expect(turn.lead?.rows.first?.marker == "yours")
        let left = p.card(Demo.leftRun(now: now))
        #expect(left.stateText == "Left at 95% · must-haves done" && left.line.key == "Left at 95%" && left.tone == .neutral && !left.live)
        #expect(left.receipt != nil && left.actions.resume && left.actions.close)
        // Earlier jobs sit under "This session" on its page.
        #expect(left.page?.groups.last?.title == "This session · 3 jobs")
        // Amber is only time and limits; rose only a question.
        #expect(p.card(Demo.limitRun(now: now)).line.keyTone == .warn && p.card(Demo.quietRun(now: now)).line.keyTone == .warn)
        #expect(p.card(Demo.inputRun(now: now)).line.keyTone == .alert)
        #expect(p.card(Demo.abandonedRun(now: now)).stateText == "Closed")
        #expect(RunOutcomes(p.page(Demo.settledRuns(now: now)).days[0].cards).words.contains("1 closed"))
    }

    @Test func recentRunsSumTimeWorked() throws {
        let m = try #require(RecentRunsPresenter(now: now).model([RunRecord(Demo.leftRun(now: now)), RunRecord(Demo.finishedRun(now: now))]))
        #expect(m.summary == "2 runs · 5h 1m")
        #expect(m.rows.map(\.outcome).contains("Left at 95%"))
    }
}
