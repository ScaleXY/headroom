import Foundation
import HeadroomKit

/// A synced run's own page, for the iPhone and the Watch: the same parts as the Mac's, built from
/// what the Mac syncs. Rows sync only with task names included and only the open ones, so the
/// finished tasks are counted, not listed; lanes need the rows' times, which older Macs leave out.
extension RunsPresenter {
    public func syncedPage(_ d: RunDigest, card c: RunCardModel) -> RunPageModel {
        let finished = d.isSettled
        let run = pageRun(d)
        let status = syncedStatus(d, run: run, card: c)
        let limit = finished ? nil : self.limit(from: c.timeline)
        let g = groups(run, showDone: false, opened: [])
        let named = d.rows != nil
        let timed = d.rows?.contains { $0.startedAt != nil } ?? false
        return RunPageModel(status: status, line: syncedLine(d, card: c, status: status, limit: limit), facts: syncedFacts(d, card: c), limit: limit,
                            groups: g.groups, groupsTitle: d.left || d.yourTurn ? "What's left" : finished ? "Didn't finish" : run.hasDeclaredTasks ? (run.mirrored ? "Open steps" : "Open tasks") : "Agents",
                            openCount: named ? g.open + d.moreRows : 0, doneCount: g.done, moreOpen: g.more + d.moreRows,
                            lanes: !finished && d.lastSeen == nil && timed ? lanes(run) : nil, listsDone: false)
    }

    /// The run as the Mac had it, as far as the digest goes: its synced rows as nodes under the
    /// rows above them, and the limit's outlook and forecast for the lanes.
    func pageRun(_ d: RunDigest) -> TaskRun {
        let rows = d.rows ?? []
        var nodes: [TaskNode] = []
        var parents: [(depth: Int, id: String)] = []
        for (i, row) in rows.enumerated() {
            while let last = parents.last, last.depth >= row.depth { parents.removeLast() }
            let leaf = i + 1 >= rows.count || rows[i + 1].depth <= row.depth
            let est = row.estimate ?? (row.state == .done ? 1 : 0)
            nodes.append(TaskNode(id: "\(i)", title: row.title, parent: parents.last?.id, depth: row.depth, state: row.state, waitReason: row.waitReason,
                                  stale: row.stale, progress: TaskProgress(done: row.state == .done ? 1 : 0, inFlight: 0, estimate: est),
                                  importance: row.importance, declared: d.hasDeclaredTasks || d.mirrored, leaf: leaf, counted: !row.quiet, steps: row.steps,
                                  startedAt: row.startedAt, endedAt: row.endedAt, lastActivityAt: row.lastActivityAt))
            parents.append((row.depth, "\(i)"))
        }
        let eta = (d.finishAt ?? d.etaSeconds.map { d.updatedAt.addingTimeInterval($0) }).map { $0.timeIntervalSince(now) }
        return TaskRun(id: d.id, title: d.title ?? d.id, harness: d.harness, startedAt: d.startedAt, updatedAt: d.updatedAt, state: d.state,
                       waitReason: d.waitReason, stale: d.stale, progress: d.progress, mustHaves: d.mustHaves, etaSeconds: eta, tokens: d.tokens,
                       warning: d.warning, hasDeclaredTasks: d.hasDeclaredTasks || d.mirrored, nodes: nodes,
                       finishedEarlier: d.finishedEarlier + d.finishedRows, abandoned: d.abandoned,
                       time: TaskTimeSplit(working: d.workingSeconds ?? 0), etaHighSeconds: d.finishHigh.map { $0.timeIntervalSince(now) },
                       limitOutlook: d.limit, mirrored: d.mirrored, left: d.left)
    }

    func syncedStatus(_ d: RunDigest, run: TaskRun, card c: RunCardModel) -> RunStatusModel {
        if d.lastSeen != nil, !d.isSettled { return RunStatusModel(key: c.stateText) }
        if d.state.isTerminal, !d.abandoned, let rc = c.receipt {
            let key = d.state == .done ? RunWords.done : d.state == .failed ? RunWords.failed : RunWords.partial
            return RunStatusModel(key: key, detail: rc.tasks + " " + rc.tasksNote)
        }
        if d.needsInput {
            return RunStatusModel(key: "Waiting on you", detail: d.question?.asker.map { "\($0) asks" } ?? self.status(run).detail)
        }
        // Without names nothing is listed: say how many are running from the counts.
        if d.rows == nil, d.state == .running, !d.stale {
            let n = d.counts.running
            let declared = d.hasDeclaredTasks || d.mirrored
            return RunStatusModel(key: n == 0 ? RunWords.running : declared ? "\(n) running" : "\(n) agent\(n == 1 ? "" : "s") running")
        }
        return self.status(run)
    }

    func syncedLine(_ d: RunDigest, card c: RunCardModel, status: RunStatusModel, limit: RunLimitModel?) -> String? {
        if d.isSettled {
            guard let rc = c.receipt else { return status.detail }
            return [rc.tasks + " " + rc.tasksNote, rc.duration].joined(separator: " · ")
        }
        if d.needsInput, let q = d.question, !q.text.isEmpty { return "“\(q.text)”" }
        if let limit { return "Pauses \(limit.pause) at the limit" + (limit.finish.map { " · done \($0)" } ?? "") }
        if d.state == .running, !d.stale, d.lastSeen == nil, let h = c.hero, h.hourglass, let caption = h.sideCaption {
            return [caption, status.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return status.detail
    }

    func syncedFacts(_ d: RunDigest, card c: RunCardModel) -> [RunFactModel] {
        var out: [RunFactModel] = []
        if d.isSettled {
            guard let rc = c.receipt else { return out }
            out.append(RunFactModel(label: "Worked", value: rc.duration))
            out.append(RunFactModel(label: "Tokens", value: rc.tokens))
            if let cost = rc.cost { out.append(RunFactModel(label: "Cost", value: cost.replacingOccurrences(of: "about ", with: "~"))) }
            return out
        }
        if let h = c.hero, h.hourglass, let caption = h.sideCaption, caption.hasPrefix("done ") {
            out.append(RunFactModel(label: "Done", value: String(caption.dropFirst(5))))
        } else if let w = d.workingSeconds, w >= 60 {
            out.append(RunFactModel(label: "Working", value: Self.duration(w)))
        }
        if d.mustHaves.total > 0 { out.append(RunFactModel(label: "Must-haves", value: "\(d.mustHaves.done) of \(d.mustHaves.total)", mustHave: true)) }
        if d.tokens > 0 { out.append(RunFactModel(label: "Tokens", value: NumberFormat.tokens(d.tokens))) }
        return out
    }
}
