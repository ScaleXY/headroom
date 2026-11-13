import Foundation
import HeadroomKit
import HeadroomPresent

/// Decides which task-run notifications are due: each once per episode, an episode being a
/// stretch in which the condition holds (a run needing input, stopped with work left, a critical
/// task failed, a run gone quiet, a run finished). What already held at launch is taken as seen,
/// so a restart never repeats one. Hidden runs never alert; an abandoned run doesn't "finish".
struct TaskAlerts {
    struct Alert: Equatable, Sendable {
        var kind: TaskNotificationKind
        /// One per episode: what the delivered ledger remembers.
        var id: String
        /// The notification's identifier: a later alert with the same one replaces it on screen.
        var request: String
        var run: String
        var title: String
        var body: String
        var sound: Bool
        /// The app can bring the run's session forward ("Open Session").
        var openable: Bool
    }

    struct Mark: Equatable {
        var input = false
        var stopped = false
        var stale = false
        var finished = false
        var failedCritical: Set<String> = []
    }

    /// Another prompt from the same run this soon replaces the last one, without a sound.
    static let repeatWindow: TimeInterval = 120
    /// A run that finishes (or stops) again this soon with the same outcome isn't news.
    static let againWindow: TimeInterval = 30 * 60

    private var marks: [String: Mark]?
    private var lastInput: [String: Date] = [:]
    private var lastFinished: [String: (at: Date, state: TaskRunState)] = [:]
    private var lastStopped: [String: Date] = [:]

    /// The alerts that became due, for the kinds `enabled` allows. Episodes of disabled kinds are
    /// still tracked, so turning one on later doesn't fire for something old. `quietAfter` is the
    /// threshold the fold used for `stale`, for the alert's wording.
    mutating func evaluate(_ runs: [TaskRun], now: Date, quietAfter: TimeInterval = TaskFold.defaultStaleAfter,
                           enabled: (TaskNotificationKind) -> Bool) -> [Alert] {
        let current = Dictionary(runs.filter { $0.isActive(now: now) }.map { ($0.id, Self.mark($0)) }, uniquingKeysWith: { a, _ in a })
        defer {
            marks = current
            // Forget runs gone from view once their windows have passed.
            lastInput = lastInput.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
            lastFinished = lastFinished.filter { now.timeIntervalSince($0.value.at) < Self.againWindow }
            lastStopped = lastStopped.filter { now.timeIntervalSince($0.value) < Self.againWindow }
        }
        guard let previous = marks else { return [] }
        var out: [Alert] = []
        for r in runs where !r.hidden {
            guard let m = current[r.id] else { continue }
            let was = previous[r.id] ?? Mark()
            let name = Self.name(r)
            let stamp = Int(r.updatedAt.timeIntervalSince1970)
            let openable = r.host != nil || r.cwd != nil
            func alert(_ kind: TaskNotificationKind, _ id: String, request: String? = nil, _ title: String, _ body: String, sound: Bool = false) {
                out.append(Alert(kind: kind, id: id, request: request ?? id, run: r.id, title: title, body: body, sound: sound, openable: openable))
            }
            if m.input, !was.input {
                // Permission prompts come in bursts: one notification per run, sounding once.
                let recent = lastInput[r.id].map { now.timeIntervalSince($0) < Self.repeatWindow } ?? false
                lastInput[r.id] = now
                alert(.needsInput, "task.input.\(r.id).\(stamp)", request: "task.input.\(r.id)", RunWords.alertNeedsInput(name), Self.question(r), sound: !recent)
            }
            for id in m.failedCritical.subtracting(was.failedCritical).sorted() {
                let node = r.nodes.first { $0.id == id }
                alert(.criticalFailed, "task.critical.\(r.id).\(id).\(stamp)", RunWords.alertCriticalFailed(name), node?.title ?? id)
            }
            // A session's own plan list is tracked for every session that keeps one: only the ones
            // with real work behind them say when they go quiet, stop or finish.
            let watched = Self.worthWatching(r)
            if m.stale, !was.stale, watched {
                alert(.stale, "task.stale.\(r.id).\(stamp)", RunWords.alertQuiet(name), "No agent activity for \(Self.span(quietAfter)).")
            }
            if m.stopped, !was.stopped, !r.abandoned, watched {
                let again = lastStopped[r.id].map { now.timeIntervalSince($0) < Self.againWindow } ?? false
                if !again {
                    lastStopped[r.id] = now
                    let (done, count) = Self.counts(r)
                    alert(.stopped, "task.stopped.\(r.id).\(stamp)", RunWords.alertStopped(name), "\(done) of \(count) done.")
                }
            }
            if m.finished, !was.finished, !r.abandoned, watched {
                let again = lastFinished[r.id].map { now.timeIntervalSince($0.at) < Self.againWindow && $0.state == r.state } ?? false
                if !again {
                    lastFinished[r.id] = (now, r.state)
                    let (done, count) = Self.counts(r)
                    let (title, body): (String, String) = switch r.state {
                    case .done: (RunWords.alertFinished(name), Self.leaves(r) == 0 ? "Everything is done." : "\(count) done.")
                    case .partial: (RunWords.alertPartial(name), "\(done) of \(count) done.")
                    default: (RunWords.alertFailed(name), "A critical task failed. \(done) of \(count) done.")
                    }
                    alert(.finished, "task.finished.\(r.id).\(stamp)", title, body)
                }
            }
        }
        return out.filter { enabled($0.kind) }
    }

    static func mark(_ r: TaskRun) -> Mark {
        Mark(input: r.needsInput || (!r.state.isTerminal && r.nodes.contains { $0.state == .waiting && $0.waitReason == .input }),
             stopped: r.state == .stopped, stale: r.stale, finished: r.state.isTerminal,
             failedCritical: Set(r.nodes.filter { $0.importance == .critical && $0.state == .failed }.map(\.id)))
    }

    /// Working time that makes a plan read off the harness worth a "finished" or "stopped" alert.
    static let mirroredMinimumWork: TimeInterval = 15 * 60

    /// A run the agent planned (or that spawned agents) always is; a session's own plan list only
    /// once it has had a quarter of an hour of work.
    static func worthWatching(_ r: TaskRun) -> Bool {
        !r.mirrored || r.time.working >= mirroredMinimumWork || r.nodes.contains { $0.attempts.count > 0 }
    }

    /// What the run is asking, in its own words when known.
    static func question(_ r: TaskRun) -> String {
        if let q = r.question?.text.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { return q }
        let waiting = r.nodes.first { $0.state == .waiting && $0.waitReason == .input }
        if let note = waiting?.waitNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { return note }
        return waiting.map { "\($0.title) is waiting for your answer." } ?? "An agent is waiting for your answer."
    }

    /// Counted leaves (compacted ones were done), and how many are done.
    static func leaves(_ r: TaskRun) -> Int { r.nodes.filter { $0.leaf && $0.counted }.count + (r.finishedEarlier ?? 0) }

    /// ("3", "5 tasks"): done leaves and the total with its unit.
    static func counts(_ r: TaskRun) -> (done: Int, total: String) {
        let earlier = r.finishedEarlier ?? 0
        let total = leaves(r)
        let done = r.nodes.filter { $0.leaf && $0.counted && $0.state == .done }.count + earlier
        let unit = r.hasDeclaredTasks ? "task" : "agent"
        return (done, "\(total) \(unit)\(total == 1 ? "" : "s")")
    }

    /// "15 minutes", "an hour", "2 hours".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return minutes == 60 ? "an hour" : "\(minutes / 60) hours"
    }

    /// The run's title, or its project when the title is only the id.
    static func name(_ r: TaskRun) -> String { r.agentTitle ?? r.project ?? "Agent run" }
}
