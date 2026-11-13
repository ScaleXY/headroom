import Foundation
import HeadroomCore
import HeadroomKit
import HeadroomPresent

/// What runs are read against: each provider's limits as the snapshot states them, and what each
/// is spending on this Mac right now. Built by the model when its readings change, not per fold.
struct TaskLimitInputs: Sendable, Equatable {
    var providers: [ProviderSnapshot] = []
    var spend: [Provider: ProviderSpend] = [:]
}

/// Task tracking in the app: the transcript observer, the `tasks.json` writer and the run
/// notifications. Folds again on `TaskJournal.notification` (the CLI, hooks and run actions), on
/// new observed events, and once a minute while a run is live or an agent's end can only be seen
/// by polling. Idle (no timer, no work) when nothing is live.
@MainActor
final class TaskTracker {
    static let tick: TimeInterval = 60

    private(set) var runs: [TaskRun] = []
    /// Called on the main actor when `runs` changed.
    var onChange: (() -> Void)?

    private let observer: TaskObserver
    private let writer: TaskFeedWriter
    private let settings: AppSettings
    private let notifier: Notifier
    /// The providers' limits and spend, for the limit outlook (cached by the model).
    private let limits: @MainActor () -> TaskLimitInputs
    private var alerts = TaskAlerts()
    private var journalObserver: RefreshObserver?
    private var timer: Timer?
    private var busy = false
    private var again = false
    private var stopped = false

    init(home: URL = SnapshotFile.directory, roots: LogRoots = .standard(), settings: AppSettings, notifier: Notifier,
         limits: @escaping @MainActor () -> TaskLimitInputs) {
        observer = TaskObserver(roots: roots, home: home)
        writer = TaskFeedWriter(home: home)
        self.settings = settings
        self.notifier = notifier
        self.limits = limits
    }

    /// Catches up on the last day of transcripts, then listens.
    func start() {
        journalObserver = RefreshObserver(name: TaskJournal.notification) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let observer = observer
        Task {
            let t0 = Date()
            let report = await observer.scan(since: Date().addingTimeInterval(-TaskObserver.firstLook))
            diag.notice("tasks scan files=\(report.filesRead) bytes=\(report.bytes) events=\(report.events) \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
            refresh()
        }
    }

    /// Saves the observer's cursors (on quit).
    func flush() async { await observer.flush() }

    func stop() {
        stopped = true
        let observer = observer
        Task { await observer.flush() }
        journalObserver = nil
        timer?.invalidate()
        timer = nil
        if !runs.isEmpty { runs = []; onChange?() }
    }

    /// Paths the log watcher reported.
    func transcriptsChanged(_ paths: [String]) {
        let observer = observer
        Task {
            let report = await observer.ingest(paths: paths)
            if report.events > 0 { refresh() }
        }
    }

    /// FSEvents dropped events: look at everything changed in the last day.
    func rescan() {
        let observer = observer
        Task {
            _ = await observer.scan(since: Date().addingTimeInterval(-TaskObserver.firstLook))
            refresh()
        }
    }

    /// Limits changed: only matters while something is live.
    func limitsChanged() {
        if runs.contains(where: { !$0.state.isTerminal }) { refresh() }
    }

    /// Folds and writes; calls that arrive meanwhile fold once more afterwards.
    func refresh() {
        guard !stopped else { return }
        guard !busy else { again = true; return }
        busy = true
        let inputs = limits()
        let staleAfter = settings.runQuietAfter
        let observer = observer, writer = writer
        Task {
            let hidden = await observer.boundChildren
            let result = await writer.refresh(hidden: hidden, providers: inputs.providers, spend: inputs.spend, staleAfter: staleAfter,
                                              calendar: Display.calendar, locale: Display.locale)
            let polling = await observer.needsPolling
            finish(result.runs, polling: polling)
        }
    }

    private func finish(_ new: [TaskRun], polling: Bool) {
        busy = false
        guard !stopped else { return }
        RunHistory.shared.record(new)
        if new != runs {
            runs = new
            onChange?()
        }
        let settings = settings
        for a in alerts.evaluate(new, now: Date(), quietAfter: settings.runQuietAfter, enabled: { settings.taskNotifies($0) }) { notifier.post(a) }
        // Past an hour of quiet a run is stale and nothing about it moves with the clock.
        let live = new.contains { !$0.state.isTerminal && Date().timeIntervalSince($0.updatedAt) < 3600 }
        arm(live || polling)
        if again { again = false; refresh() }
    }

    private func arm(_ needed: Bool) {
        guard needed else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticked() }
        }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func ticked() {
        let observer = observer
        Task {
            _ = await observer.poll()
            refresh()
        }
    }
}
