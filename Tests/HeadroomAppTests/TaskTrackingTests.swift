import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit

/// A Headroom home in a temporary folder.
final class TaskHome: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tasks-\(UUID().uuidString)", isDirectory: true)
    let t0 = Date().addingTimeInterval(-3600)
    deinit { try? FileManager.default.removeItem(at: url) }

    func add(_ run: String, _ s: TimeInterval, _ op: TaskEvent.Op, stream: TaskJournal.Stream = .journal, source: TaskSource = .agent) throws {
        try TaskJournal.append([TaskEvent(at: t0.addingTimeInterval(s), run: run, source: source, op: op)], stream: stream, home: url)
    }

    func feed() -> TasksFeed? { TasksFile.read(from: TasksFile.url(home: url)) }
}

@Suite struct TaskFeedWriterTests {
    @Test func writesOnlyWhenTheContentChanges() async throws {
        let h = TaskHome()
        try h.add("r1", 0, .add(.init(id: "a")))
        try h.add("r1", 1, .done(task: "a", evidence: nil))
        let writer = TaskFeedWriter(home: h.url)
        var r = await writer.refresh(hidden: [], providers: [])
        #expect(r.wrote && r.runs.map(\.id) == ["r1"] && h.feed()?.runs.first?.state == .done)
        let folds = await writer.folds
        // Nothing changed but the clock: no write, and the finished run isn't folded again.
        r = await writer.refresh(hidden: [], providers: [])
        let after = await writer.folds
        #expect(!r.wrote && after == folds)
        // A fresh writer (an app restart) compares with what's on disk, apart from its PID.
        let same = TaskFeedWriter(home: h.url, pid: h.feed()!.writerPID)
        let again = await same.refresh(hidden: [], providers: [])
        #expect(!again.wrote)
        try h.add("r1", 5, .add(.init(id: "b")))
        r = await writer.refresh(hidden: [], providers: [])
        #expect(r.wrote && h.feed()?.runs.first?.nodes.count == 2)
    }

    @Test func boundChildrenAreHidden() async throws {
        let h = TaskHome()
        try h.add("parent", 0, .attempt(.init(key: "delegate:t1", kind: .delegate, title: "Retry queue")), stream: .observed, source: .harness)
        try h.add("child", 0, .attempt(.init(key: "agent:x", kind: .agent)), stream: .observed, source: .harness)
        let r = await TaskFeedWriter(home: h.url).refresh(hidden: ["child"], providers: [])
        #expect(r.runs.map(\.id) == ["parent"] && h.feed()?.runs.map(\.id) == ["parent"])
    }

    @Test func eventFilesAWeekOldArePruned() async throws {
        let h = TaskHome()
        try h.add("old", 0, .add(.init(id: "a")))
        try h.add("old", 0, .attempt(.init(key: "agent:a")), stream: .observed, source: .harness)
        try h.add("new", 0, .add(.init(id: "a")))
        let old = Date().addingTimeInterval(-8 * 86400)
        for s in TaskJournal.Stream.allCases {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: TaskJournal.url(run: "old", stream: s, home: h.url).path)
        }
        let r = await TaskFeedWriter(home: h.url).refresh(hidden: [], providers: [])
        #expect(r.runs.map(\.id) == ["new"])
        #expect(TaskJournal.runs(home: h.url) == ["new"])
    }

    @Test func aBlockedProviderShowsInTheFeed() async throws {
        let h = TaskHome()
        try h.add("r1", 0, .meta(title: "Build", project: "demo", harness: "claude-code"))
        try h.add("r1", 0, .add(.init(id: "a")))
        try h.add("r1", 1, .start(task: "a"))
        let blocked = ProviderSnapshot(id: .claude, blocked: BlockedSnapshot(by: "session", detail: nil, until: Date().addingTimeInterval(3600)))
        let r = await TaskFeedWriter(home: h.url).refresh(hidden: [], providers: [blocked])
        #expect(r.runs.first?.waitReason == .limit && h.feed()?.runs.first?.warning?.hasPrefix("Claude 5-hour limit reached") == true)
    }
}

@MainActor @Suite struct TaskAlertTests {
    let now = Date()

    func run(_ state: TaskRunState, wait: TaskWaitReason? = nil, stale: Bool = false, nodes: [TaskNode] = [], updated: TimeInterval = -60) -> TaskRun {
        TaskRun(id: "r1", title: "r1", project: "demo", startedAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(updated),
                state: state, waitReason: wait, stale: stale, nodes: nodes)
    }

    func settings() -> AppSettings {
        let suite = "headroom-tests-\(UUID().uuidString)"
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func eachEpisodeNotifiesOnceAndRespectsTheSettings() {
        let s = settings()
        var alerts = TaskAlerts()
        func eval(_ r: TaskRun) -> [TaskNotificationKind] { alerts.evaluate([r], now: now, enabled: { s.taskNotifies($0) }).map(\.kind) }
        // What already holds at launch is taken as seen.
        #expect(eval(run(.waiting, wait: .input)) == [])
        #expect(eval(run(.running)) == [])
        let ask = alerts.evaluate([run(.waiting, wait: .input)], now: now) { s.taskNotifies($0) }
        #expect(ask.map(\.kind) == [.needsInput] && ask[0].title == "Agent run · demo needs your input")
        #expect(eval(run(.waiting, wait: .input)) == [])
        #expect(eval(run(.running)) == [] && eval(run(.waiting, wait: .input)) == [.needsInput])

        // Stale and critical failures are off by default; their episodes still pass.
        #expect(eval(run(.running, stale: true)) == [])
        let critical = TaskNode(id: "deploy", title: "Deploy", state: .failed, importance: .critical)
        #expect(eval(run(.running, nodes: [critical])) == [])
        s.setTaskNotifies(.stale, true)
        s.setTaskNotifies(.criticalFailed, true)
        #expect(eval(run(.running, nodes: [critical])) == [])
        #expect(eval(run(.running, stale: true)) == [.stale])
        #expect(eval(run(.running)) == [])
        #expect(eval(run(.running, nodes: [critical])) == [.criticalFailed])

        let done = TaskNode(id: "~agent-a", title: "a", state: .done, declared: false)
        let finished = alerts.evaluate([run(.done, nodes: [done])], now: now) { s.taskNotifies($0) }
        #expect(finished.map(\.kind) == [.finished] && finished[0].title == "Agent run · demo finished" && finished[0].body == "1 agent done.")
        #expect(eval(run(.done, nodes: [done])) == [])
        s.setTaskNotifies(.finished, false)
        #expect(eval(run(.running)) == [] && eval(run(.partial)) == [])
    }

    @Test func anAgentWaitingInARunningRunNeedsInput() {
        var alerts = TaskAlerts()
        _ = alerts.evaluate([run(.running)], now: now) { _ in true }
        let waiting = TaskNode(id: "~delegate-x", title: "Retry queue", state: .waiting, waitReason: .input, declared: false)
        let a = alerts.evaluate([run(.running, nodes: [waiting])], now: now) { _ in true }
        #expect(a.map(\.kind) == [.needsInput] && a[0].body == "Retry queue is waiting for your answer.")
    }

    @Test func aSessionsOwnPlanAlertsOnlyWithRealWork() {
        func mirrored(_ state: TaskRunState, working: TimeInterval) -> TaskRun {
            var r = run(state)
            r.mirrored = true
            r.time = TaskTimeSplit(working: working)
            return r
        }
        var alerts = TaskAlerts()
        _ = alerts.evaluate([mirrored(.running, working: 120)], now: now) { _ in true }
        // A two-minute session that ticked off its plan list is no news.
        #expect(alerts.evaluate([mirrored(.done, working: 120)], now: now) { _ in true }.isEmpty)
        var longer = TaskAlerts()
        _ = longer.evaluate([mirrored(.running, working: 20 * 60)], now: now) { _ in true }
        var ended = mirrored(.stopped, working: 20 * 60)
        ended.turnSeconds = 20 * 60
        #expect(longer.evaluate([ended], now: now) { _ in true }.map(\.kind) == [.stopped])
        // A question is always news.
        #expect(alerts.evaluate([mirrored(.waiting, working: 60)].map { var r = $0; r.waitReason = .input; return r }, now: now) { _ in true }.map(\.kind) == [.needsInput])
    }

    @Test func oldRunsNeverNotify() {
        var alerts = TaskAlerts()
        _ = alerts.evaluate([], now: now) { _ in true }
        #expect(alerts.evaluate([run(.done, updated: -3600)], now: now) { _ in true }.isEmpty)
    }

    @Test func settingsDefaults() {
        let s = settings()
        #expect(s.taskTracking)
        #expect(TaskNotificationKind.allCases.filter { s.taskNotifies($0) } == [.needsInput, .stopped, .finished])
        s.taskTracking = false
        #expect(!s.taskTracking)
        #expect(s.runQuietAfter == 15 * 60)
        s.runQuietAfter = 30 * 60
        #expect(s.runQuietAfter == 30 * 60)
        #expect(!s.syncQuestionText)
    }

    @Test func theQuestionIsTheBody() {
        var alerts = TaskAlerts()
        _ = alerts.evaluate([run(.running)], now: now) { _ in true }
        var asking = run(.waiting, wait: .input)
        asking.question = TaskQuestion(text: "May I drop the unused audit table?", options: ["Drop it", "Keep it"], askedAt: now)
        let a = alerts.evaluate([asking], now: now) { _ in true }
        #expect(a.map(\.body) == ["May I drop the unused audit table?"] && a[0].sound)
    }

    @Test func permissionPromptsInABurstReplaceEachOtherQuietly() {
        var alerts = TaskAlerts()
        var t = now
        func eval(_ r: TaskRun) -> [TaskAlerts.Alert] { alerts.evaluate([r], now: t) { _ in true } }
        func asking(_ at: TimeInterval) -> TaskRun {
            TaskRun(id: "r1", title: "r1", project: "demo", startedAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(at),
                    state: .waiting, waitReason: .input)
        }
        _ = eval(run(.running))
        let first = eval(asking(0))
        t = now.addingTimeInterval(30)
        _ = eval(run(.running, updated: 20))
        t = now.addingTimeInterval(60)
        let second = eval(asking(60))
        #expect(first.count == 1 && second.count == 1)
        // A new episode, so a new ledger entry, but the same notification on screen and no sound.
        #expect(first[0].id != second[0].id && first[0].request == second[0].request)
        #expect(first[0].sound && !second[0].sound)
        // Well after the burst it sounds again.
        t = now.addingTimeInterval(400)
        _ = eval(run(.running, updated: 390))
        t = now.addingTimeInterval(600)
        #expect(eval(asking(600)).first?.sound == true)
    }

    @Test func aLongTurnEndingAlertsAndAShortOneOrASessionEndingDoesNot() {
        let open = TaskNode(id: "api", title: "API", state: .running)
        let done = TaskNode(id: "docs", title: "Docs", state: .done)
        func ended(_ turn: Double?, left: Bool = false, updated: Double = 0) -> TaskRun {
            var r = run(.stopped, nodes: [open, done], updated: updated)
            r.turnSeconds = turn; r.left = left
            return r
        }
        var alerts = TaskAlerts()
        _ = alerts.evaluate([run(.running, nodes: [open, done])], now: now) { _ in true }
        let turn = alerts.evaluate([ended(24 * 60)], now: now) { _ in true }
        #expect(turn.map(\.kind) == [.stopped] && turn[0].title == "Agent run · demo finished its turn after 24m" && turn[0].body == "1 of 2 tasks done.")
        // Back to work and its turn ended again soon after: once is enough.
        _ = alerts.evaluate([run(.running, nodes: [open, done], updated: -30)], now: now) { _ in true }
        #expect(alerts.evaluate([ended(15 * 60, updated: -20)], now: now) { _ in true }.isEmpty)
        // Under ten minutes of work: no news.
        var quick = TaskAlerts()
        _ = quick.evaluate([run(.running, nodes: [open, done])], now: now) { _ in true }
        #expect(quick.evaluate([ended(9 * 60)], now: now) { _ in true }.isEmpty)
        // The session simply ended (left): no news either.
        var gone = TaskAlerts()
        _ = gone.evaluate([run(.running, nodes: [open, done])], now: now) { _ in true }
        #expect(gone.evaluate([ended(30 * 60, left: true)], now: now) { _ in true }.isEmpty)
    }

    @Test func finishedAtMostOnceInHalfAnHourUnlessTheOutcomeChanged() {
        var alerts = TaskAlerts()
        var t = now
        func eval(_ state: TaskRunState, _ at: TimeInterval) -> [TaskNotificationKind] {
            alerts.evaluate([run(state, updated: at)], now: t) { _ in true }.map(\.kind)
        }
        _ = eval(.running, -60)
        #expect(eval(.done, -50) == [.finished])
        // An undeclared run reopening between batches of agents doesn't ping each time.
        _ = eval(.running, -40)
        #expect(eval(.done, -30) == [])
        _ = eval(.running, -20)
        #expect(eval(.partial, -10) == [.finished])
        t = now.addingTimeInterval(31 * 60)
        _ = eval(.running, 31 * 60 - 30)
        #expect(eval(.partial, 31 * 60 - 10) == [.finished])
    }

    @Test func hiddenAndAbandonedRuns() {
        var alerts = TaskAlerts()
        var hidden = run(.running)
        hidden.hidden = true
        _ = alerts.evaluate([hidden], now: now) { _ in true }
        var ask = run(.waiting, wait: .input)
        ask.hidden = true
        #expect(alerts.evaluate([ask], now: now) { _ in true }.isEmpty)

        var other = TaskAlerts()
        _ = other.evaluate([run(.running)], now: now) { _ in true }
        var gaveUp = run(.failed)
        gaveUp.abandoned = true
        #expect(other.evaluate([gaveUp], now: now) { _ in true }.isEmpty)
    }

    @Test func theQuietAlertSaysTheThreshold() {
        var alerts = TaskAlerts()
        _ = alerts.evaluate([run(.running)], now: now, quietAfter: 1800) { _ in true }
        let a = alerts.evaluate([run(.running, stale: true)], now: now, quietAfter: 1800) { _ in true }
        #expect(a.first?.body == "No agent activity for 30 minutes." && a.first?.title == "Agent run · demo went quiet")
        #expect(TaskAlerts.span(3600) == "an hour" && TaskAlerts.span(600) == "10 minutes")
    }

    @Test func runAlertsKeepTheirOwnLedger() {
        let defaults = UserDefaults(suiteName: "headroom-tests-\(UUID().uuidString)")!
        for i in 0..<20 { #expect(Notifier.firstTime("limit.\(i)", ledger: Notifier.pacingLedger, defaults: defaults)) }
        for i in 0..<500 { _ = Notifier.firstTime("task.input.r.\(i)", ledger: Notifier.runLedger, defaults: defaults) }
        // A busy run can't push a pacing alert out and make it fire again.
        #expect(!Notifier.firstTime("limit.0", ledger: Notifier.pacingLedger, defaults: defaults))
        #expect(defaults.stringArray(forKey: Notifier.runLedger)?.count == Notifier.ledgerSize)
    }
}

@Suite struct TaskTrackerPlumbingTests {
    @Test func theQuietThresholdReachesTheFold() async throws {
        let h = TaskHome()
        try h.add("r1", 0, .add(.init(id: "a")))
        try h.add("r1", 1, .start(task: "a"))
        // The task last moved an hour ago (h.t0): quiet at 15 minutes, not at an hour and a half.
        let writer = TaskFeedWriter(home: h.url)
        #expect(await writer.refresh(hidden: [], providers: []).runs.first?.stale == true)
        #expect(await writer.refresh(hidden: [], providers: [], staleAfter: 90 * 60).runs.first?.stale == false)
    }

    @Test func aScanLeavesTheAppsFeedAlone() async throws {
        let h = TaskHome()
        try h.add("r1", 0, .add(.init(id: "a")))
        // The "app" is this test process.
        _ = await TaskFeedWriter(home: h.url, pid: getpid()).refresh(hidden: [], providers: [])
        #expect(TasksScanCommand.appOwnsFeed(home: h.url, pid: 1))
        let scan = TaskFeedWriter(home: h.url, pid: 0, writes: false)
        try h.add("r1", 5, .add(.init(id: "b")))
        let r = await scan.refresh(hidden: [], providers: [])
        #expect(!r.wrote && h.feed()?.writerPID == getpid() && h.feed()?.runs.first?.nodes.count == 1)
        // With no live writer the scan writes, with no PID of its own.
        _ = await TaskFeedWriter(home: h.url, pid: 0).refresh(hidden: [], providers: [])
        #expect(h.feed()?.writerPID == 0 && !TasksScanCommand.appOwnsFeed(home: h.url, pid: 1))
    }

    @Test func spendReachesTheOutlook() async throws {
        let h = TaskHome()
        try h.add("r1", 0, .meta(title: "Build", project: "demo", harness: "claude-code"))
        try h.add("r1", 0, .add(.init(id: "a")))
        try h.add("r1", 3590, .start(task: "a"))
        let session = SessionSnapshot(used: 0.5, left: 0.5, resetsAt: Date().addingTimeInterval(3600), level: "normal")
        let r = await TaskFeedWriter(home: h.url).refresh(hidden: [], providers: [ProviderSnapshot(id: .claude, session: session)],
                                                          spend: [.claude: ProviderSpend(tokensPerHour: 1_000_000, windowTokens: 2_000_000)])
        // No rate of its own yet (another part fills it), but the window's room is known.
        #expect(r.runs.first?.limitOutlook?.roomTokens == 2_000_000)
    }
}
