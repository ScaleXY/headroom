import Foundation
import HeadroomCore
import HeadroomKit

/// `HeadroomApp tasks-scan [--claude-root DIR] [--codex-root DIR] [--since HOURS]`: runs the task
/// observer once over the transcript roots, writes observed events and `tasks.json` under
/// `HEADROOM_HOME` (or the usual folder), and prints counts only. No credentials, no network, no UI.
enum TasksScanCommand {
    static func run(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let standard = LogRoots.standard()
        let roots = LogRoots(claude: value("--claude-root").map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? standard.claude,
                             codex: value("--codex-root").map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? standard.codex)
        guard let hours = Double(value("--since") ?? "24"), hours > 0 else {
            print("usage: HeadroomApp tasks-scan [--claude-root DIR] [--codex-root DIR] [--since HOURS]")
            return 2
        }
        let home = SnapshotFile.directory
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let t0 = Date()
            let observer = TaskObserver(roots: roots, home: home)
            let report = await observer.scan(since: Date().addingTimeInterval(-hours * 3600))
            await observer.flush()
            // A running app keeps tasks.json (with its limits and its PID): leave it be. Otherwise
            // write it with no PID, since this process is gone in a moment.
            let appOwnsFeed = Self.appOwnsFeed(home: home)
            let writer = TaskFeedWriter(home: home, pid: 0, writes: !appOwnsFeed)
            let result = await writer.refresh(hidden: await observer.boundChildren, providers: [])
            let s = await observer.summary()
            let kinds = TaskAttemptKind.allCases.map { "\($0.rawValue) \(s.attempts[$0] ?? 0)" }.joined(separator: ", ")
            box.lines = [
                "files read: \(report.filesRead) (\(report.bytes / 1_000_000) MB), events written: \(report.events)",
                "runs: \(s.runs) observed, \(result.runs.count) \(appOwnsFeed ? "folded (tasks.json left to the running app)" : "in tasks.json")",
                "attempts: \(kinds)",
                "delegates bound to a child: \(s.delegatesBound) of \(s.delegates)",
                "tagged attempts: \(s.tagged)",
                String(format: "took %.2fs", Date().timeIntervalSince(t0)),
            ]
            done.signal()
        }
        done.wait()
        box.lines.forEach { print($0) }
        return 0
    }

    /// Whether another live process (the app) wrote `tasks.json` and still runs.
    static func appOwnsFeed(home: URL, pid: Int32 = getpid()) -> Bool {
        guard let feed = TasksFile.read(from: TasksFile.url(home: home)) else { return false }
        return feed.writerPID != pid && TasksFile.writerIsAlive(feed)
    }
}
