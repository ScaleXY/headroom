import Foundation
import HeadroomKit

// MARK: - Styles

/// How the Runs tab lists runs. Every style opens a run's own page on click.
public enum RunsListStyle: Int, CaseIterable, Sendable {
    /// One line per run in fixed columns: state, name, meter, figure, time.
    case ledger
    /// The name and figure, and under them what's happening, with a hairline of progress.
    case twoLine
    /// Each line is its own progress bar, tinted by state; finished runs fold into a tally.
    case fill

    public var title: String {
        switch self {
        case .ledger: "Ledger"
        case .twoLine: "Two-line"
        case .fill: "Fill rows"
        }
    }

    public var detail: String {
        switch self {
        case .ledger: "One line per run, in columns. The densest."
        case .twoLine: "Adds what each run is doing, under its name."
        case .fill: "Each line fills as the run gets along."
        }
    }
}

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
        /// "1/3 · 2 agents", "asks · 14m", "optional".
        public var meta: String?
        public var tone: RunTone
        public var glyph: RunGlyph
        public var mustHave: Bool
        public var bars: [Bar]
        public init(id: String, title: String, meta: String? = nil, tone: RunTone, glyph: RunGlyph, mustHave: Bool = false, bars: [Bar]) {
            self.id = id; self.title = title; self.meta = meta; self.tone = tone; self.glyph = glyph; self.mustHave = mustHave; self.bars = bars
        }
    }

    public struct Tick: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case plain, now, limit, finish }
        public var label: String
        public var at: Double
        public var kind: Kind
        public init(label: String, at: Double, kind: Kind = .plain) { self.label = label; self.at = at; self.kind = kind }
    }

    public var lanes: [Lane]
    /// Where now sits, 0…1.
    public var now: Double
    /// The limit's pause, as fractions.
    public var pause: ClosedRange<Double>?
    public var ticks: [Tick]
    /// Open lanes past the ones drawn.
    public var moreLanes: Int

    public init(lanes: [Lane], now: Double, pause: ClosedRange<Double>? = nil, ticks: [Tick], moreLanes: Int = 0) {
        self.lanes = lanes; self.now = now; self.pause = pause; self.ticks = ticks; self.moreLanes = moreLanes
    }
}

/// What a run's own page needs beyond the card: its status line, facts, limit, grouped tasks and lanes.
public struct RunPageModel: Sendable, Hashable {
    public var status: RunStatusModel
    /// The list's second line (Two-line): the question, the pause, what's running.
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

    public init(status: RunStatusModel, line: String? = nil, facts: [RunFactModel] = [], limit: RunLimitModel? = nil, groups: [RunGroupModel] = [],
                groupsTitle: String = "Open tasks", openCount: Int = 0, doneCount: Int = 0, showDone: Bool = false, moreOpen: Int = 0,
                lanes: RunLanesModel? = nil) {
        self.status = status; self.line = line; self.facts = facts; self.limit = limit; self.groups = groups; self.groupsTitle = groupsTitle
        self.openCount = openCount; self.doneCount = doneCount; self.showDone = showDone; self.moreOpen = moreOpen; self.lanes = lanes
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
                            groups: g.groups, groupsTitle: finished ? "Didn't finish" : r.hasDeclaredTasks ? (r.mirrored ? "Open steps" : "Open tasks") : "Agents",
                            openCount: g.open, doneCount: g.done, showDone: showDone && g.done > 0, moreOpen: g.more,
                            lanes: finished ? nil : lanes(r))
    }

    // MARK: Status

    /// What a page lists: declared leaf tasks (and the replaced ones) or a mirrored plan's steps;
    /// with no plan, every agent, since one that spawned others is still at work itself. Helper
    /// agents under a declared task stay out.
    func pageLeaves(_ r: TaskRun) -> [TaskNode] {
        guard r.hasDeclaredTasks else { return r.nodes }
        return r.nodes.filter { n in n.leaf && (n.declared || n.counted || n.replacedBy != nil) }
    }

    func status(_ r: TaskRun) -> RunStatusModel {
        let leaves = pageLeaves(r)
        let open = leaves.filter { !$0.state.isTerminal }.count
        func titles(_ nodes: [TaskNode]) -> String? { nodes.isEmpty ? nil : nodes.map(\.title).joined(separator: ", ") }
        let noun = r.hasDeclaredTasks ? (r.mirrored ? "step" : "task") : "agent"
        func left(_ n: Int) -> String { "\(n) \(noun)\(n == 1 ? "" : "s") left" }
        if r.abandoned { return RunStatusModel(key: RunWords.abandoned, detail: open > 0 ? left(open) + " open" : nil) }
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
            case .dependency:
                let waiting = leaves.first { $0.state == .waiting }
                return RunStatusModel(key: "Waiting", detail: waiting?.waitNote ?? waiting.map { "\($0.title) waits on another task" })
            }
        case .stopped:
            let key = stateText(r).hasPrefix("Mac last seen") ? stateText(r) : "Stopped"
            return RunStatusModel(key: key, detail: open > 0 ? left(open) : nil)
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

    func limit(_ r: TaskRun) -> RunLimitModel? {
        guard let tl = timeline(r) else { return nil }
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
            out.append(RunFactModel(label: "Took", value: rc.duration))
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
        let listed = leaves.filter { !isDone($0) }
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
        let order = listed.enumerated().sorted { (a, b) in (a.element.attention, a.offset) < (b.element.attention, b.offset) }.map(\.element)
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
        if showDone, !done.isEmpty {
            groups.append(RunGroupModel(id: "~done", title: "Done", rows: done.map(row)))
        }
        return (groups, listed.count, done.count + (r.finishedEarlier ?? 0), listed.count - shown.count)
    }

    // MARK: Lanes

    /// The run from its start to its forecast finish (or now): a lane per open task, most pressing
    /// first, and one for everything finished. Nil before anything has a time.
    public func lanes(_ r: TaskRun) -> RunLanesModel? {
        let leaves = pageLeaves(r)
        let start = min(r.startedAt, leaves.compactMap(\.startedAt).min() ?? r.startedAt)
        let tl = timeline(r)
        let outlook = r.limitOutlook
        var finish: Date?
        if tl != nil, let f = outlook?.finishAt { finish = f }
        else if r.state == .running, !r.stale, let eta = r.etaHighSeconds ?? r.etaSeconds { finish = now.addingTimeInterval(eta) }
        let nowAt = max(now, start.addingTimeInterval(60))
        let end = max(finish ?? nowAt, nowAt.addingTimeInterval(nowAt.timeIntervalSince(start) * 0.12))
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        func at(_ d: Date) -> Double { min(max(d.timeIntervalSince(start) / span, 0), 1) }
        let nowF = at(nowAt)
        var pause: ClosedRange<Double>?
        if tl != nil, let p = outlook?.pauseAt, let q = outlook?.resumeAt, p < q { pause = at(p)...at(q) }
        let forecastEnd = finish.map(at) ?? nowF

        /// Forecast from now to `to`, broken by the pause.
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

        let open = leaves.filter { !$0.state.isTerminal }
            .enumerated().sorted { ($0.element.attention, $0.offset) < ($1.element.attention, $1.offset) }.map(\.element)
        var lanes: [RunLanesModel.Lane] = []
        for n in open.prefix(Self.laneCap) {
            let (glyph, tone) = Self.look(n)
            var bars: [RunLanesModel.Bar] = []
            var meta: [String] = []
            if let s = n.steps { meta.append("\(s.done)/\(s.total)") }
            if n.attempts.active > 1 { meta.append("\(n.attempts.active) agents") }
            let began = n.startedAt.map(at)
            switch n.state {
            case .running, .waiting:
                let kind: RunLanesModel.BarKind = n.state == .waiting && n.waitReason == .input ? .asking
                    : (n.stale || n.state == .waiting) ? .held : .running
                if let b = began { bars.append(.init(kind: kind, start: b, end: max(nowF, b + 0.01))) }
                if kind == .asking {
                    meta.append("asks" + (n.lastActivityAt.map { " · " + TimeFormat.compact(now.timeIntervalSince($0)) } ?? ""))
                } else if kind == .held, n.stale {
                    meta.append("quiet")
                }
                // What's left of it: as far as it has to go, by its own progress, within the run's forecast.
                if kind == .running, forecastEnd > nowF {
                    let left = 1 - min(max(n.progress.estimate, 0), 0.95)
                    bars += ahead(.forecast, from: nowF, to: nowF + (forecastEnd - nowF) * left)
                }
            case .parked:
                if let b = began { bars.append(.init(kind: .held, start: b, end: max(n.lastActivityAt.map(at) ?? b, b + 0.01))) }
            default:
                // Not started: the stretch it's forecast to need, at the end of the forecast.
                if forecastEnd > nowF {
                    let width = max((forecastEnd - nowF) * 0.18, 0.04)
                    bars += ahead(.planned, from: max(nowF, forecastEnd - width), to: forecastEnd)
                }
            }
            if n.importance == .optional { meta.append("optional") }
            lanes.append(.init(id: n.id, title: n.title, meta: meta.isEmpty ? nil : meta.joined(separator: " · "), tone: tone, glyph: glyph,
                               mustHave: n.importance == .critical, bars: bars))
        }
        let closed = leaves.filter(\.state.isTerminal)
        if !closed.isEmpty {
            let bars: [RunLanesModel.Bar] = closed.compactMap { n in
                guard let s = n.startedAt else { return nil }
                let e = n.endedAt ?? n.lastActivityAt ?? s
                let kind: RunLanesModel.BarKind = n.state == .failed && n.replacedBy == nil ? .failed : .done
                return .init(kind: kind, start: at(s), end: max(at(e), at(s) + 0.008))
            }
            let count = closed.count + (r.finishedEarlier ?? 0)
            lanes.append(.init(id: "~done", title: "\(count) finished", tone: .quiet, glyph: .done, bars: bars))
        }

        // Ticks: the start, each hour between, now, the pause, the finish. Hours give way to the rest.
        func clock(_ d: Date) -> String {
            TimeFormat.clock(d, calendar: calendar, locale: locale).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")
        }
        var ticks: [RunLanesModel.Tick] = [.init(label: "NOW", at: nowF, kind: .now)]
        if let p = pause, let a = outlook?.pauseAt, let b = outlook?.resumeAt {
            ticks.append(.init(label: clock(a), at: p.lowerBound, kind: .limit))
            ticks.append(.init(label: clock(b), at: p.upperBound, kind: .limit))
        }
        if let f = finish, forecastEnd > nowF { ticks.append(.init(label: clock(f), at: forecastEnd, kind: .finish)) }
        var hours: [RunLanesModel.Tick] = []
        if var h = calendar.dateInterval(of: .hour, for: start)?.end {
            let step: TimeInterval = span > 6 * 3600 ? 3 * 3600 : span > 3 * 3600 ? 2 * 3600 : 3600
            while h < end {
                hours.append(.init(label: clock(h), at: at(h)))
                h = h.addingTimeInterval(step)
            }
        }
        if hours.isEmpty { hours.append(.init(label: clock(start), at: 0)) }
        // A label needs about 9% of the width; keep the important ones.
        for t in hours where !ticks.contains(where: { abs($0.at - t.at) < 0.1 }) { ticks.append(t) }
        ticks.sort { $0.at < $1.at }
        return RunLanesModel(lanes: lanes, now: nowF, pause: pause, ticks: ticks, moreLanes: max(0, open.count - Self.laneCap))
    }
}
