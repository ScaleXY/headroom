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

extension TaskCompaction {
    /// Lines of a run's observed file (by index) whose activity can go without changing its fold.
    ///
    /// The fold reads an `attempt.activity` of an open attempt only for times and running totals:
    /// last activity and token totals (maxima), working stretches (activity within
    /// `TaskFold.workingGap` joins up), session tokens (handed out when anything else happens) and
    /// waits cleared by the first activity after them. So within a stretch of one attempt's
    /// activity with nothing between but other attempts' activity, a line can go when its
    /// neighbours are within the gap of each other: the first and last stay, every other kind of
    /// event, the end of a wait's grace and an attempt's first activity break the stretch, and
    /// nothing goes from the last `TaskFold.recentLookback` plus an hour, which the recent token
    /// rate reads sample by sample.
    static func droppableActivity(journal: [TaskEvent], observed: [TaskEvent?]) -> Set<Int> {
        struct Item { var event: TaskEvent; var line: Int?; var offset: Int }
        // Fold order: by time, ties in file order with the journal first.
        var items = journal.enumerated().map { Item(event: $0.element, line: nil, offset: $0.offset) }
        for (i, e) in observed.enumerated() { if let e { items.append(Item(event: e, line: i, offset: journal.count + i)) } }
        items.sort { ($0.event.at, $0.offset) < ($1.event.at, $1.offset) }
        guard let last = items.last?.event.at else { return [] }
        let cutoff = last.addingTimeInterval(-(TaskFold.recentLookback + 3600))

        var drop: Set<Int> = []
        var stretch: [String: [Item]] = [:]
        var known: Set<String> = []
        var endedAt: [String: Date] = [:]
        var deadlines: [Date] = []
        func settle() {
            for seq in stretch.values where seq.count > 2 {
                var kept = seq[0].event.at
                for i in 1..<(seq.count - 1) {
                    let next = seq[i + 1].event.at
                    if let line = seq[i].line, next < cutoff, next.timeIntervalSince(kept) <= TaskFold.workingGap {
                        drop.insert(line)
                    } else {
                        kept = seq[i].event.at
                    }
                }
            }
            stretch = [:]
        }
        for it in items {
            let e = it.event
            if case .activity(let key, .none, _) = e.op, known.contains(key), endedAt[key] == nil, !deadlines.contains(where: { e.at >= $0 }) {
                stretch[key, default: []].append(it)
                continue
            }
            settle()
            deadlines.removeAll { e.at >= $0 }
            switch e.op {
            case .attempt(let s):
                if let end = endedAt[s.key], e.at > end { endedAt[s.key] = nil }
                known.insert(s.key)
            case .activity(let key, _, _):
                known.insert(key)
            case .attemptEnd(let key, _):
                if known.contains(key) { endedAt[key] = e.at }
            case .end, .abandon:
                for k in known where endedAt[k] == nil { endedAt[k] = e.at }
            case .wait:
                if e.source == .agent || e.source == .user { deadlines.append(e.at.addingTimeInterval(TaskFold.waitGrace)) }
            default:
                break
            }
        }
        settle()
        return drop
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
