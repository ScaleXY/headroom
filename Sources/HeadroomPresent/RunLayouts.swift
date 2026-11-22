import Foundation
import HeadroomKit

// MARK: - Styles

/// How a run's own page draws it.
public enum RunPageStyle: Int, CaseIterable, Sendable {
    /// The status, the percent and its facts, the task meter, the limit, then the open tasks.
    case briefing
    /// A time chart: a lane per open task, with now, the limit's pause and the forecast finish.
    case lanes

    public var title: String {
        switch self {
        case .briefing: "Briefing"
        case .lanes: "Lanes"
        }
    }

    public var detail: String {
        switch self {
        case .briefing: "What it's doing, how far along, and the open tasks."
        case .lanes: "Each task on a timeline, with the limit's pause."
        }
    }
}

// MARK: - Models

/// The run's state in one line: a short key in the state's colour, and what it's about.
public struct RunStatusModel: Sendable, Hashable {
    /// "3 running", "Quiet 18m", "Waiting on you", "Paused at the limit", "Done".
    public var key: String
    /// "Refunds, Receipts, Cover checkout end to end", "on Rebuild the search index".
    public var detail: String?

    public init(key: String, detail: String? = nil) { self.key = key; self.detail = detail }
}

/// The run will pause at its provider's 5-hour limit before it finishes.
public struct RunLimitModel: Sendable, Hashable {
    /// "10:30 AM"
    public var pause: String
    /// "11:20 AM"
    public var resume: String
    /// "~11:45 AM"
    public var finish: String?
    /// The full forecast, for a tooltip.
    public var note: String?

    public init(pause: String, resume: String, finish: String? = nil, note: String? = nil) {
        self.pause = pause; self.resume = resume; self.finish = finish; self.note = note
    }
}

/// A label and its figure on the run page: "Done" "~11:45 AM", "Must-haves" "2 of 3".
public struct RunFactModel: Sendable, Hashable {
    public var label: String
    public var value: String
    /// Drawn with the must-have diamond.
    public var mustHave: Bool

    public init(label: String, value: String, mustHave: Bool = false) { self.label = label; self.value = value; self.mustHave = mustHave }
}

/// Open tasks under the parent they belong to ("Port the checkout endpoints › Rewrite the routes").
public struct RunGroupModel: Sendable, Hashable, Identifiable {
    public var id: String
    /// Nil for top-level tasks.
    public var title: String?
    public var rows: [RunRowModel]

    public init(id: String, title: String?, rows: [RunRowModel]) { self.id = id; self.title = title; self.rows = rows }
}

/// The run as a time chart: a lane per open task (and one for the finished ones), bars where
/// work happened, outlines where it's forecast, the limit's pause as a band.
public struct RunLanesModel: Sendable, Hashable {
    public enum BarKind: Sendable, Hashable {
        /// Finished work.
        case done
        /// Work under way, up to now.
        case running
        /// Waiting on you.
        case asking
        /// Running but quiet, or waiting on something.
        case held
        case failed
        /// Forecast: what's left of work under way.
        case forecast
        /// Not started; drawn where the forecast leaves room for it.
        case planned
    }

    public struct Bar: Sendable, Hashable {
        public var kind: BarKind
        /// Fractions 0…1 of the chart's width.
        public var start: Double
        public var end: Double
        public init(kind: BarKind, start: Double, end: Double) { self.kind = kind; self.start = start; self.end = end }
    }

    public struct Lane: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        /// "1/3 · 2 agents", "optional": what the task is, beside its title.
        public var meta: String?
        /// Where it stands, on the right: "~10:14", "Asks you · 4m", "Quiet 18m", "Back 10:48", "Not started", "1 failed".
        public var status: String?
        /// The status's colour; `.neutral` reads as a plain figure.
        public var statusTone: RunTone
        public var tone: RunTone
        public var glyph: RunGlyph
        public var mustHave: Bool
        public var bars: [Bar]
        public init(id: String, title: String, meta: String? = nil, status: String? = nil, statusTone: RunTone = .neutral, tone: RunTone,
                    glyph: RunGlyph, mustHave: Bool = false, bars: [Bar]) {
            self.id = id; self.title = title; self.meta = meta; self.status = status; self.statusTone = statusTone
            self.tone = tone; self.glyph = glyph; self.mustHave = mustHave; self.bars = bars
        }

        /// The lane that holds every finished task.
        public var isFinished: Bool { id == "~done" }
    }

    public struct Tick: Sendable, Hashable {
        /// `start`: when the run began, at the left edge. `limit`: the pause's two edges.
        public enum Kind: Sendable, Hashable { case plain, start, now, limit, finish }
        public var label: String
        public var at: Double
        public var kind: Kind
        public init(label: String, at: Double, kind: Kind = .plain) { self.label = label; self.at = at; self.kind = kind }
    }

    public var lanes: [Lane]
    /// Where now sits, 0…1.
    public var now: Double
    /// The limit's pause, as fractions; it may hold now, when the run is paused already.
    public var pause: ClosedRange<Double>?
    /// The forecast finish, when there is one past now.
    public var finish: Double?
    public var ticks: [Tick]
    /// Open lanes past the ones drawn.
    public var moreLanes: Int

    public init(lanes: [Lane], now: Double, pause: ClosedRange<Double>? = nil, finish: Double? = nil, ticks: [Tick], moreLanes: Int = 0) {
        self.lanes = lanes; self.now = now; self.pause = pause; self.finish = finish; self.ticks = ticks; self.moreLanes = moreLanes
    }

    /// The finished lane marks where each task ended up to this many tasks; past it, the dots blur.
    public static let dotCap = 24

    /// The bars' spans with overlaps joined: where any of them ran.
    public static func merged(_ bars: [Bar]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for b in bars.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, b.start <= last.upperBound + 0.004 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, b.end)
            } else {
                out.append(b.start...max(b.end, b.start))
            }
        }
        return out
    }
}

/// What a run's own page needs beyond the card: its status line, facts, limit, grouped tasks and lanes.
public struct RunPageModel: Sendable, Hashable {
    public var status: RunStatusModel
    /// A short second line: the question, the pause, what's running.
    public var line: String?
    public var facts: [RunFactModel]
    public var limit: RunLimitModel?
    /// Open tasks while live; what didn't finish once finished. The finished ones follow when `showDone`.
    public var groups: [RunGroupModel]
    /// "Open tasks" while live, "Didn't finish" once finished.
    public var groupsTitle: String
    public var openCount: Int
    public var doneCount: Int
    public var showDone: Bool
    /// Open rows past the cap.
    public var moreOpen: Int
    public var lanes: RunLanesModel?
    /// The finished tasks can be listed (`showDone`). A synced run carries only its open ones, so
    /// it says how many finished without a way to show them.
    public var listsDone: Bool

    public init(status: RunStatusModel, line: String? = nil, facts: [RunFactModel] = [], limit: RunLimitModel? = nil, groups: [RunGroupModel] = [],
                groupsTitle: String = "Open tasks", openCount: Int = 0, doneCount: Int = 0, showDone: Bool = false, moreOpen: Int = 0,
                lanes: RunLanesModel? = nil, listsDone: Bool = true) {
        self.status = status; self.line = line; self.facts = facts; self.limit = limit; self.groups = groups; self.groupsTitle = groupsTitle
        self.openCount = openCount; self.doneCount = doneCount; self.showDone = showDone; self.moreOpen = moreOpen; self.lanes = lanes
        self.listsDone = listsDone
    }
}

// MARK: - Building

extension RunsPresenter {
    /// Open rows on a run page before "and N more".
    public static let pageRowCap = 12
    /// Lanes drawn before the rest are counted.
    public static let laneCap = 6

    /// The run page's parts. `showDone` lists the finished tasks too; `opened` holds rows showing
    /// their details (`rowKey`).
    public func pageModel(_ r: TaskRun, showDone: Bool = false, opened: Set<String> = []) -> RunPageModel {
        let finished = Self.isFinished(r)
        let status = self.status(r)
        let limit = finished ? nil : self.limit(r)
        let g = groups(r, showDone: showDone, opened: opened)
        return RunPageModel(status: status, line: line(r, status: status, limit: limit), facts: facts(r, limit: limit), limit: limit,
                            groups: g.groups,
                            groupsTitle: r.left || r.yourTurn ? "What's left" : finished ? "Didn't finish" : r.hasDeclaredTasks ? (r.mirrored ? "Open steps" : "Open tasks") : "Agents",
                            openCount: g.open, doneCount: g.done, showDone: showDone && g.done > 0, moreOpen: g.more,
                            lanes: finished ? nil : lanes(r))
    }

    // MARK: Status

    /// What a page lists: declared leaf tasks (and the replaced ones) or a mirrored plan's steps;
    /// with no plan, every agent, since one that spawned others is still at work itself. Helper
    /// agents under a declared task stay out.
    func pageLeaves(_ r: TaskRun) -> [TaskNode] {
        guard r.hasDeclaredTasks else { return r.nodes }
        return r.jobNodes.filter { n in n.leaf && (n.declared || n.counted || n.replacedBy != nil) }
    }

    func status(_ r: TaskRun) -> RunStatusModel {
        let leaves = pageLeaves(r)
        let open = leaves.filter { !$0.state.isTerminal }.count
        func titles(_ nodes: [TaskNode]) -> String? { nodes.isEmpty ? nil : nodes.map(\.title).joined(separator: ", ") }
        let noun = r.hasDeclaredTasks ? (r.mirrored ? "step" : "task") : "agent"
        func left(_ n: Int) -> String { "\(n) \(noun)\(n == 1 ? "" : "s") left" }
        if r.abandoned { return RunStatusModel(key: RunWords.closed, detail: open > 0 ? left(open) + " open" : nil) }
        switch r.state {
        case .running where r.stale:
            let quietFor = TimeFormat.compact(now.timeIntervalSince(r.updatedAt))
            let last = leaves.filter { $0.state == .running }.max { ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast) }
            return RunStatusModel(key: "Quiet \(quietFor)", detail: last.map { "on \($0.title)" })
        case .running:
            let running = leaves.filter { $0.state == .running }
            let key = running.isEmpty ? RunWords.running : r.hasDeclaredTasks ? "\(running.count) running" : "\(running.count) agent\(running.count == 1 ? "" : "s") running"
            return RunStatusModel(key: key, detail: titles(running))
        case .waiting:
            switch r.waitReason ?? .dependency {
            case .input:
                let asker = r.question?.task.flatMap { id in r.nodes.first { $0.id == id }?.title }
                    ?? leaves.first { $0.state == .waiting && $0.waitReason == .input }?.title
                return RunStatusModel(key: "Waiting on you", detail: asker.map { "\($0) asks" })
            case .limit:
                let resume = r.limitOutlook?.resumeAt.map { "resumes \(TimeFormat.clock($0, calendar: calendar, locale: locale))" }
                return RunStatusModel(key: "Paused at the limit", detail: resume)
            case .dependency, .you:
                let waiting = leaves.first { $0.state == .waiting }
                return RunStatusModel(key: "Waiting", detail: waiting?.waitNote ?? waiting.map { "\($0.title) waits on another task" })
            }
        case .stopped:
            if stateText(r).hasPrefix("Mac last seen") { return RunStatusModel(key: stateText(r), detail: open > 0 ? left(open) : nil) }
            // Must-haves done is said under the status (the verdict), not twice.
            var detail = [open > 0 ? left(open) : nil, r.mustHavesDone && !r.left ? RunWords.mustHavesDone : nil].compactMap { $0 }
            if r.left { detail.append("session ended") }
            return RunStatusModel(key: r.left ? RunWords.left(at: r.hasDeclaredTasks ? shownPercent(r) : nil) : RunWords.yourTurn,
                                  detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
        case .done:
            let (tasks, note) = Self.receiptTasks(r)
            return RunStatusModel(key: RunWords.done, detail: tasks + " " + note)
        case .partial, .failed:
            let lost = leaves.filter { ($0.state == .failed || $0.state == .partial) && $0.replacedBy == nil }
            let detail = lost.first.map { $0.title + (lost.count > 1 ? " and \(lost.count - 1) more failed" : " failed") }
            return RunStatusModel(key: r.state == .failed ? RunWords.failed : RunWords.partial, detail: detail)
        }
    }

    /// The Two-line list's second line: the question, the pause, when it's done and what's running.
    func line(_ r: TaskRun, status: RunStatusModel, limit: RunLimitModel?) -> String? {
        if Self.isFinished(r) {
            let rc = receipt(r)
            return [rc.tasks + " " + rc.tasksNote, rc.duration].joined(separator: " · ")
        }
        if r.needsInput, let q = question(r) { return "“\(q.text)”" }
        if let limit { return "Pauses \(limit.pause) at the limit" + (limit.finish.map { " · done \($0)" } ?? "") }
        if r.state == .running, !r.stale, let caption = hero(r).sideCaption, hero(r).hourglass {
            return [caption, status.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return status.detail
    }

    func limit(_ r: TaskRun) -> RunLimitModel? { limit(from: timeline(r)) }

    func limit(from tl: RunTimelineModel?) -> RunLimitModel? {
        guard let tl else { return nil }
        func tick(_ label: String) -> String? { tl.ticks.first { $0.label == label }?.time }
        guard let pause = tick("window empty"), let resume = tick("resets") else { return nil }
        return RunLimitModel(pause: pause, resume: resume, finish: tick("done"), note: tl.note)
    }

    /// The figures beside the percent: when it's done, the must-haves, the tokens; or how long it's
    /// worked; or, finished, how long it took and what it cost.
    func facts(_ r: TaskRun, limit: RunLimitModel?) -> [RunFactModel] {
        var out: [RunFactModel] = []
        if Self.isFinished(r) {
            let rc = receipt(r)
            out.append(RunFactModel(label: "Worked", value: rc.duration))
            out.append(RunFactModel(label: "Tokens", value: rc.tokens))
            if let cost = rc.cost { out.append(RunFactModel(label: "Cost", value: cost.replacingOccurrences(of: "about ", with: "~"))) }
            return out
        }
        let h = hero(r)
        if h.hourglass, let caption = h.sideCaption, caption.hasPrefix("done ") {
            out.append(RunFactModel(label: "Done", value: String(caption.dropFirst(5))))
        } else if r.time.working >= 60 {
            out.append(RunFactModel(label: "Working", value: Self.duration(r.time.working)))
        }
        if r.mustHaves.total > 0 { out.append(RunFactModel(label: "Must-haves", value: "\(r.mustHaves.done) of \(r.mustHaves.total)", mustHave: true)) }
        if r.tokens > 0 { out.append(RunFactModel(label: "Tokens", value: NumberFormat.tokens(r.tokens))) }
        return out
    }

    // MARK: Groups

    /// Open leaves under their parents' names, most pressing first; finished runs list what didn't
    /// finish instead. `showDone` adds the finished leaves as a last group.
    func groups(_ r: TaskRun, showDone: Bool, opened: Set<String>) -> (groups: [RunGroupModel], open: Int, done: Int, more: Int) {
        let finished = Self.isFinished(r)
        var byID: [String: TaskNode] = [:]
        for n in r.nodes { byID[n.id] = n }
        let leaves = pageLeaves(r)
        func isDone(_ n: TaskNode) -> Bool { n.state == .done || (finished && n.state == .skipped && n.replacedBy == nil) }
        // Live: what's still open, and apart from it what failed. Finished: whatever didn't finish.
        // Yours first on a run that waits on its person: that's what they can do now.
        let listed = (finished && !r.left ? leaves.filter { !isDone($0) } : leaves.filter { !$0.state.isTerminal })
        let failed = finished ? [] : leaves.filter { $0.state.isTerminal && !isDone($0) && $0.state != .skipped && $0.state != .cancelled }
        let done = leaves.filter(isDone)
        // "Port the checkout endpoints › Rewrite the routes": the last two ancestors.
        func path(_ n: TaskNode) -> String? {
            var names: [String] = []
            var p = n.parent
            var guardCount = 0
            while let id = p, let node = byID[id], guardCount < 16 {
                names.insert(node.title, at: 0); p = node.parent; guardCount += 1
            }
            return names.isEmpty ? nil : names.suffix(2).joined(separator: " › ")
        }
        func row(_ n: TaskNode) -> RunRowModel {
            taskRow(n, depth: 0, run: r, rolled: [], opened: opened.contains(Self.rowKey(run: r.id, row: n.id)))
        }
        func yours(_ n: TaskNode) -> Int { n.state == .waiting && n.waitReason == .you && r.state == .stopped ? 0 : 1 }
        let order = listed.enumerated().sorted { (a, b) in (yours(a.element), a.element.attention, a.offset) < (yours(b.element), b.element.attention, b.offset) }
            .map(\.element)
        let shown = Array(order.prefix(Self.pageRowCap))
        var groups: [RunGroupModel] = []
        var index: [String: Int] = [:]
        for n in shown {
            let title = path(n)
            let key = title ?? "~top"
            if let i = index[key] { groups[i].rows.append(row(n)) } else {
                index[key] = groups.count
                groups.append(RunGroupModel(id: key, title: title, rows: [row(n)]))
            }
        }
        // Top-level tasks read as "Other" only beside named groups.
        if groups.count > 1, let i = index["~top"] {
            let top = groups.remove(at: i)
            groups.append(RunGroupModel(id: top.id, title: "Other", rows: top.rows))
        }
        if !failed.isEmpty {
            // The first few; the count says how many in all.
            let shownFailed = failed.prefix(3)
            groups.append(RunGroupModel(id: "~failed", title: failed.count > shownFailed.count ? "Didn't finish · \(failed.count)" : "Didn't finish",
                                        rows: shownFailed.map(row)))
        }
        if showDone, !done.isEmpty {
            groups.append(RunGroupModel(id: "~done", title: "Done", rows: done.map(row)))
        }
        // The jobs this session finished before this one: one row each, folded under "This session".
        let earlier = r.earlierJobs
        if !earlier.isEmpty {
            groups.append(RunGroupModel(id: TaskFold.sessionID, title: "\(TaskFold.sessionTitle) · \(earlier.count + 1) jobs",
                                        rows: earlier.map { n in
                                            var row = row(n)
                                            let ls = r.nodes.filter { $0.leaf && $0.depth > n.depth && isUnder($0, n.id, byID) }
                                            if !ls.isEmpty { row.steps = "\(ls.filter { $0.state == .done }.count) of \(ls.count)" }
                                            return row
                                        }))
        }
        return (groups, listed.count, done.count + (r.finishedEarlier ?? 0), listed.count - shown.count)
    }

    /// Whether `n` sits beneath the node `ancestor`.
    func isUnder(_ n: TaskNode, _ ancestor: String, _ byID: [String: TaskNode]) -> Bool {
        var p = n.parent, hops = 0
        while let id = p, hops < 32 {
            if id == ancestor { return true }
            p = byID[id]?.parent; hops += 1
        }
        return false
    }

    // MARK: Lanes

    /// The run from its start to its forecast finish (or now): a lane per open task, most pressing
    /// first, and one for everything finished. A task that stopped moving shows when: its bar runs
    /// in blue while it worked, then turns rose from the question, or amber from when it went
    /// quiet or hit the limit. A pause at the limit, coming or under way, is a band that work
    /// forecast past it skips. Nil before anything has a time.
    public func lanes(_ r: TaskRun) -> RunLanesModel? {
        let leaves = pageLeaves(r)
        let start = min(r.startedAt, leaves.compactMap(\.startedAt).min() ?? r.startedAt)
        let outlook = r.limitOutlook
        let nowAt = max(now, start.addingTimeInterval(60))

        // The pause: coming (the timeline's forecast), or under way (blocked now, until it resets).
        var pauseFrom: Date?, pauseTo: Date?, finish: Date?
        if timeline(r) != nil, let o = outlook {
            pauseFrom = o.pauseAt; pauseTo = o.resumeAt; finish = o.finishAt
        } else if let o = outlook, let p = o.pauseAt, let q = o.resumeAt, p <= now, q > now,
                  r.state == .waiting, r.waitReason == .limit {
            // It paused when it last moved: the outlook only knows it's paused as of now.
            pauseFrom = max(start, min(p, r.updatedAt)); pauseTo = q; finish = o.finishAt.flatMap { $0 > q ? $0 : nil }
        } else if r.state == .running, !r.stale, let eta = r.etaHighSeconds ?? r.etaSeconds {
            finish = now.addingTimeInterval(eta)
        }
        let farthest = [finish, pauseTo].compactMap { $0 }.max() ?? nowAt
        // Room past the last thing drawn, so now (or the resume) never sits on the edge.
        let lead = finish == nil ? 0.14 : 0.04
        let end = max(farthest, nowAt).addingTimeInterval(max(max(farthest, nowAt).timeIntervalSince(start) * lead, 60))
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        func at(_ d: Date) -> Double { min(max(d.timeIntervalSince(start) / span, 0), 1) }
        func clock(_ d: Date) -> String {
            TimeFormat.clock(d, calendar: calendar, locale: locale).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")
        }
        let nowF = at(nowAt)
        var pause: ClosedRange<Double>?
        if let a = pauseFrom, let b = pauseTo, a < b { pause = at(a)...at(b) }
        let finishF = finish.map(at)
        let forecastEnd = finishF ?? nowF
        /// Where `share` of the working time left ends, skipping the pause.
        func workingEnd(_ share: Double) -> Double {
            let pauseLen = pause.map { max(0, min($0.upperBound, forecastEnd) - max($0.lowerBound, nowF)) } ?? 0
            let need = max(0, forecastEnd - nowF - pauseLen) * share
            guard let p = pause, nowF + need > p.lowerBound, p.upperBound > nowF else { return nowF + need }
            return min(p.upperBound + (need - max(0, p.lowerBound - nowF)), forecastEnd)
        }
        /// Forecast from `from` to `to`, broken by the pause.
        func ahead(_ kind: RunLanesModel.BarKind, from: Double, to: Double) -> [RunLanesModel.Bar] {
            guard to > from + 0.002 else { return [] }
            if let p = pause, p.lowerBound < to, p.upperBound > from {
                var out: [RunLanesModel.Bar] = []
                if p.lowerBound > from { out.append(.init(kind: kind, start: from, end: p.lowerBound)) }
                if to > p.upperBound { out.append(.init(kind: kind, start: p.upperBound, end: to)) }
                return out
            }
            return [.init(kind: kind, start: from, end: to)]
        }
        /// Worked from `began` until `turned`, then `kind` until now.
        func worked(from began: Double, turned: Double?, then kind: RunLanesModel.BarKind) -> [RunLanesModel.Bar] {
            let stop = max(nowF, began + 0.01)
            guard let turned, turned > began + 0.004, turned < stop - 0.004 else { return [.init(kind: kind, start: began, end: stop)] }
            return [.init(kind: .running, start: began, end: turned), .init(kind: kind, start: turned, end: stop)]
        }

        let open = leaves.filter { !$0.state.isTerminal }
            .enumerated().sorted { ($0.element.attention, $0.offset) < ($1.element.attention, $1.offset) }.map(\.element)
        var lanes: [RunLanesModel.Lane] = []
        for n in open.prefix(Self.laneCap) {
            let (glyph, tone) = Self.look(n)
            var bars: [RunLanesModel.Bar] = []
            var meta: [String] = []
            var status: String?, statusTone = tone
            if let s = n.steps { meta.append("\(s.done)/\(s.total)") }
            if n.attempts.active > 1 { meta.append("\(n.attempts.active) agents") }
            if n.importance == .optional { meta.append("optional") }
            let began = n.startedAt.map(at)
            let left = 1 - min(max(n.progress.estimate, 0), 0.95)
            switch n.state {
            case .running where !n.stale:
                if let b = began { bars.append(.init(kind: .running, start: b, end: max(nowF, b + 0.01))) }
                // What's left of it: as far as it has to go, by its own progress, within the run's forecast.
                if forecastEnd > nowF {
                    let to = workingEnd(left)
                    bars += ahead(.forecast, from: nowF, to: to)
                    status = "~" + clock(start.addingTimeInterval(to * span)); statusTone = .neutral
                } else {
                    status = "Running"
                }
            case .waiting where n.waitReason == .input:
                // Rose from the question (for this task, or the run's own), else from when it last moved.
                let asked = r.question.flatMap { $0.task == n.id || $0.task == nil ? $0.askedAt : nil } ?? n.lastActivityAt
                if let b = began { bars += worked(from: b, turned: asked.map(at), then: .asking) }
                status = "Asks you" + (asked.map { " · " + TimeFormat.compact(now.timeIntervalSince($0)) } ?? "")
            case .waiting where n.waitReason == .limit:
                if let b = began { bars += worked(from: b, turned: (pauseFrom ?? n.lastActivityAt).map(at), then: .held) }
                if let p = pause, forecastEnd > p.upperBound { bars += ahead(.forecast, from: nowF, to: workingEnd(left)) }
                status = pauseTo.map { "Back " + clock($0) } ?? "At the limit"
            case .running, .waiting:
                // Quiet, or waiting on something else: amber from when it last moved.
                if let b = began { bars += worked(from: b, turned: n.lastActivityAt.map(at), then: .held) }
                if n.stale {
                    status = "Quiet" + (n.lastActivityAt.map { " " + TimeFormat.compact(now.timeIntervalSince($0)) } ?? "")
                } else {
                    status = "Waiting"; statusTone = .quiet
                }
            case .parked:
                if let b = began { bars.append(.init(kind: .held, start: b, end: max(n.lastActivityAt.map(at) ?? b, b + 0.01))) }
                status = "Parked"; statusTone = .quiet
            default:
                // Not started: the stretch it's forecast to need, at the end of the forecast.
                if forecastEnd > nowF {
                    let width = max((forecastEnd - nowF) * 0.18, 0.04)
                    bars += ahead(.planned, from: max(nowF, forecastEnd - width), to: forecastEnd)
                }
                status = "Not started"; statusTone = .quiet
            }
            lanes.append(.init(id: n.id, title: n.title, meta: meta.isEmpty ? nil : meta.joined(separator: " · "), status: status,
                               statusTone: statusTone, tone: tone, glyph: glyph, mustHave: n.importance == .critical, bars: bars))
        }
        let closed = leaves.filter(\.state.isTerminal)
        if !closed.isEmpty {
            var failed = 0
            let bars: [RunLanesModel.Bar] = closed.compactMap { n in
                let broke = n.state == .failed && n.replacedBy == nil
                if broke { failed += 1 }
                guard let s = n.startedAt else { return nil }
                let e = n.endedAt ?? n.lastActivityAt ?? s
                return .init(kind: broke ? .failed : .done, start: at(s), end: max(at(e), at(s) + 0.008))
            }
            let count = closed.count + (r.finishedEarlier ?? 0)
            lanes.append(.init(id: "~done", title: "\(count) finished", status: failed > 0 ? "\(failed) failed" : nil,
                               statusTone: .alert, tone: .quiet, glyph: failed > 0 ? .failed : .done, bars: bars))
        }

        // Ticks: the start, each hour between, now, the pause, the finish. Hours give way to the rest.
        var ticks: [RunLanesModel.Tick] = [.init(label: "NOW", at: nowF, kind: .now), .init(label: clock(start), at: 0, kind: .start)]
        if let p = pause, let a = pauseFrom, let b = pauseTo {
            ticks.append(.init(label: clock(a), at: p.lowerBound, kind: .limit))
            ticks.append(.init(label: clock(b), at: p.upperBound, kind: .limit))
        }
        if let f = finish, let ff = finishF, ff > nowF { ticks.append(.init(label: "~" + clock(f), at: ff, kind: .finish)) }
        var hours: [RunLanesModel.Tick] = []
        // At most about five: whole hours, or whole days (named) for a run that spans days.
        let stepHours = [1, 2, 3, 6, 12, 24, 48, 168].first { span / Double($0 * 3600) <= 5 } ?? 168
        let unit: Calendar.Component = stepHours >= 24 ? .day : .hour
        if var h = calendar.dateInterval(of: unit, for: start)?.end {
            while h < end {
                let label = stepHours >= 24 ? TimeFormat.weekdayShort(h, calendar: calendar, locale: locale) : clock(h)
                hours.append(.init(label: label, at: at(h)))
                // Days step by the calendar: 24 hours on from midnight isn't midnight when the clocks change.
                h = calendar.date(byAdding: unit, value: stepHours >= 24 ? stepHours / 24 : stepHours, to: h) ?? h.addingTimeInterval(Double(stepHours) * 3600)
            }
        }
        // A label needs about 9% of the width; keep the important ones.
        for t in hours where !ticks.contains(where: { abs($0.at - t.at) < 0.1 }) { ticks.append(t) }
        ticks.sort { $0.at < $1.at }
        return RunLanesModel(lanes: lanes, now: nowF, pause: pause, finish: finishF.flatMap { $0 > nowF ? $0 : nil }, ticks: ticks,
                             moreLanes: max(0, open.count - Self.laneCap))
    }
}
