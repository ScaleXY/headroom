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
