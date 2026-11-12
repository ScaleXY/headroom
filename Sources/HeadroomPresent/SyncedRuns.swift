import Foundation
import HeadroomKit

// Runs as the iPhone, iPad and Watch know them: what a Mac synced (structure and state, names only
// when the Mac shares them), turned into the same cards and words the Mac's Runs tab uses.

/// A run's work counted by state: a declared plan's leaves, or every agent of an observed run
/// (the compacted ones as done). The finished share is what the observed headline counts.
public struct RunCounts: Codable, Sendable, Hashable {
    public var running: Int
    public var needsInput: Int
    /// Waiting on a limit or on another task.
    public var waiting: Int
    /// Failed, or finished with failures.
    public var failed: Int
    /// Done, skipped or cancelled.
    public var done: Int
    /// Planned, or paused with work left.
    public var planned: Int

    public init(running: Int = 0, needsInput: Int = 0, waiting: Int = 0, failed: Int = 0, done: Int = 0, planned: Int = 0) {
        self.running = running; self.needsInput = needsInput; self.waiting = waiting; self.failed = failed; self.done = done; self.planned = planned
    }

    /// Missing counts read as zero, so a newer or older writer never drops the run.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ k: CodingKeys) -> Int { max(0, ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? 0) }
        self.init(running: n(.running), needsInput: n(.needsInput), waiting: n(.waiting), failed: n(.failed), done: n(.done), planned: n(.planned))
    }

    public var total: Int { running + needsInput + waiting + failed + done + planned }
    public var finished: Int { failed + done }

    public static func of(_ r: TaskRun) -> RunCounts {
        var c = RunCounts()
        for n in r.nodes where !r.hasDeclaredTasks || n.leaf {
            switch n.state {
            case .running: c.running += 1
            case .waiting where n.waitReason == .input: c.needsInput += 1
            case .waiting: c.waiting += 1
            case .failed, .partial: c.failed += 1
            case .done, .skipped, .cancelled: c.done += 1
            case .planned, .parked: c.planned += 1
            }
        }
        if !r.hasDeclaredTasks { c.done += r.finishedEarlier ?? 0 }
        return c
    }

    /// "3 running · 1 needs input · 12 done": every state with work in it.
    public var line: String {
        [(running, "running"), (needsInput, "needs input"), (waiting, "waiting"), (failed, "failed"), (done, "done"), (planned, "planned")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

/// One run as a reader knows it: what its Mac synced, and whether that Mac is still around.
public struct RunDigest: Sendable, Hashable, Identifiable {
    /// One of the run's most pressing rows, synced only when the Mac includes task names.
    public struct Row: Sendable, Hashable {
        public var title: String
        public var state: TaskState
        public var waitReason: TaskWaitReason?
        public var stale: Bool
        /// 0…2, as the Mac shows it.
        public var depth: Int
        /// Declared steps, or finished of the work rolled into this row.
        public var steps: TaskSteps?
        public var importance: TaskImportance
        /// Doesn't count toward the run.
        public var quiet: Bool

        public init(title: String, state: TaskState, waitReason: TaskWaitReason? = nil, stale: Bool = false, depth: Int = 0, steps: TaskSteps? = nil,
                    importance: TaskImportance = .normal, quiet: Bool = false) {
            self.title = title; self.state = state; self.waitReason = waitReason; self.stale = stale; self.depth = depth; self.steps = steps
            self.importance = importance; self.quiet = quiet
        }
    }

    /// The Mac's device ID and the run's hashed ID: unique across Macs.
    public var id: String
    /// The Mac's computer name.
    public var mac: String
    public var harness: String?
    public var state: TaskRunState
    public var waitReason: TaskWaitReason?
    public var stale: Bool
    public var progress: TaskProgress
    public var mustHaves: TaskMustHaves
    public var etaSeconds: Double?
    public var tokens: Int64
    /// The limit warning, which names only the provider and times.
    public var warning: String?
    public var hasDeclaredTasks: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var counts: RunCounts
    /// The agent's title for the run; nil unless the Mac includes task names (and never the project).
    public var title: String?
    /// The most pressing rows; nil unless the Mac includes task names.
    public var rows: [Row]?
    /// Rows past the ones synced.
    public var moreRows: Int
    /// Finished rows the Mac folds into "N finished".
    public var finishedRows: Int
    /// Finished agents compacted away on the Mac.
    public var finishedEarlier: Int
    /// When the Mac was last heard from, set when it went quiet (asleep, quit, or no heartbeat)
    /// with this run still live: nobody knows how it's going since.
    public var lastSeen: Date?

    public init(id: String, mac: String, harness: String? = nil, state: TaskRunState, waitReason: TaskWaitReason? = nil, stale: Bool = false,
                progress: TaskProgress = .zero, mustHaves: TaskMustHaves = TaskMustHaves(done: 0, total: 0), etaSeconds: Double? = nil, tokens: Int64 = 0,
                warning: String? = nil, hasDeclaredTasks: Bool, startedAt: Date, updatedAt: Date, counts: RunCounts = RunCounts(), title: String? = nil,
                rows: [Row]? = nil, moreRows: Int = 0, finishedRows: Int = 0, finishedEarlier: Int = 0, lastSeen: Date? = nil) {
        self.id = id; self.mac = mac; self.harness = harness; self.state = state; self.waitReason = waitReason; self.stale = stale
        self.progress = progress; self.mustHaves = mustHaves; self.etaSeconds = etaSeconds; self.tokens = tokens; self.warning = warning
        self.hasDeclaredTasks = hasDeclaredTasks; self.startedAt = startedAt; self.updatedAt = updatedAt; self.counts = counts; self.title = title
        self.rows = rows; self.moreRows = moreRows; self.finishedRows = finishedRows; self.finishedEarlier = finishedEarlier; self.lastSeen = lastSeen
    }

    /// Unfinished, on a Mac that's still heard from.
    public var isLive: Bool { !state.isTerminal && lastSeen == nil }
    public var needsInput: Bool { isLive && state == .waiting && waitReason == .input }
    public var includesNames: Bool { rows != nil }
    public var attention: TaskAttention { TaskAttention(run: state, waitReason: waitReason, stale: stale) }
}

/// What a phone notification about a run says.
public struct RunAlertCopy: Sendable, Hashable {
    public var title: String
    public var body: String
}

extension RunsPresenter {
    /// The rows a Mac syncs when it includes task names: the first `cap` of what its Runs tab
    /// lists (pressing work first, finished work folded), how many more there were, and how many
    /// finished rows the "N finished" line stands for.
    public func digestRows(_ r: TaskRun, cap: Int) -> (rows: [RunDigest.Row], more: Int, finished: Int) {
        let l = layout(r, expanded: false)
        let rows = l.visible.prefix(cap).map { v -> RunDigest.Row in
            let n = r.nodes[v.node]
            var steps = n.leaf ? n.steps : nil
            if steps == nil, v.depth == Self.maxDepth {
                let rolled = descendants(v.node, r.nodes, l.children)
                if !rolled.isEmpty { steps = TaskSteps(done: rolled.filter(\.state.isTerminal).count, total: rolled.count) }
            }
            return RunDigest.Row(title: n.title, state: n.state, waitReason: n.waitReason, stale: n.stale, depth: v.depth, steps: steps,
                                 importance: n.importance, quiet: !n.counted || n.state == .skipped || n.state == .cancelled)
        }
        return (rows, max(0, l.visible.count - cap), l.finished)
    }

    /// Synced runs as the Runs section shows them: live ones in the order given (most pressing
    /// first), then the last day's finished ones, newest first. A run whose Mac went quiet stays
    /// with the live ones, marked as last seen.
    public func page(_ digests: [RunDigest]) -> RunsPageModel {
        let shown = digests.filter { now.timeIntervalSince($0.updatedAt) < Self.recentWindow }
        let live = shown.filter { !$0.state.isTerminal }
        let finished = shown.filter(\.state.isTerminal).sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let recent = Array(finished.prefix(Self.recentCap))
        var counts: [String: Int] = [:]
        for d in live + recent { counts[baseTitle(d), default: 0] += 1 }
        func make(_ d: RunDigest) -> RunCardModel { card(d, sayStart: (counts[baseTitle(d)] ?? 0) > 1) }
        return RunsPageModel(live: live.map(make), recent: recent.map(make), moreRecent: finished.count - recent.count)
    }

    /// The Mac's card for a synced run. Without names the title is "Run on <Mac>" and the rows are
    /// one line of counts; notes, failure reasons and evidence never sync, so rows say only their
    /// state's plain words.
    public func card(_ d: RunDigest, sayStart: Bool = false) -> RunCardModel {
        let declared = d.hasDeclaredTasks
        let quiet = d.lastSeen != nil && !d.state.isTerminal
        var (glyph, tone) = Self.look(asRun(d))
        if quiet { (glyph, tone) = (.stopped, .quiet) }
        var figures: [String] = []
        let headline: String
        var estimate: String?
        if declared {
            headline = "\(percent(d.progress.done))%"
            if percent(d.progress.estimate) > percent(d.progress.done) { estimate = "~\(percent(d.progress.estimate))%" }
            if d.mustHaves.total > 0 { figures.append("must-haves \(d.mustHaves.done) of \(d.mustHaves.total)") }
            if let eta = d.etaSeconds, !quiet { figures.append("about \(TimeFormat.compact(eta)) left") }
        } else {
            let (finished, total) = (d.counts.finished, d.counts.total)
            headline = total == 0 ? "No agents yet" : "\(finished) of \(total) agent\(total == 1 ? "" : "s") finished"
            if d.counts.running > 0, !quiet { figures.append("\(d.counts.running) running") }
            if d.counts.failed > 0 { figures.append("\(d.counts.failed) failed") }
        }
        if d.tokens > 0 { figures.append("\(NumberFormat.tokens(d.tokens)) tokens") }
        return RunCardModel(id: d.id, title: displayTitle(d, sayStart: sayStart), subtitle: subtitle(d), stateText: stateText(d), glyph: glyph,
                            tone: tone, live: !d.state.isTerminal, declared: declared, needsInput: d.needsInput,
                            provider: TaskLimits.provider(named: d.harness), bar: declared ? d.progress : nil, headline: headline,
                            estimate: estimate, figures: figures, warning: quiet ? nil : d.warning, rows: rows(d))
    }

    public func displayTitle(_ d: RunDigest, sayStart: Bool = false) -> String {
        let base = baseTitle(d)
        return sayStart ? base + " · " + TimeFormat.shortDayTime(d.startedAt, now: now, calendar: calendar, locale: locale) : base
    }

    func baseTitle(_ d: RunDigest) -> String { d.title ?? "Run on \(d.mac)" }

    /// The Mac (unless the title already names it), what ran it, and how long ago it moved.
    func subtitle(_ d: RunDigest) -> String {
        var parts: [String] = []
        if d.title != nil { parts.append(d.mac) }
        if let h = Self.harnessName(d.harness) { parts.append(h) }
        let age = TimeFormat.freshness(since: d.updatedAt, now: now)
        let ago = age == "now" ? "just now" : "\(age) ago"
        parts.append(d.state.isTerminal ? "finished \(ago)" : "updated \(ago)")
        return parts.joined(separator: " · ")
    }

    /// The Mac's state words; "Last seen 2h ago" once its Mac went quiet mid-run.
    public func stateText(_ d: RunDigest) -> String {
        if let seen = d.lastSeen, !d.state.isTerminal {
            let age = TimeFormat.freshness(since: seen, now: now)
            return age == "now" ? "Last seen just now" : "Last seen \(age) ago"
        }
        return stateText(asRun(d))
    }

    /// The fields the Mac's state words read, so both say exactly the same.
    func asRun(_ d: RunDigest) -> TaskRun {
        TaskRun(id: d.id, title: d.id, harness: d.harness, startedAt: d.startedAt, updatedAt: d.updatedAt, state: d.state, waitReason: d.waitReason,
                stale: d.stale, progress: d.progress, mustHaves: d.mustHaves, etaSeconds: d.etaSeconds, tokens: d.tokens, warning: d.warning,
                hasDeclaredTasks: d.hasDeclaredTasks)
    }

    /// Named rows as the Mac lists them (capped, then "and N more", "N finished", "finished
    /// earlier"), or the counts line.
    func rows(_ d: RunDigest) -> [RunRowModel] {
        guard let synced = d.rows else {
            guard d.counts.total > 0 else { return [] }
            let worst: (RunGlyph, RunTone) =
                d.counts.needsInput > 0 && d.lastSeen == nil ? (.needsInput, .alert)
                : d.counts.failed > 0 ? (.failed, .alert)
                : d.counts.running > 0 && d.lastSeen == nil ? (.running, .progress)
                : (.done, .quiet)
            return [RunRowModel(id: "~counts", kind: .counts, glyph: worst.0, tone: worst.1, title: d.counts.line)]
        }
        var out = synced.prefix(Self.rowCap).enumerated().map { i, row -> RunRowModel in
            let node = TaskNode(id: "\(i)", title: row.title, depth: row.depth, state: row.state, waitReason: row.waitReason, stale: row.stale,
                                importance: row.importance)
            let (glyph, tone) = Self.look(node)
            // Notes don't sync: a row that needs looking at says so in its state's plain words.
            var detail: String?, detailTone = RunTone.quiet
            if [.waiting, .failed, .partial].contains(row.state) { (detail, detailTone) = note(node, limitWarning: d.warning) }
            return RunRowModel(id: "\(i)", glyph: glyph, tone: row.quiet && tone != .alert ? .quiet : tone, depth: min(row.depth, Self.maxDepth),
                               title: row.title, marker: row.importance == .normal ? nil : row.importance.rawValue,
                               steps: row.steps.map { "\($0.done)/\($0.total)" }, detail: detail, detailTone: detailTone, quiet: row.quiet)
        }
        let more = synced.count - min(synced.count, Self.rowCap) + d.moreRows
        if more > 0 { out.append(RunRowModel(id: "~more", kind: .more(more), glyph: .more, tone: .quiet, title: "and \(more) more")) }
        if d.finishedRows > 0 {
            out.append(RunRowModel(id: "~finished", kind: .finished(count: d.finishedRows, expanded: false), glyph: .done, tone: .quiet,
                                   title: "\(d.finishedRows) finished"))
        }
        if d.finishedEarlier > 0 {
            out.append(RunRowModel(id: "~earlier", kind: .earlier(d.finishedEarlier), glyph: .done, tone: .quiet, title: "+ \(d.finishedEarlier) finished earlier"))
        }
        return out
    }

    /// "42%" for a declared run, "7/9" agents otherwise: the compact figure for the watch and
    /// the Live Activity.
    public func shortFigure(_ d: RunDigest) -> String {
        d.hasDeclaredTasks ? "\(percent(d.progress.done))%" : "\(d.counts.finished)/\(d.counts.total)"
    }

    /// The line under a compact title: the Mac, or what ran it when the title already names the Mac.
    public func source(_ d: RunDigest) -> String {
        d.title == nil ? (Self.harnessName(d.harness) ?? "Agent run") : d.mac
    }

    // MARK: Alerts

    /// A run on a Mac that now waits for an answer.
    public func needsInputAlert(_ d: RunDigest) -> RunAlertCopy {
        RunAlertCopy(title: "\(baseTitle(d)) needs your input",
                     body: d.title == nil ? "An agent is waiting for your answer." : "An agent on \(d.mac) is waiting for your answer.")
    }

    /// A run that finished, failed or finished with failures.
    public func finishedAlert(_ d: RunDigest) -> RunAlertCopy {
        let what = switch d.state {
        case .failed: "failed"
        case .partial: "finished with failures"
        default: "finished"
        }
        var facts: [String] = []
        if d.hasDeclaredTasks {
            facts.append("\(percent(d.progress.done))% done")
            if d.mustHaves.total > 0 { facts.append("must-haves \(d.mustHaves.done) of \(d.mustHaves.total)") }
        } else if d.counts.total > 0 {
            facts.append(d.counts.line)
        }
        if d.tokens > 0 { facts.append("\(NumberFormat.tokens(d.tokens)) tokens") }
        let body = (d.title == nil ? "" : "On \(d.mac). ") + facts.joined(separator: " · ")
        return RunAlertCopy(title: "\(baseTitle(d)) \(what)", body: body.isEmpty ? "On \(d.mac)." : body)
    }
}
