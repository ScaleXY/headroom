import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let presenter: RunsPresenter = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return RunsPresenter(now: now, calendar: cal, locale: Locale(identifier: "en_US"))
}()

/// A run as the phone receives it: what `RunSummaryBuilder` keeps, names or not.
@MainActor private func digest(_ r: TaskRun, names: Bool, mac: String = "MacBook Pro", lastSeen: Date? = nil) -> RunDigest {
    let picked = presenter.digestRows(r, cap: 30)
    return RunDigest(id: "mac:" + r.id, mac: mac, harness: r.harness, state: r.state, waitReason: r.waitReason, stale: r.stale,
                     progress: r.progress, mustHaves: r.mustHaves, etaSeconds: r.etaSeconds, tokens: r.tokens, warning: r.warning,
                     hasDeclaredTasks: r.hasDeclaredTasks, startedAt: r.startedAt, updatedAt: r.updatedAt, counts: RunCounts.of(r),
                     title: names ? r.bestTitle : nil, rows: names ? picked.rows : nil, moreRows: names ? picked.more : 0,
                     finishedRows: names ? picked.finished : 0, finishedEarlier: r.finishedEarlier ?? 0, lastSeen: lastSeen)
    .with { $0.left = r.left; $0.turnSeconds = r.yourTurn ? r.turnSeconds : nil }
}

extension RunDigest {
    func with(_ change: (inout RunDigest) -> Void) -> RunDigest { var d = self; change(&d); return d }
}

@MainActor @Suite struct SyncedRunsTests {
    static func runs() -> [TaskRun] { [Demo.declaredRun(now: now), Demo.observedRun(now: now), Demo.inputRun(now: now), Demo.limitRun(now: now),
                       Demo.finishedRun(now: now), Demo.failedRun(now: now), Demo.largeRun(now: now)] }

    @Test(arguments: 0..<7)
    func theCardSaysWhatTheMacSays(_ i: Int) {
        let r = Self.runs()[i]
        let mac = presenter.card(r)
        for names in [true, false] {
            let phone = presenter.card(digest(r, names: names))
            #expect(phone.stateText == mac.stateText)
            // The Mac's rules: a plan's headline is its best guess (the estimate), rounded down and
            // never 100% before it's done, with no "by tokens" line beside it; agents otherwise.
            if r.hasDeclaredTasks {
                let pct = Int((r.progress.estimate * 100 + 1e-9).rounded(.down))
                #expect(phone.headline == "\(r.state == .done ? pct : min(pct, 99))%")
            } else {
                #expect(phone.headline == mac.headline)
            }
            #expect(phone.estimate == nil)
            // Time left is worded as a range now; everything else in the line is the Mac's.
            #expect(phone.figures.filter { !$0.hasSuffix(" left") } == mac.figures.filter { !$0.hasSuffix(" left") })
            #expect(phone.warning == mac.warning)
            #expect(phone.bar == mac.bar)
            #expect(phone.glyph == mac.glyph && phone.tone == mac.tone)
            #expect(phone.needsInput == mac.needsInput && phone.live == mac.live && phone.provider == mac.provider)
        }
    }

    @Test(arguments: 0..<7)
    func withNamesTheRowsAreTheMacsWithoutTheirNotes(_ i: Int) {
        let r = Self.runs()[i]
        let mac = presenter.card(r).rows
        let phone = presenter.card(digest(r, names: true)).rows
        #expect(phone.map(\.title) == mac.map(\.title))
        #expect(phone.map(\.glyph) == mac.map(\.glyph))
        #expect(phone.map(\.depth) == mac.map(\.depth))
        #expect(phone.map(\.steps) == mac.map(\.steps))
        #expect(phone.map(\.marker) == mac.map(\.marker))
        let notes = r.nodes.flatMap { [$0.note, $0.waitNote, $0.failure, $0.evidence].compactMap { $0 } }
        for detail in phone.compactMap(\.detail) { #expect(!notes.contains(detail)) }
    }

    @Test func withNamesTheTitleIsTheAgentsAndTheSubtitleNamesTheMac() {
        let c = presenter.card(digest(Demo.declaredRun(now: now), names: true))
        #expect(c.title == "Move checkout to the new payments API")
        #expect(c.subtitle == "MacBook Pro · Claude Code · updated 1m ago")
        // Not declared: the session's own title; never the project or repo, and the Mac stays in the subtitle.
        let observed = presenter.card(digest(Demo.observedRun(now: now), names: true))
        #expect(observed.title == "Audit the design tokens for contrast")
        #expect(observed.subtitle.hasPrefix("MacBook Pro · "))
        #expect(!observed.subtitle.contains("design-system"))
        // No title at all: what ran it.
        var untitled = Demo.observedRun(now: now)
        untitled.sessionTitle = nil
        #expect(presenter.card(digest(untitled, names: true)).title == "Claude Code run")
    }

    @Test func withoutNamesTheTitleIsWhatRanItAndTheRowsOneLineOfCounts() {
        let c = presenter.card(digest(Demo.declaredRun(now: now), names: false))
        #expect(c.title == "Claude Code run")
        #expect(c.subtitle == "MacBook Pro · updated 1m ago")
        #expect(c.rows.count == 1)
        #expect(c.rows[0].kind == .counts)
        #expect(c.rows[0].title == "3 running · 5 done · 2 planned")
        let input = presenter.card(digest(Demo.inputRun(now: now), names: false))
        #expect(input.rows.map(\.title) == ["1 needs input · 1 done · 1 planned"])
        #expect(input.rows[0].glyph == .needsInput)
    }

    @Test func countsReadInTheBriefsOrder() {
        #expect(RunCounts(running: 3, needsInput: 1, done: 12).line == "3 running · 1 needs input · 12 done")
        #expect(RunCounts(running: 1, needsInput: 1, waiting: 2, failed: 1, done: 4, planned: 3).line
            == "1 running · 1 needs input · 2 waiting · 1 failed · 4 done · 3 planned")
    }

    @Test func observedCountsIncludeCompactedAgents() {
        let r = Demo.largeRun(now: now)
        let counts = RunCounts.of(r)
        let mac = presenter.agentCounts(r)
        #expect(counts.finished == mac.finished && counts.total == mac.total)
    }

    @Test func runsWithTheSameTitleSayWhenTheyStarted() {
        let a = digest(Demo.declaredRun(now: now), names: false), b = digest(Demo.limitRun(now: now), names: false)
        let page = presenter.page([b, a])
        #expect(page.live.count == 2 && page.live.allSatisfy { $0.title.hasPrefix("Claude Code run · ") })
    }

    @Test func aRunOnAQuietMacReadsLastSeen() {
        let d = digest(Demo.inputRun(now: now), names: true, lastSeen: now.addingTimeInterval(-2 * 3600))
        let c = presenter.card(d)
        #expect(c.stateText == RunWords.macLastSeen("2h"))
        #expect(c.stateText == "Mac last seen 2h ago")
        #expect(!c.needsInput)
        #expect(c.glyph == .stopped && c.tone == .quiet)
        #expect(!d.isLive)
        #expect(c.question == nil && c.elapsed == nil)
    }

    @Test func alertsUseTheSameTitle() {
        let named = digest(Demo.inputRun(now: now), names: true)
        #expect(presenter.needsInputAlert(named) == RunAlertCopy(title: "Database upgrade needs your input", body: "Answer it on MacBook Pro"))
        let unnamed = digest(Demo.failedRun(now: now), names: false)
        #expect(presenter.finishedAlert(unnamed).title == "Claude Code run failed")
        #expect(presenter.finishedAlert(unnamed).body == "On MacBook Pro. 50% done · must-haves 0 of 1 · 101K tokens")
        #expect(presenter.turnEndedAlert(digest(Demo.yourTurnRun(now: now), names: true)).title == "Tidy the settings module finished its turn after 24m")
    }

    // MARK: Second pass

    @Test func aSyncedQuestionLeadsTheCardAndTheAlert() {
        var d = digest(Demo.inputRun(now: now), names: true)
        // Without the wording: where to answer.
        #expect(presenter.card(d).question == RunQuestionModel(asker: "", text: "Answer it on MacBook Pro"))
        d.question = RunDigest.Question(text: "May I drop the audit table?", options: ["Drop it", "Keep it"], asker: "Switch the queries over")
        let q = presenter.card(d).question
        #expect(q == RunQuestionModel(asker: "Switch the queries over is asking", text: "May I drop the audit table?", options: ["Drop it", "Keep it"]))
        #expect(presenter.needsInputAlert(d).body == "On MacBook Pro: May I drop the audit table?")
        // Only while it needs you, and never from a quiet Mac.
        d.lastSeen = now.addingTimeInterval(-3600)
        #expect(presenter.card(d).question == nil)
    }

    @Test func theTaskMapCountsAndElapsedComeFromTheSync() {
        var d = digest(Demo.declaredRun(now: now), names: false)
        d.segments = [RunDigest.Segment(weight: 0.5, fill: 1, state: .done, importance: .critical),
                      RunDigest.Segment(weight: 0.3, fill: 0.4, state: .running),
                      RunDigest.Segment(weight: 0.2, fill: 0, state: .waiting, waitReason: .input)]
        d.workingSeconds = 72 * 60
        let c = presenter.card(d)
        #expect(c.segments.map(\.tone) == [.neutral, .progress, .alert])
        #expect(c.segments.map(\.critical) == [true, false, false])
        #expect(c.counts == "5 of 10 tasks · 3 running")
        #expect(c.elapsed == "1h 12m working")
        // A plan read off the harness counts steps.
        d.mirrored = true
        #expect(presenter.card(d).counts == "5 of 10 steps · 3 running")
        // Finished: how long it worked (the time open, without a split).
        let done = presenter.card(digest(Demo.finishedRun(now: now), names: false))
        #expect(done.elapsed == "1h 42m working")
        #expect(done.counts == "4 of 4 tasks")
    }

    @Test func theEstimateIsARangeOfClockTimesNotSecondsFromTheLastEvent() {
        var d = digest(Demo.declaredRun(now: now), names: false)
        d.etaSeconds = 26 * 60
        // The finish the Mac synced, as time from now: no longer anchored to the last event.
        d.finishAt = now.addingTimeInterval(26 * 60)
        #expect(presenter.card(d).figures.contains("about 26m left"))
        d.finishLow = now.addingTimeInterval(20 * 60); d.finishHigh = now.addingTimeInterval(35 * 60)
        #expect(presenter.card(d).figures.contains("20–35m left"))
        d.finishLow = now.addingTimeInterval(40 * 60); d.finishHigh = now.addingTimeInterval(90 * 60)
        #expect(presenter.card(d).figures.contains("40m–2h left"))
        // A finish that's passed says nothing.
        d.finishLow = nil; d.finishHigh = nil; d.finishAt = now.addingTimeInterval(-60)
        #expect(!presenter.card(d).figures.contains { $0.hasSuffix("left") })
    }

    @Test func theLimitTimelineRunsFromNowToTheFinish() throws {
        var d = digest(Demo.declaredRun(now: now), names: false)
        d.limit = TaskLimitOutlook(provider: .claude, pauseAt: now.addingTimeInterval(30 * 60), resumeAt: now.addingTimeInterval(80 * 60),
                                   finishAt: now.addingTimeInterval(105 * 60), tokensNeeded: 1_100_000, roomTokens: 600_000, share: 0.62)
        let t = try #require(presenter.card(d).timeline)
        #expect(t.spans.map(\.kind) == [.working, .paused, .working])
        #expect(t.ticks.map(\.label) == ["now", "window empty", "resets", "done"])
        #expect(t.ticks.map(\.time) == ["8 AM", "8:30 AM", "9:20 AM", "~9:45 AM"])
        #expect(abs(t.spans[0].end - 30.0 / 105) < 1e-9)
        #expect(t.note == "Using 62% of what Claude is spending now · needs about 1.1M more tokens, the window has room for 600K")
        // No pause in sight: no timeline.
        d.limit?.pauseAt = nil
        #expect(presenter.card(d).timeline == nil)
    }

    @Test func aFinishedRunGetsAReceipt() throws {
        var d = digest(Demo.finishedRun(now: now), names: false)
        #expect(presenter.card(d).receipt == nil)
        d.receipt = RunDigest.Receipt(seconds: 102 * 60, tokensByModel: ["gpt-6-sol": 296_000],
                                      time: TaskTimeSplit(working: 70 * 60, waitingInput: 22 * 60, waitingLimit: 10 * 60), optionalFailed: 1,
                                      scopeChanges: 2, retries: 1)
        d.cost = 4.1
        // A failed optional task doesn't count toward the run, so the Mac leaves it out of the counts.
        d.counts = RunCounts(done: 4)
        let r = try #require(presenter.card(d).receipt)
        #expect(r.duration == "1h 10m" && r.open == "1h 42m")
        #expect(r.tokens == "296K")
        #expect(r.cost == "about $4.10")
        #expect(r.tasks == "4 of 5" && r.tasksNote == "tasks · 1 optional failed")
        #expect(r.footnote == "Plan changed 2 times after it started · 1 retry")
        #expect(r.time.total == 102 * 60)
    }

    @Test func tappingACardListsEveryRowItsMacSynced() {
        let d = digest(Demo.largeRun(now: now), names: true)
        let closed = presenter.card(d)
        #expect(closed.expandable && !closed.expanded)
        #expect(closed.rows.filter { $0.kind == .task }.count == RunsPresenter.rowCap)
        #expect(closed.rows.contains { if case .more = $0.kind { true } else { false } })
        let open = presenter.page([d], expanded: [d.id]).live[0]
        #expect(open.expanded)
        #expect(open.rows.filter { $0.kind == .task }.count == d.rows?.count)
        // A short plan has nothing more to show.
        #expect(!presenter.card(digest(Demo.inputRun(now: now), names: true)).expandable)
    }

    @Test func theHeadlineIsTheEstimateAndNever100BeforeItsDone() {
        var d = digest(Demo.declaredRun(now: now), names: false)
        d.progress = TaskProgress(done: 0.4, inFlight: 0.2, estimate: 0.578)
        #expect(presenter.card(d).headline == "57%")
        #expect(presenter.shortFigure(d) == "57%")
        d.progress = TaskProgress(done: 0.98, inFlight: 0.02, estimate: 1)
        #expect(presenter.card(d).headline == "99%")
        d.state = .done
        #expect(presenter.card(d).headline == "100%")
        // A plan read off the harness reads the same way.
        var mirrored = digest(Demo.observedRun(now: now), names: false)
        mirrored.mirrored = true
        mirrored.progress = TaskProgress(done: 0.5, inFlight: 0, estimate: 0.5)
        #expect(presenter.card(mirrored).headline == "50%" && presenter.card(mirrored).declared)
    }

    @Test func oneStepOrTaskIsSingularAsOnTheMac() throws {
        func one(mirrored: Bool, state: TaskRunState, counts: RunCounts) -> RunDigest {
            var d = RunDigest(id: "mac:1", mac: "MacBook Pro", state: state, hasDeclaredTasks: true, startedAt: now.addingTimeInterval(-600),
                              updatedAt: now.addingTimeInterval(-60), counts: counts, title: "One thing")
            d.mirrored = mirrored
            d.receipt = state.isTerminal ? RunDigest.Receipt(seconds: 540) : nil
            return d
        }
        let step = presenter.card(one(mirrored: true, state: .done, counts: RunCounts(done: 1)))
        #expect(step.counts == "1 of 1 step")
        #expect(step.verdict?.primary == "Done.")
        #expect(try #require(step.receipt).tasksNote == "step")
        #expect(presenter.card(one(mirrored: false, state: .running, counts: RunCounts(running: 1))).counts == "0 of 1 task · 1 running")
        #expect(presenter.card(one(mirrored: true, state: .done, counts: RunCounts(done: 3))).verdict?.primary == "All 3 steps done.")
        // Failed with no failed task counted: how it ended, not "0 tasks failed."
        #expect(presenter.card(one(mirrored: false, state: .partial, counts: RunCounts(done: 2))).verdict?.primary == RunWords.partial + ".")
    }

    @Test func aReceiptNamesFailedAndOptionalFailedApart() throws {
        var d = RunDigest(id: "mac:2", mac: "MacBook Pro", state: .partial, hasDeclaredTasks: true, startedAt: now.addingTimeInterval(-600),
                          updatedAt: now.addingTimeInterval(-60), counts: RunCounts(failed: 1, done: 2), title: "Mixed")
        d.receipt = RunDigest.Receipt(seconds: 540, optionalFailed: 1)
        let receipt = try #require(presenter.card(d).receipt)
        #expect(receipt.tasks == "2 of 4")
        #expect(receipt.tasksNote == "tasks · 1 failed · 1 optional failed")
    }

    @Test func aClosedRunSaysSo() {
        var d = digest(Demo.yourTurnRun(now: now), names: true)
        d.abandoned = true
        #expect(presenter.card(d).stateText == RunWords.closed)
        #expect(!d.yourTurn && d.isSettled)
    }

    // MARK: The run's own page

    @Test func withNamesAFlatRunsPageIsTheMacs() throws {
        for r in [Demo.inputRun(now: now), Demo.observedRun(now: now)] {
            let mac = presenter.pageModel(r)
            let phone = try #require(presenter.card(digest(r, names: true)).page)
            #expect(phone.status == mac.status, "\(r.id)")
            #expect(phone.groups.map(\.title) == mac.groups.map(\.title), "\(r.id)")
            #expect(phone.groups.flatMap(\.rows).map(\.title) == mac.groups.flatMap(\.rows).map(\.title), "\(r.id)")
            #expect(phone.openCount == mac.openCount && phone.doneCount == mac.doneCount, "\(r.id)")
            // Only the open rows sync, so the finished ones are counted, not listed.
            #expect(!phone.listsDone && mac.listsDone)
        }
    }

    /// The Mac's card rolls work deeper than two levels into its ancestor ("Refunds 1/3"), and
    /// those are the rows that sync: the phone lists them under the same parents.
    @Test func aNestedPlanSyncsRolledUp() throws {
        let r = Demo.declaredRun(now: now)
        let mac = presenter.pageModel(r)
        let card = presenter.card(digest(r, names: true))
        let phone = try #require(card.page)
        #expect(phone.status.key == mac.status.key)
        #expect(phone.groups.map(\.title) == ["Port the checkout endpoints › Rewrite the routes", "Other"])
        let open = card.rows.filter { $0.kind == .task && $0.glyph != .done }.map(\.title)
        // The parents head the groups; the rows under them are the leaves.
        #expect(Set(phone.groups.flatMap(\.rows).map(\.title)) == Set(open).subtracting(["Port the checkout endpoints", "Rewrite the routes"]))
        #expect(phone.groups.flatMap(\.rows).first { $0.title == "Refunds" }?.steps == "1/3")
    }

    @Test func syncedTaskTimesDrawLanes() throws {
        let r = Demo.declaredRun(now: now)
        let page = try #require(presenter.card(digest(r, names: true)).page)
        let lanes = try #require(page.lanes)
        #expect(lanes.lanes.map(\.title) == page.groups.flatMap(\.rows).map(\.title))
        #expect(lanes.now > 0 && lanes.now < 1)
        let running = try #require(lanes.lanes.first { $0.title == "Cover checkout end to end" })
        #expect(running.mustHave && running.bars.contains { $0.kind == .running } && running.bars.contains { $0.kind == .forecast })
        #expect(lanes.lanes.allSatisfy { $0.bars.allSatisfy { $0.start >= 0 && $0.end <= 1 && $0.end >= $0.start } })
        // An older Mac sends no times: no lanes, and the page reads as a Briefing.
        var old = digest(r, names: true)
        old.rows = old.rows?.map { var row = $0; row.startedAt = nil; row.endedAt = nil; row.lastActivityAt = nil; row.estimate = nil; return row }
        #expect(presenter.card(old).page?.lanes == nil)
    }

    @Test func withoutNamesThePageHasNoTasksOrLanes() throws {
        for r in Self.runs() {
            let page = try #require(presenter.card(digest(r, names: false)).page)
            #expect(page.groups.isEmpty && page.lanes == nil && page.openCount == 0, "\(r.id)")
            #expect(!page.status.key.isEmpty)
        }
        // Running agents are still counted.
        let observed = try #require(presenter.card(digest(Demo.observedRun(now: now), names: false)).page)
        #expect(observed.status.key == presenter.pageModel(Demo.observedRun(now: now)).status.key)
    }

    @Test func aRunFromAMacThatWentQuietSaysSoAndDrawsNoLanes() throws {
        let page = try #require(presenter.card(digest(Demo.declaredRun(now: now), names: true, lastSeen: now.addingTimeInterval(-3600))).page)
        #expect(page.status.key.hasPrefix("Mac last seen"))
        #expect(page.lanes == nil)
    }
}
