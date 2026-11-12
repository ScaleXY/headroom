import Foundation
import HeadroomKit

/// Folds the task event files of the last week into `tasks.json`, with long observed runs
/// compacted (`TaskCompaction`) for the file and the app alike.
///
/// Runs are cached with their files' sizes and times: a run is read and folded again only when
/// its files changed, or while it's unfinished and recent (the stale overlay and the ETA move with
/// the clock). Calibration is `TaskFold.foldCalibrated`'s, computed across the cache: tokens per
/// effort unit come from done leaves, which don't depend on it, so only unfinished runs fold twice.
actor TaskFeedWriter {
    static let window: TimeInterval = 7 * 86400
    /// Unfinished runs quiet for longer are left as last folded.
    static let liveWindow: TimeInterval = 86400

    struct Cached {
        var signature: [Double]
        var run: TaskRun?
        var newest: Double
    }

    let home: URL
    private let now: @Sendable () -> Date
    private let pid: Int32
    private var cache: [String: Cached] = [:]
    private var lastBody: Data?
    private var lastRuns: [TaskRun]?
    private var prunedAt: Date = .distantPast
    /// Folds done since launch, for tests and diagnostics.
    private(set) var folds = 0

    init(home: URL, pid: Int32 = getpid(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.pid = pid
        self.now = now
    }

    struct Result: Sendable {
        /// Most pressing first.
        var runs: [TaskRun]
        var wrote: Bool
    }

    /// Folds what changed, hides `hidden` runs (delegates' child sessions), reads each against
    /// the providers' limits, and writes `tasks.json` if anything but its timestamp changed.
    func refresh(hidden: Set<String>, providers: [ProviderSnapshot], calendar: Calendar = .current, locale: Locale = .current) -> Result {
        let now = now()
        let since = now.addingTimeInterval(-Self.window).timeIntervalSince1970
        let files = listing()
        if now.timeIntervalSince(prunedAt) > 3600 {
            prunedAt = now
            prune(files, before: since)
        }
        cache = cache.filter { files[$0.key].map { $0.newest >= since } ?? false }

        var events: [String: [TaskEvent]] = [:]
        for (run, f) in files where f.newest >= since {
            let c = cache[run]
            let live = c?.run.map { !$0.state.isTerminal && now.timeIntervalSince($0.updatedAt) < Self.liveWindow } ?? true
            guard c?.signature != f.signature || live else { continue }
            events[run] = TaskJournal.read(run: run, home: home)
            cache[run] = Cached(signature: f.signature, run: nil, newest: f.newest)
        }
        for (run, list) in events {
            cache[run]?.run = TaskFold.fold(list, now: now).first
            folds += 1
        }
        if let tpu = TaskFold.tokensPerEffortUnit(cache.values.compactMap(\.run)) {
            for (run, list) in events where cache[run]?.run.map({ !$0.state.isTerminal }) == true {
                cache[run]?.run = TaskFold.fold(list, now: now, tokensPerEffortUnit: tpu).first
                folds += 1
            }
        }
        let runs = cache.values.compactMap(\.run).filter { !hidden.contains($0.id) && $0.updatedAt.timeIntervalSince1970 >= since }
            .map { TaskLimits.adjust(TaskCompaction.compact($0, now: now), providers: providers, now: now, calendar: calendar, locale: locale) }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        return Result(runs: runs.sortedForDisplay(), wrote: write(TasksFeed(generatedAt: now, writerPID: pid, runs: runs)))
    }

    /// Writes atomically, and only when the content apart from `generated_at` differs from what's on disk.
    private func write(_ feed: TasksFeed) -> Bool {
        // Cheaper than encoding a large feed to find it's the same.
        if lastBody != nil, feed.runs == lastRuns { return false }
        var body = feed
        body.generatedAt = .distantPast
        guard let encoded = try? TasksFile.encoder().encode(body) else { return false }
        let url = TasksFile.url(home: home)
        if lastBody == nil, var onDisk = TasksFile.read(from: url) {
            onDisk.generatedAt = .distantPast
            lastBody = try? TasksFile.encoder().encode(onDisk)
        }
        guard encoded != lastBody, let data = try? TasksFile.encoder().encode(feed) else {
            lastRuns = feed.runs
            return false
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".tasks.\(getpid()).tmp")
        guard (try? data.write(to: tmp)) != nil else { return false }
        chmod(tmp.path, 0o600)
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        lastBody = encoded
        lastRuns = feed.runs
        return true
    }

    struct Files {
        var signature: [Double] = [0, 0, 0, 0]
        var newest: Double = 0
    }

    /// Each run's event files: size and modification time of the journal, then the observed file.
    private func listing() -> [String: Files] {
        var out: [String: Files] = [:]
        for (i, stream) in TaskJournal.Stream.allCases.enumerated() {
            let dir = TaskJournal.directory(stream, home: home)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                var st = stat()
                guard stat(dir.appendingPathComponent(name).path, &st) == 0 else { continue }
                let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                let run = String(name.dropLast(6))
                var f = out[run] ?? Files()
                f.signature[i * 2] = Double(st.st_size)
                f.signature[i * 2 + 1] = m
                f.newest = max(f.newest, m)
                out[run] = f
            }
        }
        return out
    }

    /// Deletes the event files of runs nobody has touched for a week.
    private func prune(_ files: [String: Files], before cutoff: Double) {
        for (run, f) in files where f.newest < cutoff {
            for s in TaskJournal.Stream.allCases { try? FileManager.default.removeItem(at: TaskJournal.url(run: run, stream: s, home: home)) }
        }
    }
}
