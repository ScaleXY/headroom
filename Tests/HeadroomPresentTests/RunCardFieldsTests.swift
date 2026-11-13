import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

// The second pass's card fields: the map, counts, elapsed and ETA range, the question, the
// actions, the limit timeline, the receipt, opened rows, and the menu bar's counts.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let p = RunsPresenter(now: t0, calendar: utc, locale: Locale(identifier: "en_US"))
private let uuid = "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60"

private func leaf(_ id: String, _ state: TaskState, share: Double = 0, estimate: Double? = nil, importance: TaskImportance = .normal,
                  counted: Bool = true, wait: TaskWaitReason? = nil, waitNote: String? = nil, evidence: String? = nil, failure: String? = nil,
                  note: String? = nil, tokens: Int64 = 0, working: Double = 0, agents: Int = 0, retries: Int = 0) -> TaskNode {
    let prog = TaskProgress(done: state == .done ? 1 : 0, inFlight: 0, estimate: estimate ?? (state == .done ? 1 : 0))
    return TaskNode(id: id, title: id.capitalized, state: state, waitReason: wait, progress: prog, importance: importance, counted: counted,
                    note: note, waitNote: waitNote, evidence: evidence, failure: failure,
                    attempts: TaskAttemptsSummary(count: agents, retries: retries), tokens: tokens, startedAt: at(-30),
                    endedAt: state.isTerminal ? at(-5) : nil, lastActivityAt: at(-2), share: share, workingSeconds: working)
}

private func run(_ id: String = "r", state: TaskRunState = .running, wait: TaskWaitReason? = nil, stale: Bool = false, nodes: [TaskNode] = [],
                 updated: Double = -1, estimate: Double = 0.5, done: Double = 0.4, harness: String? = "claude-code", warning: String? = nil,
                 configure: (inout TaskRun) -> Void = { _ in }) -> TaskRun {
    var r = TaskRun(id: id, title: "Plan " + id, harness: harness, startedAt: at(-102), updatedAt: at(updated), state: state, waitReason: wait,
                    stale: stale, progress: TaskProgress(done: done, inFlight: 0.2, estimate: estimate), etaSeconds: 25 * 60, tokens: 296_000,
                    warning: warning, hasDeclaredTasks: true, nodes: nodes)
    configure(&r)
    return r
}

@Suite struct RunHonestNumberTests {
    @Test func theHeadlineIsTheEstimateRoundedDownAndNeverFullBeforeDone() {
        #expect(p.card(run(estimate: 0.579, done: 0.3)).headline == "57%")
        #expect(p.card(run(estimate: 1, done: 0.9)).headline == "99%")
        #expect(p.card(run(state: .done, estimate: 1, done: 1)).headline == "100%")
        // Done never reads lower than what's finished.
        #expect(p.card(run(estimate: 0.2, done: 0.3)).headline == "30%")
    }

    @Test func countsBesideThePercent() {
        let nodes = [leaf("a", .done), leaf("b", .done), leaf("c", .running), leaf("d", .planned),
                     leaf("opt", .failed, importance: .optional, counted: false)]
        #expect(p.card(run(nodes: nodes)).counts == "2 of 4 tasks · 1 running")
        #expect(p.card(run(nodes: [leaf("a", .done)])).counts == "1 of 1 task")
        // Finished: no "running".
        #expect(p.card(run(state: .done, nodes: nodes)).counts == "2 of 4 tasks")
        let mirrored = p.card(run(nodes: nodes) { $0.mirrored = true })
        #expect(mirrored.counts == "2 of 4 steps · 1 running" && mirrored.figures.first == RunWords.fromSessionPlan)
    }

    @Test func theMapIsTheCountedLeavesByShare() {
        let nodes = [leaf("plan", .planned, share: 0.2), leaf("run", .running, share: 0.3, estimate: 0.4, importance: .critical),
                     leaf("done", .done, share: 0.3), leaf("ask", .waiting, share: 0.1, estimate: 0.5, wait: .input),
                     leaf("broke", .failed, share: 0.1, importance: .critical),
                     leaf("helper", .done, share: 0, counted: false)]
        let segs = p.card(run(nodes: nodes)).segments
        // Closed first, then under way, then untouched; plan order within each.
        #expect(segs.map(\.title) == ["Done", "Broke", "Run", "Ask", "Plan"])
        #expect(abs(segs.reduce(0) { $0 + $1.weight } - 1) < 1e-9)
        #expect(segs[0].fill == 1 && segs[0].tone == .progress)
        #expect(segs[1].failed && segs[1].fill == 1 && segs[1].critical)
        #expect(segs[2].fill == 0.4 && segs[2].tone == .progress && segs[2].critical)
        #expect(segs[3].tone == .alert && !segs[3].failed)
        #expect(segs[4].fill == 0 && segs[4].tone == .quiet)
        // No shares from the fold, or too many to draw: the bar stands in.
        #expect(p.card(run(nodes: [leaf("a", .done), leaf("b", .running)])).segments.isEmpty)
        let many = (0..<(RunsPresenter.maxSegments + 1)).map { leaf("t\($0)", .planned, share: 1) }
        #expect(p.card(run(nodes: many)).segments.isEmpty)
        // A finished card shows its receipt, not the map.
        #expect(p.card(run(state: .done, nodes: nodes)).segments.isEmpty)
    }

    @Test func elapsedIsWorkingTimeWhileLive() {
        #expect(p.card(run { $0.time = TaskTimeSplit(working: 72 * 60, waitingInput: 600) }).elapsed == "1h 12m working")
        #expect(p.card(run()).elapsed == nil)
        #expect(p.card(run(state: .done, updated: 0)).elapsed == "1h 42m")
        #expect(RunsPresenter.duration(30) == "<1m" && RunsPresenter.duration(3 * 3600) == "3h" && RunsPresenter.duration(50 * 3600) == "2d 2h")
    }

    @Test func theForecastIsARange() {
        let ranged = p.card(run { $0.etaLowSeconds = 19 * 60; $0.etaHighSeconds = 34 * 60 })
        #expect(ranged.figures.contains("15–35m left"))
        let hours = p.card(run { $0.etaLowSeconds = 70 * 60; $0.etaHighSeconds = 2.4 * 3600 })
        #expect(hours.figures.contains("1–2h left"))
        let mixed = p.card(run { $0.etaLowSeconds = 40 * 60; $0.etaHighSeconds = 2 * 3600 })
        #expect(mixed.figures.contains("40m–2h left"))
        #expect(p.card(run()).figures.contains("about 25m left"))
    }
}

@Suite struct RunQuestionAndActionTests {
    @Test func theQuestionLeadsWhileTheRunNeedsYou() {
        let nodes = [leaf("migrate", .waiting, wait: .input, waitNote: "Drop the table?")]
        let asked = run(state: .waiting, wait: .input, nodes: nodes) {
            $0.question = TaskQuestion(text: "May I drop the unused audit table?", options: ["Drop it", "Keep it"], task: "migrate", askedAt: at(-4))
        }
        let q = p.card(asked).question
        #expect(q == RunQuestionModel(asker: "Migrate is asking", text: "May I drop the unused audit table?", options: ["Drop it", "Keep it"]))
        let orchestrator = run(state: .waiting, wait: .input) { $0.question = TaskQuestion(text: "Ship it?", askedAt: at(-1)) }
        #expect(p.card(orchestrator).question?.asker == "The agent is asking")
        // Without the harness's question, the waiting task's note stands in.
        #expect(p.card(run(state: .waiting, wait: .input, nodes: nodes)).question?.text == "Drop the table?")
        #expect(p.card(run(nodes: nodes)).question == nil)
    }

    @Test func actionsFollowWhatTheRunKnows() {
        #expect(p.card(run()).actions == RunActionSet(hide: true, abandon: true))
        #expect(p.card(run { $0.cwd = "/tmp/x" }).actions.openSession)
        #expect(p.card(run { $0.host = "com.apple.Terminal" }).actions.openSession)
        #expect(p.card(run(uuid)).actions.copyResume)
        #expect(p.card(run(uuid, harness: "codex")).actions.copyResume)
        #expect(!p.card(run(uuid, harness: "aider")).actions.copyResume)
        #expect(!p.card(run("not-a-session")).actions.copyResume)
        let done = p.card(run(state: .done)).actions
        #expect(done.hide && !done.abandon)
        #expect(!p.card(run { $0.abandoned = true }).actions.abandon)
    }
}

@Suite struct RunTimelineTests {
    func outlook(pause: Double, resume: Double, finish: Double) -> TaskLimitOutlook {
        TaskLimitOutlook(provider: .claude, pauseAt: at(pause), resumeAt: at(resume), finishAt: at(finish), tokensNeeded: 1_100_000,
                         roomTokens: 600_000, share: 0.62)
    }

    @Test func workingPausedWorkingDone() throws {
        let c = p.card(run(warning: "Claude 5-hour limit will likely run out first.") { $0.limitOutlook = outlook(pause: 25, resume: 75, finish: 100) })
        let tl = try #require(c.timeline)
        #expect(tl.spans.map(\.kind) == [.working, .paused, .working])
        #expect(tl.spans[0].end == 0.25 && tl.spans[1].start == 0.25 && tl.spans[1].end == 0.75 && tl.spans[2].end == 1)
        #expect(tl.ticks.map(\.label) == ["now", "window empty", "resets", "done"])
        #expect(tl.ticks.map(\.at) == [0, 0.25, 0.75, 1] && tl.ticks.map(\.strong) == [false, true, false, true])
        #expect(tl.ticks[1].time == "8:25 AM" && tl.ticks[3].time == "~9:40 AM")
        #expect(tl.note == "Using 62% of what Claude is spending now · needs about 1.1M more tokens, the window has room for 600K")
        // The timeline replaces the one-line warning.
        #expect(c.warning == nil)
    }

    @Test func noTimelineWithoutAPauseBeforeTheFinish() {
        let warn = "Claude 5-hour limit will likely run out first."
        #expect(p.card(run(warning: warn)).timeline == nil && p.card(run(warning: warn)).warning == warn)
        #expect(p.card(run(warning: warn) { $0.limitOutlook = outlook(pause: 90, resume: 120, finish: 60) }).timeline == nil)
        #expect(p.card(run(warning: warn) { $0.limitOutlook = TaskLimitOutlook(provider: .claude, share: 0.5) }).warning == warn)
        #expect(p.card(run(state: .done) { $0.limitOutlook = outlook(pause: 25, resume: 75, finish: 100) }).timeline == nil)
    }
}

@Suite struct RunReceiptTests {
    func finished() -> TaskRun {
        let nodes = [leaf("a", .done), leaf("b", .done, retries: 1), leaf("c", .done), leaf("d", .done),
                     leaf("bench", .failed, importance: .optional, counted: false)]
        return run(state: .done, nodes: nodes, updated: 0) {
            $0.scopeChanges = 2
            $0.time = TaskTimeSplit(working: 70 * 60, waitingInput: 22 * 60, waitingLimit: 10 * 60)
            $0.tokensByModel = ["claude-sonnet-5-5": 296_000, "made-up-model": 1000]
        }
    }

    @Test func finishedCardsCarryAReceipt() throws {
        let rc = try #require(p.card(finished()).receipt)
        #expect(rc.duration == "1h 42m" && rc.tokens == "296K" && rc.cost == nil)
        #expect(rc.tasks == "4 of 5" && rc.tasksNote == "tasks · 1 optional failed")
        #expect(rc.time.waitingInput == 22 * 60)
        #expect(rc.footnote == "Plan changed 2 times after it started · 1 retry")
        #expect(p.card(run()).receipt == nil)
    }

    @Test func theCostIsPricedFromTheModels() throws {
        let engine = PricingEngine(table: try PriceTable.bundled())
        let priced = RunsPresenter(now: t0, calendar: utc, locale: Locale(identifier: "en_US"), pricing: engine)
        let cost = try #require(priced.card(finished()).receipt?.cost)
        #expect(cost.hasPrefix("about $"))
        // Unpriced models alone give no cost.
        #expect(RunsPresenter.cost(["made-up-model": 1000], pricing: engine) == nil)
    }

    @Test func abandonedRunsSitWithTheFinishedOnes() {
        let r = run("gone", state: .stopped, nodes: [leaf("a", .done), leaf("b", .cancelled, counted: false), leaf("c", .planned)]) { $0.abandoned = true }
        let page = p.page([r])
        #expect(page.live.isEmpty && page.recent.map(\.id) == ["gone"])
        let c = page.recent[0]
        #expect(c.stateText == "Abandoned" && c.glyph == .skipped && c.tone == .quiet && !c.live)
        #expect(c.receipt?.tasksNote == "tasks · 1 cancelled · 1 left open")
        #expect(p.menuBar([r]) == nil)
    }
}

@Suite struct RunRowDetailTests {
    @Test func rowsOpenToTheirDetails() throws {
        let nodes = [leaf("snap", .done, evidence: "Snapshot taken, restore tested", tokens: 96_000, working: 11 * 60, agents: 1),
                     leaf("bare", .done, tokens: 5000),
                     leaf("broke", .failed, failure: "The certificate expired", note: "Tried twice")]
        let r = run("x", nodes: nodes)
        let closed = p.rows(r, expanded: true).rows
        #expect(closed.first { $0.id == "snap" }?.opens == true && closed.first { $0.id == "snap" }?.details == nil)
        // Tokens alone are already on the row: nothing to open.
        #expect(closed.first { $0.id == "bare" }?.opens == false)
        let opened = p.rows(r, expanded: true, opened: [RunsPresenter.rowKey(run: "x", row: "snap"), RunsPresenter.rowKey(run: "x", row: "broke")]).rows
        let snap = try #require(opened.first { $0.id == "snap" }?.details)
        #expect(snap == [RunDetailLine(label: "Evidence", value: "Snapshot taken, restore tested"),
                         RunDetailLine(label: "Took", value: "11m · 1 agent · no retries"), RunDetailLine(label: "Tokens", value: "96K")])
        let broke = try #require(opened.first { $0.id == "broke" }?.details)
        #expect(broke.map(\.label) == ["Failed because", "Note"])
        // Another run's row with the same id stays closed.
        #expect(p.rows(r, expanded: true, opened: [RunsPresenter.rowKey(run: "y", row: "snap")]).rows.allSatisfy { $0.details == nil })
    }

    @Test func andNMoreExpandsEvenWithNothingFinished() {
        let nodes = (0..<14).map { leaf("t\($0)", .running) }
        let closed = p.card(run("m", nodes: nodes))
        #expect(closed.expandable && !closed.expanded && closed.rows.last?.kind == .more(4))
        let open = p.card(run("m", nodes: nodes), expanded: true)
        #expect(open.expanded && open.rows.count == 14)
    }
}

@Suite struct RunPageSecondPassTests {
    @Test func hiddenRunsNeverShow() {
        let hidden = run("h") { $0.hidden = true }
        #expect(p.page([hidden, run("v")]).live.map(\.id) == ["v"])
        #expect(p.menuBar([hidden]) == nil)
    }

    @Test func aRunWaitingOnYouStaysPastADay() {
        let old = run("old", state: .waiting, wait: .input, updated: -30 * 60)
        #expect(p.page([old]).live.map(\.id) == ["old"])
        #expect(p.page([run("stuck", updated: -30 * 60)]).isEmpty)
    }

    @Test func moreFinishedRunsOpenTheList() {
        let many = (0..<6).map { run("d\($0)", state: .done, updated: -Double($0 + 1)) }
        let all = p.page(many, allRecent: true)
        #expect(all.recent.count == 6 && all.moreRecent == 0 && all.allRecent)
        #expect(!p.page(many).allRecent && p.page(many).moreRecent == 2)
    }

    @Test func oneWordPerState() {
        #expect(p.stateText(run(state: .stopped)) == RunWords.stopped)
        #expect(p.stateText(run(state: .partial)) == RunWords.partial)
        #expect(p.stateText(run(state: .waiting, wait: .input)) == RunWords.needsInput)
        #expect(p.stateText(run(stale: true, updated: -18)) == RunWords.quiet("18m"))
        #expect(p.stateText(run { $0.abandoned = true }) == RunWords.abandoned)
        // Rose is for "needs you"; a failure is .alert with the failed glyph, which surfaces colour apart.
        let failed = p.card(run(state: .failed))
        #expect(failed.glyph == .failed && failed.tone == .alert)
    }
}

@Suite struct RunMenuBarSecondPassTests {
    @Test func severalRunsShowACount() throws {
        let m = try #require(p.menuBar([run("a"), run("b"), run("c")]))
        #expect(m.text == "50%" && m.liveCount == 3 && m.needsInputCount == 0 && !m.quiet)
        #expect(m.spoken == "Plan a: 50% done. 3 runs going.")
    }

    @Test func twoAskingSaySo() throws {
        let m = try #require(p.menuBar([run("a", state: .waiting, wait: .input), run("b", state: .waiting, wait: .input), run("c")]))
        #expect(m.text == "2 need you" && m.needsInput && m.needsInputCount == 2)
        #expect(m.spoken.hasSuffix("2 runs need your input."))
    }

    @Test func aQuietLeadShowsQuietNotAStalePercent() throws {
        let m = try #require(p.menuBar([run("q", stale: true, updated: -18)]))
        #expect(m.quiet && m.text == "quiet 18m" && m.spoken == "Plan q: Quiet for 18m.")
    }
}

@Suite struct RecentRunsTests {
    func record(_ id: String, endedHoursAgo: Double, state: TaskRunState = .done, hidden: Bool = false) -> RunRecord {
        RunRecord(id: id, title: "Run " + id, startedAt: at(-endedHoursAgo * 60 - 42), endedAt: at(-endedHoursAgo * 60), state: state,
                  hidden: hidden, tokens: 100_000, tokensByModel: ["claude-sonnet-5-5": 100_000])
    }

    @Test func newestFirstWithWhenHowLongAndCost() throws {
        let engine = PricingEngine(table: try PriceTable.bundled())
        let rp = RecentRunsPresenter(now: t0, calendar: utc, locale: Locale(identifier: "en_US"), pricing: engine)
        let m = try #require(rp.model([record("old", endedHoursAgo: 30), record("new", endedHoursAgo: 1, state: .failed),
                                       record("gone", endedHoursAgo: 2, hidden: true)]))
        #expect(m.rows.map(\.id) == ["new", "old"])
        #expect(m.rows[0].when == "today 7 AM" && m.rows[1].when == "yesterday 2 AM")
        #expect(m.rows[0].duration == "42m" && m.rows[0].glyph == .failed && m.rows[0].outcome == "Failed")
        #expect(m.rows[0].cost?.hasPrefix("$") == true && m.summary.hasPrefix("2 runs · 1h 24m · $"))
        #expect(rp.model([]) == nil && rp.model([record("h", endedHoursAgo: 1, hidden: true)]) == nil)
    }

    @Test func aRecordKeepsTheReceiptsFigures() {
        let r = run("x", state: .partial, nodes: [leaf("a", .done), leaf("b", .failed)], updated: -10) { $0.tokensByModel = ["m": 5] }
        let rec = RunRecord(r)
        #expect(rec.title == "Plan x" && rec.endedAt == at(-10) && rec.tasks == "1 of 2" && rec.tasksNote == "tasks · 1 failed")
        #expect(rec.tokensByModel == ["m": 5] && rec.state == .partial)
    }
}

// The Runs card in the Pace card's grammar: a hero (number, raised unit, side figure with a
// clock caption) and a verdict (a sentence under the badge, the tokens beside it).
@Suite struct RunHeroAndVerdictTests {
    @Test func aDeclaredRunsHeroIsItsPercentAndTimeLeft() throws {
        let nodes = [leaf("a", .done), leaf("b", .running), leaf("c", .planned)]
        let hero = try #require(p.card(run(nodes: nodes) { $0.etaLowSeconds = 20 * 60; $0.etaHighSeconds = 30 * 60 }).hero)
        #expect(hero.number == "50" && hero.unit == "%" && hero.label == "1 of 3 tasks · 1 running")
        #expect(hero.side == "~25m" && hero.hourglass)
        // A clock time, as Pace's renewal is.
        #expect(hero.sideCaption == "done 1:00–1:10 AM" || hero.sideCaption?.hasPrefix("done ") == true)
        #expect(hero.fraction == 0.5)
    }

    @Test func aPauseAtTheLimitCountsInTheTimeLeft() throws {
        let hero = try #require(p.card(run {
            $0.limitOutlook = TaskLimitOutlook(provider: .claude, pauseAt: at(30), resumeAt: at(80), finishAt: at(105))
        }).hero)
        #expect(hero.side == "~2h" && hero.sideCaption?.hasPrefix("done ~") == true)
    }

    @Test func agentsCountedWithoutAPlanGetNoForecast() throws {
        let nodes = [leaf("a", .done), leaf("b", .running), leaf("c", .done)]
        let hero = try #require(p.card(run(nodes: nodes) { $0.hasDeclaredTasks = false; $0.time = TaskTimeSplit(working: 40 * 60) }).hero)
        #expect(hero.number == "2" && hero.unit == "/3" && hero.label == "agents finished · 1 running")
        #expect(hero.side == "40m" && hero.sideCaption == "working" && !hero.hourglass)
    }

    @Test func theVerdictSaysWhatsHappening() {
        let nodes = [leaf("routes", .running), leaf("tests", .running), leaf("docs", .planned)]
        let v = p.card(run(nodes: nodes)).verdict
        #expect(v?.primary == "Working on Routes and 1 more." && v?.figure == "296K tokens")
        // A run that needs you leads with the question instead.
        #expect(p.card(run(state: .waiting, wait: .input, nodes: nodes)).verdict?.primary == nil)
        // Stopped: what's left, not the state again.
        #expect(p.card(run(state: .stopped, nodes: nodes)).verdict?.primary?.hasPrefix("3 tasks left.") == true)
        // Done with optional work failed says so, so "4 of 5" beside it adds up.
        let done = [leaf("a", .done), leaf("b", .done), leaf("bench", .failed, importance: .optional, counted: false)]
        #expect(p.card(run(state: .done, nodes: done)).verdict?.primary == "Everything that counts is done; Bench, which was optional, failed.")
    }

    @Test func theRowsAreNamedForWhatTheyAre() {
        #expect(p.card(run(nodes: [leaf("a", .running)])).rowsTitle == "Tasks")
        #expect(p.card(run(nodes: [leaf("a", .running)]) { $0.mirrored = true }).rowsTitle == "Steps")
        #expect(p.card(run(nodes: [leaf("a", .running)]) { $0.hasDeclaredTasks = false }).rowsTitle == "Agents")
    }
}
