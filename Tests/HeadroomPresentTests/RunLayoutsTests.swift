import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

/// The run page's parts: one status line, open tasks under their parents, the limit, the lanes.
@MainActor @Suite struct RunLayoutsTests {
    let now = Demo.now
    var presenter: RunsPresenter { RunsPresenter(now: now) }

    @Test func aRunningRunSaysWhatsRunningInOneLine() {
        let page = presenter.pageModel(Demo.declaredRun(now: now))
        #expect(page.status.key == "3 running")
        #expect(page.status.detail == "Refund webhooks, Receipts, Cover checkout end to end")
        #expect(page.groupsTitle == "Open tasks")
    }

    @Test func statusFollowsTheState() {
        #expect(presenter.pageModel(Demo.inputRun(now: now)).status == RunStatusModel(key: "Waiting on you", detail: "Switch the queries over asks"))
        #expect(presenter.pageModel(Demo.observedRun(now: now)).status.key == "2 agents running")
        #expect(presenter.pageModel(Demo.limitRun(now: now)).status.key == "Paused at the limit")
        let quiet = presenter.pageModel(Demo.quietRun(now: now)).status
        #expect(quiet.key.hasPrefix("Quiet ") && quiet.detail?.hasPrefix("on ") == true)
        #expect(presenter.pageModel(Demo.finishedRun(now: now)).status.key == RunWords.done)
        #expect(presenter.pageModel(Demo.abandonedRun(now: now)).status.key == RunWords.abandoned)
    }

    @Test func openTasksSitUnderTheirParentsAndFinishedOnesFold() {
        let r = Demo.declaredRun(now: now)
        let page = presenter.pageModel(r)
        let titled = page.groups.map { ($0.title, $0.rows.map(\.title)) }
        #expect(titled.contains { $0.0 == "Rewrite the routes › Refunds" && $0.1 == ["Refund webhooks", "Audit log"] })
        #expect(titled.contains { $0.0 == "Port the checkout endpoints › Rewrite the routes" && $0.1 == ["Receipts"] })
        // Top-level tasks read as "Other" beside named groups, and come last.
        #expect(page.groups.last?.title == "Other")
        #expect(page.groups.last?.rows.map(\.title) == ["Cover checkout end to end", "Update the integration guide"])
        #expect(page.groups.allSatisfy { g in g.rows.allSatisfy { $0.glyph != .done } })
        #expect(page.openCount == 5 && page.doneCount == 5 && !page.showDone)

        let shown = presenter.pageModel(r, showDone: true)
        #expect(shown.showDone && shown.groups.last?.title == "Done" && shown.groups.last?.rows.count == 5)
    }

    @Test func aFinishedRunListsWhatDidntFinish() {
        let page = presenter.pageModel(Demo.replacedRun(now: now))
        #expect(page.groupsTitle == "Didn't finish")
        #expect(page.groups.flatMap(\.rows).allSatisfy { $0.glyph != .done })
        #expect(page.lanes == nil && page.limit == nil)
        #expect(page.facts.map(\.label).starts(with: ["Took", "Tokens"]))
    }

    @Test func theLimitIsOneLineWithItsForecast() throws {
        let page = presenter.pageModel(Demo.timelineRun(now: now))
        let limit = try #require(page.limit)
        #expect(!limit.pause.isEmpty && !limit.resume.isEmpty && limit.finish?.hasPrefix("~") == true)
        #expect(limit.note?.contains("62%") == true)
        #expect(page.line?.hasPrefix("Pauses \(limit.pause) at the limit") == true)
        #expect(page.facts.first?.label == "Done")
        #expect(page.facts.contains { $0.mustHave && $0.value == "2 of 3" })
    }

    @Test func theListLineLeadsWithTheQuestion() {
        let page = presenter.pageModel(Demo.inputRun(now: now))
        #expect(page.line?.hasPrefix("“May I drop the unused audit table?") == true)
    }

    @Test func lanesPutWorkOnOneTimeAxisWithThePause() throws {
        let lanes = try #require(presenter.pageModel(Demo.timelineRun(now: now)).lanes)
        let pause = try #require(lanes.pause)
        #expect(lanes.now > 0 && lanes.now < pause.lowerBound && pause.upperBound < 1)
        // Open tasks first, the finished ones in one lane last.
        #expect(lanes.lanes.last?.id == "~done" && lanes.lanes.last?.bars.count == 5)
        let running = try #require(lanes.lanes.first { $0.title == "Cover checkout end to end" })
        #expect(running.mustHave && running.bars.contains { $0.kind == .running && $0.end <= lanes.now + 0.001 })
        // What's left of it is forecast, and never inside the pause.
        let ahead = running.bars.filter { $0.kind == .forecast }
        #expect(!ahead.isEmpty && ahead.allSatisfy { $0.start >= lanes.now - 0.001 && !($0.start > pause.lowerBound && $0.end < pause.upperBound) })
        #expect(lanes.ticks.contains { $0.kind == .now } && lanes.ticks.filter { $0.kind == .limit }.count == 2)
        #expect(lanes.ticks.contains { $0.kind == .finish })
        // Labels never crowd each other.
        for (a, b) in zip(lanes.ticks, lanes.ticks.dropFirst()) where a.kind == .plain || b.kind == .plain { #expect(b.at - a.at >= 0.1) }
        #expect(lanes.lanes.allSatisfy { $0.bars.allSatisfy { $0.start >= 0 && $0.end <= 1 && $0.end >= $0.start } })
    }

    @Test func aRunAskingDrawsItsLaneInRoseFromTheQuestion() throws {
        let lanes = try #require(presenter.pageModel(Demo.inputRun(now: now)).lanes)
        let asking = try #require(lanes.lanes.first)
        #expect(asking.title == "Switch the queries over")
        // Blue while it worked, rose from the question to now.
        #expect(asking.bars.map(\.kind) == [.running, .asking])
        let turn = asking.bars[1].start
        #expect(asking.bars[0].end == turn && abs(asking.bars[1].end - lanes.now) < 0.001)
        #expect(asking.status == "Asks you · 4m" && asking.statusTone == .alert)
        #expect(lanes.lanes.first { $0.title == "Compare query times" }?.status == "Not started")
    }

    @Test func runningLanesSayWhenTheyreForecastToFinish() throws {
        let lanes = try #require(presenter.pageModel(Demo.timelineRun(now: now)).lanes)
        let running = lanes.lanes.filter { $0.glyph == .running }
        #expect(!running.isEmpty && running.allSatisfy { $0.status?.hasPrefix("~") == true })
        // The finish is on the axis and in the model; the run's start labels the left edge.
        let finish = try #require(lanes.finish)
        #expect(finish > lanes.now && lanes.ticks.contains { $0.kind == .finish && $0.at == finish })
        #expect(lanes.ticks.first?.kind == .start && lanes.ticks.first?.at == 0)
    }

    @Test func aRunPausedAtTheLimitShowsThePauseItsIn() throws {
        let lanes = try #require(presenter.pageModel(Demo.limitRun(now: now)).lanes)
        let pause = try #require(lanes.pause)
        // Now sits inside the pause, which runs from when it stopped to the reset.
        #expect(pause.lowerBound < lanes.now && lanes.now < pause.upperBound && pause.upperBound < 1)
        let held = try #require(lanes.lanes.first { $0.title == "Merge duplicate contacts" })
        #expect(held.status == "Back 10:48")
        #expect(held.bars.map(\.kind) == [.running, .held, .forecast])
        #expect(held.bars[2].start >= pause.upperBound - 0.001)
        #expect(lanes.ticks.filter { $0.kind == .limit }.count == 2 && lanes.finish != nil)
    }

    @Test func finishedTasksShareALaneThatCountsFailures() throws {
        let lanes = try #require(presenter.pageModel(Demo.timelineRun(now: now)).lanes)
        let done = try #require(lanes.lanes.last)
        #expect(done.isFinished && done.status == nil)
        let merged = RunLanesModel.merged(done.bars)
        #expect(!merged.isEmpty && merged.count <= done.bars.count)
        for (a, b) in zip(merged, merged.dropFirst()) { #expect(a.upperBound < b.lowerBound) }
    }

    @Test func dayTicksStayOnMidnightWhenTheClocksChange() throws {
        // Clocks go back on Sunday 1 November 2026 in New York: that day has 25 hours.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10)))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12)))
        var r = Demo.declaredRun(now: now)
        r.startedAt = start
        let lanes = try #require(RunsPresenter(now: now, calendar: cal, locale: Locale(identifier: "en_US")).lanes(r))
        let days = lanes.ticks.filter { $0.kind == .plain }.map(\.label)
        #expect(Array(days.prefix(3)) == ["Sun", "Mon", "Tue"])
    }

    @Test func everyDemoRunBuildsAPage() {
        for s in Demo.runScenarios(now: now) {
            let page = presenter.page(s.runs, expanded: s.expanded, opened: s.opened, allRecent: s.allRecent)
            for c in page.live + page.recent {
                #expect(c.page != nil, "\(s.name) \(c.title)")
                #expect(c.page?.status.key.isEmpty == false)
            }
        }
    }
}
