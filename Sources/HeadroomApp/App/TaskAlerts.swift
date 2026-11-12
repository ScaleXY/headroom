import Foundation
import HeadroomKit

/// Decides which task-run notifications are due: each once per episode, an episode being a
/// stretch in which the condition holds (a run needing input, a critical task failed, a run gone
/// stale, a run finished). What already held at launch is taken as seen, so a restart never
/// repeats one.
struct TaskAlerts {
    struct Alert: Equatable, Sendable {
        var kind: TaskNotificationKind
        var id: String
        var title: String
        var body: String
    }

    struct Mark: Equatable {
        var input = false
        var stale = false
        var finished = false
        var failedCritical: Set<String> = []
    }

    private var marks: [String: Mark]?

    /// The alerts that became due, for the kinds `enabled` allows. Episodes of disabled kinds are
    /// still tracked, so turning one on later doesn't fire for something old.
    mutating func evaluate(_ runs: [TaskRun], now: Date, enabled: (TaskNotificationKind) -> Bool) -> [Alert] {
        let current = Dictionary(runs.filter { $0.isActive(now: now) }.map { ($0.id, Self.mark($0)) }, uniquingKeysWith: { a, _ in a })
        defer { marks = current }
        guard let previous = marks else { return [] }
        var out: [Alert] = []
        for r in runs {
            guard let m = current[r.id] else { continue }
            let was = previous[r.id] ?? Mark()
            let name = Self.name(r)
            let stamp = Int(r.updatedAt.timeIntervalSince1970)
            if m.input, !was.input {
                let waiting = r.nodes.first { $0.state == .waiting && $0.waitReason == .input }
                out.append(Alert(kind: .needsInput, id: "task.input.\(r.id).\(stamp)", title: "\(name) needs you",
                                 body: waiting.map { "\($0.title) is waiting for your answer." } ?? "An agent is waiting for your answer."))
            }
            for id in m.failedCritical.subtracting(was.failedCritical).sorted() {
                let node = r.nodes.first { $0.id == id }
                out.append(Alert(kind: .criticalFailed, id: "task.critical.\(r.id).\(id).\(stamp)", title: "\(name): a critical task failed",
                                 body: node?.title ?? id))
            }
            if m.stale, !was.stale {
                out.append(Alert(kind: .stale, id: "task.stale.\(r.id).\(stamp)", title: "\(name) went quiet",
                                 body: "No agent activity for \(Int(TaskFold.defaultStaleAfter / 60)) minutes."))
            }
            if m.finished, !was.finished {
                // Compacted nodes were done leaves.
                let earlier = r.finishedEarlier ?? 0
                let leaves = r.nodes.filter { $0.leaf && $0.counted }.count + earlier
                let done = r.nodes.filter { $0.leaf && $0.counted && $0.state == .done }.count + earlier
                let unit = r.hasDeclaredTasks ? "task" : "agent"
                let count = "\(leaves) \(unit)\(leaves == 1 ? "" : "s")"
                let (title, body): (String, String) = switch r.state {
                case .done: ("\(name) finished", leaves == 0 ? "Everything is done." : "\(count) done.")
                case .partial: ("\(name) finished with problems", "\(done) of \(count) done.")
                default: ("\(name) failed", "A critical task failed. \(done) of \(count) done.")
                }
                out.append(Alert(kind: .finished, id: "task.finished.\(r.id).\(stamp)", title: title, body: body))
            }
        }
        return out.filter { enabled($0.kind) }
    }

    static func mark(_ r: TaskRun) -> Mark {
        Mark(input: r.needsInput || (!r.state.isTerminal && r.nodes.contains { $0.state == .waiting && $0.waitReason == .input }),
             stale: r.stale, finished: r.state.isTerminal,
             failedCritical: Set(r.nodes.filter { $0.importance == .critical && $0.state == .failed }.map(\.id)))
    }

    /// The run's title, or its project when the title is only the id.
    static func name(_ r: TaskRun) -> String { r.agentTitle ?? r.project ?? "Agent run" }
}
