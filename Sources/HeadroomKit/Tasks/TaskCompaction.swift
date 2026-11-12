import Foundation

/// Keeps long observed runs small. A session that runs for days collects a node per agent it ever
/// spawned (one real session reached 1,004); the finished ones from yesterday tell nobody anything
/// a count can't. Declared runs are left alone: their tree is the plan someone wrote.
public enum TaskCompaction {
    /// Finished work stays listed this long after it ended.
    public static let keepFinished: TimeInterval = 86400

    /// Drops done and skipped nodes that ended before `now - keep` and have nothing left under
    /// them, deepest first (so a finished spawner goes once its agents have). Failed and cancelled
    /// nodes stay: they are what someone comes back to look for. The run's progress, state, tokens
    /// and the remaining nodes are untouched; `finishedEarlier` counts what went.
    public static func compact(_ run: TaskRun, now: Date, keep: TimeInterval = keepFinished) -> TaskRun {
        guard !run.hasDeclaredTasks, !run.nodes.isEmpty else { return run }
        let cutoff = now.addingTimeInterval(-keep)
        var keptChild: Set<String> = []
        var drop = [Bool](repeating: false, count: run.nodes.count)
        // Display order is depth first, so walking it backwards meets children before their parent.
        for i in run.nodes.indices.reversed() {
            let n = run.nodes[i]
            let ended = n.endedAt ?? n.lastActivityAt ?? n.startedAt
            if (n.state == .done || n.state == .skipped), let ended, ended < cutoff, !keptChild.contains(n.id) {
                drop[i] = true
            } else if let p = n.parent {
                keptChild.insert(p)
            }
        }
        let dropped = drop.lazy.filter { $0 }.count
        guard dropped > 0 else { return run }
        var r = run
        r.nodes = run.nodes.indices.filter { !drop[$0] }.map { run.nodes[$0] }
        r.finishedEarlier = (run.finishedEarlier ?? 0) + dropped
        return r
    }
}

extension TaskRun {
    /// The title the agent gave the run; nil while it's only the run's id (a session UUID) or blank.
    public var agentTitle: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != id, UUID(uuidString: t) == nil else { return nil }
        return t
    }
}
