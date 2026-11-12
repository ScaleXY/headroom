import Foundation
import HeadroomKit

// MARK: - Models

/// What a run, row or glyph means, for the renderer to colour: blue for work moving, ink for
/// settled, amber for something to look at, rose for something that needs you or broke.
public enum RunTone: Sendable, Hashable {
    case progress, neutral, warn, alert, quiet
}

public enum RunGlyph: Sendable, Hashable {
    case planned, running, stale, needsInput, waiting, parked, stopped, done, partial, failed, skipped
    /// "and N more".
    case more
}

/// One line under a run card: a task, or a summary standing in for several.
public struct RunRowModel: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case task
        /// Finished rows folded into one; `expanded` when they are shown above it instead.
        case finished(count: Int, expanded: Bool)
        /// Rows past the cap.
        case more(Int)
        /// Finished agents compacted away (`TaskRun.finishedEarlier`).
        case earlier(Int)
        /// A run synced without names: its work counted by state, in one line.
        case counts
    }

    public var id: String
    public var kind: Kind
    public var glyph: RunGlyph
    public var tone: RunTone
    /// 0…2; deeper work is rolled into its ancestor at 2.
    public var depth: Int
    public var title: String
    /// "critical" or "optional".
    public var marker: String?
    /// "2/4": declared steps, or finished/total of the work rolled into this row.
    public var steps: String?
    public var tokens: String?
    /// The note that matters for the state: the wait note, the failure, the last note.
    public var detail: String?
    public var detailTone: RunTone
    /// Doesn't count toward the run (skipped, cancelled, a failed optional, a helper agent).
    public var quiet: Bool

    public init(id: String, kind: Kind = .task, glyph: RunGlyph, tone: RunTone, depth: Int = 0, title: String, marker: String? = nil,
                steps: String? = nil, tokens: String? = nil, detail: String? = nil, detailTone: RunTone = .quiet, quiet: Bool = false) {
        self.id = id; self.kind = kind; self.glyph = glyph; self.tone = tone; self.depth = depth; self.title = title; self.marker = marker
        self.steps = steps; self.tokens = tokens; self.detail = detail; self.detailTone = detailTone; self.quiet = quiet
    }

    /// The finished summary row: clicking it shows or hides the finished rows.
    public var toggles: Bool { if case .finished = kind { true } else { false } }
}

public struct RunCardModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// Project, harness, when it started (when titles clash) and how long ago it moved.
    public var subtitle: String
    public var stateText: String
    public var glyph: RunGlyph
    public var tone: RunTone
    /// Not finished. Finished runs of the last day draw quieter.
    public var live: Bool
    /// The agent declared a plan: percent and bar. Otherwise agent counts.
    public var declared: Bool
    public var needsInput: Bool
    /// The harness's provider, for the card's brand wash.
    public var provider: Provider?
    /// Done, in flight and not started, for the three-part bar (declared runs only).
    public var bar: TaskProgress?
    /// "42%" for a declared run, "7 of 9 agents finished" for an observed one.
    public var headline: String
    /// "~55%" when token use suggests more than was reported done.
    public var estimate: String?
    /// "must-haves 3 of 4", "about 25m left", "1.2M tokens".
    public var figures: [String]
    public var warning: String?
    public var rows: [RunRowModel]
    /// Has finished rows to show or hide.
    public var expandable: Bool
    public var expanded: Bool

    public init(id: String, title: String, subtitle: String, stateText: String, glyph: RunGlyph, tone: RunTone, live: Bool, declared: Bool,
                needsInput: Bool = false, provider: Provider? = nil, bar: TaskProgress? = nil, headline: String, estimate: String? = nil,
                figures: [String] = [], warning: String? = nil, rows: [RunRowModel] = [], expandable: Bool = false, expanded: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.stateText = stateText; self.glyph = glyph; self.tone = tone
        self.live = live; self.declared = declared; self.needsInput = needsInput; self.provider = provider; self.bar = bar
        self.headline = headline; self.estimate = estimate; self.figures = figures; self.warning = warning; self.rows = rows
        self.expandable = expandable; self.expanded = expanded
    }
}

/// The Runs tab: live runs first, then the ones that finished in the last day.
public struct RunsPageModel: Sendable, Hashable {
    public var live: [RunCardModel]
    public var recent: [RunCardModel]
    /// Finished runs of the last day past the ones shown.
    public var moreRecent: Int

    public init(live: [RunCardModel] = [], recent: [RunCardModel] = [], moreRecent: Int = 0) {
        self.live = live; self.recent = recent; self.moreRecent = moreRecent
    }

    public var isEmpty: Bool { live.isEmpty && recent.isEmpty }

    public static let emptyTitle = "No runs yet"
    public static let emptyBody = "Runs show up here when an agent spawns subagents. Run headroom hooks install for needs-input alerts, and headroom task guide to have agents report percentages."
    public static let recentTitle = "Finished in the last day"
}

/// The menu bar's run indicator: the most pressing live run's progress, and whether any needs you.
public struct RunsMenuBarModel: Sendable, Hashable {
    public var fraction: Double
    /// "42%", or "7/9" agents for a run with nothing declared.
    public var text: String
    public var needsInput: Bool
    public var spoken: String

    public init(fraction: Double, text: String, needsInput: Bool, spoken: String) {
        self.fraction = fraction; self.text = text; self.needsInput = needsInput; self.spoken = spoken
    }
}

// MARK: - Presenter

/// Turns folded runs into cards with every word resolved, for the Mac popover and the iPhone.
public struct RunsPresenter: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale

    /// Rows per card before "and N more".
    public static let rowCap = 10
    public static let expandedRowCap = 40
    /// Deeper work is rolled into its ancestor at this depth.
    public static let maxDepth = 2
    /// Finished runs stay on the tab this long.
    public static let recentWindow: TimeInterval = 86400
    public static let recentCap = 4

    public init(now: Date, calendar: Calendar = Display.calendar, locale: Locale = Display.locale) {
        self.now = now; self.calendar = calendar; self.locale = locale
    }

    /// `runs` most pressing first (`sortedForDisplay`, as `AppModel.taskRuns` has them).
    public func page(_ runs: [TaskRun], expanded: Set<String> = []) -> RunsPageModel {
        let shown = runs.filter { now.timeIntervalSince($0.updatedAt) < Self.recentWindow }
        let live = shown.filter { !$0.state.isTerminal }
        let finished = shown.filter(\.state.isTerminal).sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let recent = Array(finished.prefix(Self.recentCap))
        // Runs with the same name say when they started.
        var counts: [String: Int] = [:]
        for r in live + recent { counts[baseTitle(r), default: 0] += 1 }
        func make(_ r: TaskRun) -> RunCardModel { card(r, expanded: expanded.contains(r.id), sayStart: (counts[baseTitle(r)] ?? 0) > 1) }
        return RunsPageModel(live: live.map(make), recent: recent.map(make), moreRecent: finished.count - recent.count)
    }

    /// The indicator for the most pressing run that's running or waiting; nil when none is.
    public func menuBar(_ runs: [TaskRun]) -> RunsMenuBarModel? {
        let live = runs.filter { ($0.state == .running || $0.state == .waiting) && $0.isActive(now: now) }
        guard let r = live.first else { return nil }
        let needs = live.contains(where: \.needsInput)
        let name = displayTitle(r)
        if r.hasDeclaredTasks {
            let pct = percent(r.progress.done)
            return RunsMenuBarModel(fraction: r.progress.done, text: "\(pct)%", needsInput: needs,
                                    spoken: "\(name): \(pct)% done." + (needs ? " A run needs your input." : ""))
        }
        let (finished, total) = agentCounts(r)
        return RunsMenuBarModel(fraction: total > 0 ? Double(finished) / Double(total) : 0, text: "\(finished)/\(total)", needsInput: needs,
                                spoken: "\(name): \(finished) of \(total) agents finished." + (needs ? " A run needs your input." : ""))
    }

    // MARK: Card

    public func card(_ r: TaskRun, expanded: Bool = false, sayStart: Bool = false) -> RunCardModel {
        let declared = r.hasDeclaredTasks
        let (glyph, tone) = Self.look(r)
        var figures: [String] = []
        var headline: String
        var estimate: String?
        if declared {
            headline = "\(percent(r.progress.done))%"
            if percent(r.progress.estimate) > percent(r.progress.done) { estimate = "~\(percent(r.progress.estimate))%" }
            if r.mustHaves.total > 0 { figures.append("must-haves \(r.mustHaves.done) of \(r.mustHaves.total)") }
            if let eta = r.etaSeconds { figures.append("about \(TimeFormat.compact(eta)) left") }
        } else {
            // No percent and no ETA: nobody knows how many more agents will come.
            let (finished, total) = agentCounts(r)
            headline = total == 0 ? "No agents yet" : "\(finished) of \(total) agent\(total == 1 ? "" : "s") finished"
            let running = r.nodes.filter { $0.state == .running }.count
            let failed = r.nodes.filter { $0.state == .failed }.count
            if running > 0 { figures.append("\(running) running") }
            if failed > 0 { figures.append("\(failed) failed") }
        }
        if r.tokens > 0 { figures.append("\(NumberFormat.tokens(r.tokens)) tokens") }
        let built = rows(r, expanded: expanded)
        return RunCardModel(id: r.id, title: displayTitle(r, sayStart: sayStart), subtitle: subtitle(r), stateText: stateText(r), glyph: glyph,
                            tone: tone, live: !r.state.isTerminal, declared: declared, needsInput: r.needsInput,
                            provider: TaskLimits.provider(named: r.harness), bar: declared ? r.progress : nil, headline: headline,
                            estimate: estimate, figures: figures, warning: r.warning, rows: built.rows, expandable: built.finished > 0,
                            expanded: expanded && built.finished > 0)
    }

    /// The agent's title; else the project folder; else what ran it. Never the session id.
    public func displayTitle(_ r: TaskRun, sayStart: Bool = false) -> String {
        let base = baseTitle(r)
        return sayStart ? base + " · " + TimeFormat.shortDayTime(r.startedAt, now: now, calendar: calendar, locale: locale) : base
    }

    func baseTitle(_ r: TaskRun) -> String {
        if let t = r.agentTitle { return t }
        if let p = r.project?.trimmingCharacters(in: .whitespaces), !p.isEmpty { return p }
        if let h = Self.harnessName(r.harness) { return "\(h) run" }
        return "Agent run"
    }

    /// "Claude Code", "Codex", or the harness as written.
    static func harnessName(_ h: String?) -> String? {
        guard let h, !h.isEmpty else { return nil }
        switch TaskLimits.provider(named: h) {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case nil: return h
        }
    }

    func subtitle(_ r: TaskRun) -> String {
        var parts: [String] = []
        if let p = r.project, !p.isEmpty, p != baseTitle(r) { parts.append(p) }
        if let h = Self.harnessName(r.harness) { parts.append(h) }
        let age = TimeFormat.freshness(since: r.updatedAt, now: now)
        let ago = age == "now" ? "just now" : "\(age) ago"
        parts.append(r.state.isTerminal ? "finished \(ago)" : "updated \(ago)")
        return parts.joined(separator: " · ")
    }

    /// The run's state in plain words.
    public func stateText(_ r: TaskRun) -> String {
        switch r.state {
        case .running where r.stale: "Quiet for \(TimeFormat.compact(now.timeIntervalSince(r.updatedAt)))"
        case .running: "Running"
        case .waiting:
            switch r.waitReason ?? .dependency {
            case .input: "Needs your input"
            case .limit: Self.limitWords(r.warning)
            case .dependency: "Waiting on another task"
            }
        case .stopped: "Stopped with work left"
        case .done: "Done"
        case .partial: "Finished with failures"
        case .failed: "Failed"
        }
    }

    /// `TaskLimits` names the limit in the warning it writes.
    static func limitWords(_ warning: String?) -> String {
        let w = warning ?? ""
        if w.contains("weekly") { return "Waiting on the weekly limit" }
        if w.contains("outage") { return "Waiting out an outage" }
        if w.contains("5-hour") || w.isEmpty { return "Waiting on the 5-hour limit" }
        return "Waiting on a usage limit"
    }

    static func look(_ r: TaskRun) -> (RunGlyph, RunTone) {
        switch r.state {
        case .running where r.stale: (.stale, .warn)
        case .running: (.running, .progress)
        case .waiting where r.waitReason == .input: (.needsInput, .alert)
        case .waiting where r.waitReason == .limit: (.waiting, .warn)
        case .waiting: (.waiting, .neutral)
        case .stopped: (.stopped, .warn)
        case .done: (.done, .neutral)
        case .partial: (.partial, .warn)
        case .failed: (.failed, .alert)
        }
    }

    /// Finished agents over agents seen, compacted ones included.
    func agentCounts(_ r: TaskRun) -> (finished: Int, total: Int) {
        let earlier = r.finishedEarlier ?? 0
        return (r.nodes.filter(\.state.isTerminal).count + earlier, r.nodes.count + earlier)
    }

    /// Whole percent, rounded down (never "100%" before it's done); the nudge keeps 0.57 at 57.
    func percent(_ f: Double) -> Int { Int((min(max(f, 0), 1) * 100 + 1e-9).rounded(.down)) }

    // MARK: Rows

    /// Pressing work first at every level (by the most pressing thing beneath each row), three
    /// levels at most, finished rows folded into one unless `expanded`, capped with "and N more".
    /// Linear in the nodes apart from sorting siblings, and only the rows shown are formatted.
    public func rows(_ r: TaskRun, expanded: Bool) -> (rows: [RunRowModel], finished: Int) {
        let l = layout(r, expanded: expanded)
        let nodes = r.nodes
        let cap = expanded ? Self.expandedRowCap : Self.rowCap
        let shown = l.visible.prefix(cap)
        var out = shown.map { taskRow(nodes[$0.node], depth: $0.depth, run: r, rolled: $0.depth == Self.maxDepth ? descendants($0.node, nodes, l.children) : []) }
        if l.visible.count > cap {
            let n = l.visible.count - cap
            out.append(RunRowModel(id: "~more", kind: .more(n), glyph: .more, tone: .quiet, title: "and \(n) more"))
        }
        let finished = l.finished
        if finished > 0 {
            out.append(RunRowModel(id: "~finished", kind: .finished(count: finished, expanded: expanded), glyph: .done, tone: .quiet,
                                   title: expanded ? "Hide \(finished) finished" : "\(finished) finished"))
        }
        if let earlier = r.finishedEarlier, earlier > 0 {
            out.append(RunRowModel(id: "~earlier", kind: .earlier(earlier), glyph: .done, tone: .quiet, title: "+ \(earlier) finished earlier"))
        }
        return (out, finished)
    }

    /// The rows `rows(_:expanded:)` shows, in order, before the cap: each node with its display
    /// depth; `finished` counts the finished rows folded away (or shown, when `expanded`).
    func layout(_ r: TaskRun, expanded: Bool) -> (visible: [(node: Int, depth: Int)], finished: Int, children: [[Int]]) {
        let nodes = r.nodes
        var index: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { index[n.id] = i }
        var children = [[Int]](repeating: [], count: nodes.count)
        var roots: [Int] = []
        for (i, n) in nodes.enumerated() {
            if let p = n.parent, let pi = index[p], pi != i { children[pi].append(i) } else { roots.append(i) }
        }
        // Most pressing attention in each subtree; depth-first order puts children after parents.
        var sub = nodes.map(\.attention)
        for i in nodes.indices.reversed() { for c in children[i] where sub[c] < sub[i] { sub[i] = sub[c] } }
        func ordered(_ ids: [Int]) -> [Int] { ids.sorted { (sub[$0], $0) < (sub[$1], $1) } }

        var visible: [(node: Int, depth: Int)] = []
        var hiddenFinished = 0
        var shownFinished = 0
        func countRows(_ i: Int, _ depth: Int) -> Int {
            depth >= Self.maxDepth ? 1 : children[i].reduce(1) { $0 + countRows($1, depth + 1) }
        }
        func visit(_ i: Int, _ depth: Int) {
            if sub[i] == .done {
                if !expanded { hiddenFinished += countRows(i, depth); return }
                shownFinished += 1
            }
            visible.append((i, depth))
            guard depth < Self.maxDepth else { return }
            for c in ordered(children[i]) { visit(c, depth + 1) }
        }
        for i in ordered(roots) { visit(i, 0) }
        return (visible, expanded ? shownFinished : hiddenFinished, children)
    }

    func descendants(_ i: Int, _ nodes: [TaskNode], _ children: [[Int]]) -> [TaskNode] {
        var out: [TaskNode] = []
        var stack = children[i].reversed() as [Int]
        while let j = stack.popLast() {
            out.append(nodes[j])
            stack.append(contentsOf: children[j].reversed())
        }
        return out
    }

    /// One task's row. `rolled` is the work beneath it past the depth cap, in depth-first order.
    func taskRow(_ n: TaskNode, depth: Int, run: TaskRun, rolled: [TaskNode]) -> RunRowModel {
        let (glyph, tone) = Self.look(n)
        var steps: String?
        if let s = n.steps, n.leaf { steps = "\(s.done)/\(s.total)" }
        else if !rolled.isEmpty { steps = "\(rolled.filter(\.state.isTerminal).count)/\(rolled.count)" }
        var (detail, detailTone) = note(n, limitWarning: run.warning)
        // A deeper task that needs looking at speaks for the row it's rolled into.
        if let worst = rolled.min(by: { $0.attention < $1.attention }), worst.attention < n.attention, worst.attention < .running {
            let (d, t) = note(worst, limitWarning: run.warning)
            detail = worst.title + (d.map { ": " + $0 } ?? "")
            detailTone = t
        }
        var extra: [String] = []
        if n.attempts.retries > 0 { extra.append("retried \(n.attempts.retries)×") }
        if n.attempts.active > 1 { extra.append("\(n.attempts.active) agents") }
        // Observed agents never report an outcome, so only a declared plan expects one.
        if run.hasDeclaredTasks, !n.confirmed, n.state.isTerminal { extra.append("unconfirmed") }
        if !extra.isEmpty { detail = ([detail].compactMap { $0 } + extra).joined(separator: " · ") }
        let quiet = !n.counted || n.state == .skipped || n.state == .cancelled
        return RunRowModel(id: n.id, glyph: glyph, tone: quiet && tone != .alert ? .quiet : tone, depth: depth, title: n.title,
                           marker: n.importance == .normal ? nil : n.importance.rawValue, steps: steps,
                           tokens: n.tokens > 0 ? NumberFormat.tokens(n.tokens) : nil, detail: detail, detailTone: detailTone, quiet: quiet)
    }

    /// The note that matters for the node's state, and its tone.
    /// `limitWarning` is the run's warning, which names the limit.
    func note(_ n: TaskNode, limitWarning: String? = nil) -> (String?, RunTone) {
        switch n.state {
        case .waiting:
            switch n.waitReason ?? .dependency {
            case .input: return (n.waitNote ?? "Needs your input", .alert)
            case .limit: return (n.waitNote ?? Self.limitWords(limitWarning), .warn)
            case .dependency: return (n.waitNote ?? "Waiting on another task", .neutral)
            }
        case .failed: return (n.failure ?? "Failed", n.importance == .optional ? .warn : .alert)
        case .partial: return (n.failure ?? "Finished with failures", .warn)
        case .running where n.stale:
            let quiet = "Quiet for \(TimeFormat.compact(now.timeIntervalSince(n.lastActivityAt ?? now)))"
            return (n.note.map { quiet + " · " + $0 } ?? quiet, .warn)
        case .running: return (n.note, .quiet)
        case .parked: return (n.note ?? "Paused with work left", .quiet)
        case .done: return (n.evidence ?? n.note, .quiet)
        case .cancelled: return (n.failure ?? "Cancelled", .quiet)
        case .skipped: return (n.note ?? "Skipped", .quiet)
        case .planned: return (n.note, .quiet)
        }
    }

    static func look(_ n: TaskNode) -> (RunGlyph, RunTone) {
        switch n.state {
        case .planned: (.planned, .quiet)
        case .running where n.stale: (.stale, .warn)
        case .running: (.running, .progress)
        case .waiting where n.waitReason == .input: (.needsInput, .alert)
        case .waiting where n.waitReason == .limit: (.waiting, .warn)
        case .waiting: (.waiting, .neutral)
        case .parked: (.parked, .quiet)
        case .done: (.done, .neutral)
        case .partial: (.partial, .warn)
        case .failed: (.failed, n.importance == .optional ? .warn : .alert)
        case .skipped, .cancelled: (.skipped, .quiet)
        }
    }
}
