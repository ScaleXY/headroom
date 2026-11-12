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
        #expect(ask.map(\.kind) == [.needsInput] && ask[0].title == "demo needs you")
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
        #expect(finished.map(\.kind) == [.finished] && finished[0].title == "demo finished" && finished[0].body == "1 agent done.")
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

    @Test func oldRunsNeverNotify() {
        var alerts = TaskAlerts()
        _ = alerts.evaluate([], now: now) { _ in true }
        #expect(alerts.evaluate([run(.done, updated: -3600)], now: now) { _ in true }.isEmpty)
    }

    @Test func settingsDefaults() {
        let s = settings()
        #expect(s.taskTracking)
        #expect(TaskNotificationKind.allCases.filter { s.taskNotifies($0) } == [.needsInput, .finished])
        s.taskTracking = false
        #expect(!s.taskTracking)
    }
}
