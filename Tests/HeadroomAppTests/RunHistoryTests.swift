import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

@MainActor @Suite struct RunHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("run-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func run(_ id: String, state: TaskRunState = .done, endedHoursAgo: Double = 1, hidden: Bool = false) -> TaskRun {
        TaskRun(id: id, title: "Run \(id)", harness: "claude-code", startedAt: now.addingTimeInterval(-endedHoursAgo * 3600 - 600),
                updatedAt: now.addingTimeInterval(-endedHoursAgo * 3600), state: state, tokens: 1000, hasDeclaredTasks: true,
                nodes: [TaskNode(id: "a", title: "A", state: state == .done ? .done : .running)], hidden: hidden, tokensByModel: ["m": 1000])
    }

    @Test func keepsFinishedRunsAndReadsThemBack() throws {
        let d = dir()
        let history = RunHistory(directory: d)
        history.record([run("live", state: .running), run("done"), run("failed", state: .failed, endedHoursAgo: 3)], now: now)
        #expect(history.records(now: now).map(\.id) == ["done", "failed"])
        // A fresh instance reads the file.
        let again = RunHistory(directory: d).records(now: now)
        #expect(again.map(\.id) == ["done", "failed"] && again[0].tasks == "1 of 1" && again[0].tokensByModel == ["m": 1000])
    }

    @Test func aLeftRunIsRecordedAndResumingTakesTheRecordBack() throws {
        let d = dir()
        let history = RunHistory(directory: d)
        var left = run("left", state: .stopped)
        left.left = true
        left.time = TaskTimeSplit(working: 300, idle: 300)
        history.record([left], now: now)
        let rec = try #require(history.records(now: now).first)
        #expect(rec.id == "left" && rec.left == true && rec.worked == 300)
        // Resumed: open again, so it's no longer in history (and never counted twice).
        var resumed = left
        resumed.left = false
        resumed.state = .running
        history.record([resumed], now: now)
        #expect(history.records(now: now).isEmpty)
        // Left again: one record, not two.
        history.record([left], now: now)
        #expect(history.records(now: now).map(\.id) == ["left"])
        // Your turn is not settled: never recorded.
        let fresh = RunHistory(directory: dir())
        fresh.record([run("turn", state: .stopped)], now: now)
        #expect(fresh.records(now: now).isEmpty)
    }

    @Test func recordsFromBeforeTheLifecycleLoad() throws {
        let d = dir()
        let old = #"[{"abandoned":false,"ended_at":"2027-01-15T07:00:00Z","harness":"claude-code","hidden":false,"id":"x","started_at":"2027-01-10T07:00:00Z","state":"done","tasks":"1 of 1","tasks_note":"tasks","time":{"idle":0,"waiting_input":0,"waiting_limit":0,"working":0},"title":"Old","tokens":10,"tokens_by_model":{}}]"#
        try Data(old.utf8).write(to: d.appendingPathComponent("run-history.json"))
        let rec = try #require(RunHistory(directory: d).records(now: now).first)
        #expect(rec.left == nil && rec.percent == nil)
        // No split: the time open stands in for the time worked.
        #expect(rec.worked == 5 * 86400)
    }

    @Test func writesNothingWhenNothingChanged() throws {
        let d = dir()
        let history = RunHistory(directory: d)
        history.record([run("done")], now: now)
        try FileManager.default.removeItem(at: history.url)
        history.record([run("done"), run("live", state: .running)], now: now)
        #expect(!FileManager.default.fileExists(atPath: history.url.path))
        // Hiding it is a change.
        history.record([run("done", hidden: true)], now: now)
        #expect(FileManager.default.fileExists(atPath: history.url.path))
        #expect(history.records(now: now).first?.hidden == true)
    }

    @Test func keepsTwoWeeksAndFiftyRuns() {
        let history = RunHistory(directory: dir())
        history.record((0..<60).map { run("r\($0)", endedHoursAgo: Double($0) + 1) } + [run("ancient", endedHoursAgo: 15 * 24)], now: now)
        let kept = history.records(now: now)
        #expect(kept.count == RunHistory.cap && kept.first?.id == "r0" && !kept.contains { $0.id == "ancient" })
        // Two weeks on, the old ones age out.
        let later = now.addingTimeInterval(14 * 86400 - 5 * 3600)
        history.record([], now: later)
        #expect(history.records(now: later).map(\.id) == ["r0", "r1", "r2", "r3"])
    }
}
