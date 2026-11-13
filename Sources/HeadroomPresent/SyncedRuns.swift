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
        // A declared plan counts what the Mac's card counts: leaves that count toward the run.
        for n in r.nodes where !r.hasDeclaredTasks || (n.leaf && n.counted) {
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

    /// One block of the task map: a counted leaf (or a few, when the plan is long). Structure only.
    public struct Segment: Sendable, Hashable {
        /// Share of the run; a card's weights sum to 1.
        public var weight: Double
        /// How far along, 0…1.
        public var fill: Double
        public var state: TaskState
        public var waitReason: TaskWaitReason?
        public var stale: Bool
        public var importance: TaskImportance

        public init(weight: Double, fill: Double, state: TaskState, waitReason: TaskWaitReason? = nil, stale: Bool = false,
                    importance: TaskImportance = .normal) {
            self.weight = weight; self.fill = fill; self.state = state; self.waitReason = waitReason; self.stale = stale; self.importance = importance
        }
    }

    /// The question a run waits on. Synced only when the Mac shares task names and question wording.
    public struct Question: Sendable, Hashable {
        public var text: String
        public var options: [String]
        /// The title of the task asking; nil when the orchestrator asked.
        public var asker: String?

        public init(text: String, options: [String] = [], asker: String? = nil) { self.text = text; self.options = options; self.asker = asker }
    }

    /// What a finished run's receipt is built from.
    public struct Receipt: Sendable, Hashable {
        /// Start to finish.
        public var seconds: Double
        /// Tokens by model, for pricing.
        public var tokensByModel: [String: Int64]
        public var time: TaskTimeSplit
        /// Failed tasks that were optional.
        public var optionalFailed: Int
        /// Tasks added, or efforts changed, after the run started.
        public var scopeChanges: Int
        public var retries: Int

        public init(seconds: Double, tokensByModel: [String: Int64] = [:], time: TaskTimeSplit = .zero, optionalFailed: Int = 0, scopeChanges: Int = 0,
                    retries: Int = 0) {
            self.seconds = seconds; self.tokensByModel = tokensByModel; self.time = time; self.optionalFailed = optionalFailed
            self.scopeChanges = scopeChanges; self.retries = retries
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

    // From the second pass on task tracking. Older Macs leave every one of these empty.

    /// The task map, in plan order.
    public var segments: [Segment] = []
    /// The forecast finish, and its range, as clock times (not seconds from the last event).
    public var finishAt: Date?
    public var finishLow: Date?
    public var finishHigh: Date?
    /// Seconds of work so far (waits on a person or a limit left out).
    public var workingSeconds: Double?
    /// The plan comes from the harness's own plan list.
    public var mirrored = false
    /// A person gave up on the run.
    public var abandoned = false
    /// How the run sits against its provider's 5-hour window, while live.
    public var limit: TaskLimitOutlook?
    /// Finished runs only.
    public var receipt: Receipt?
    /// What the receipt's tokens cost, in dollars, when the reader could price them.
    public var cost: Double?
    /// What the run asks, while it needs input and the Mac shares the wording.
    public var question: Question?
    /// When the Mac's user last touched it; sent while a run waits on input.
    public var macActiveAt: Date?

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
    /// Stopped with work left, on a Mac still heard from, and nobody gave up on it.
    public var stoppedWithWorkLeft: Bool { state == .stopped && lastSeen == nil && !abandoned }
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
    /// with the live ones, marked as last seen. `expanded` cards list every row synced.
    public func page(_ digests: [RunDigest]) -> RunsPageModel { page(digests, expanded: []) }

    /// The same, with `expanded` cards listing every synced row. (No default here: `page([])`
    /// must keep meaning the Mac's own runs.)
    public func page(_ digests: [RunDigest], expanded: Set<String>) -> RunsPageModel {
        let shown = digests.filter { now.timeIntervalSince($0.updatedAt) < Self.recentWindow }
        let live = shown.filter { !$0.state.isTerminal }
        let finished = shown.filter(\.state.isTerminal).sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let recent = Array(finished.prefix(Self.recentCap))
        var counts: [String: Int] = [:]
        for d in live + recent { counts[baseTitle(d), default: 0] += 1 }
        func make(_ d: RunDigest) -> RunCardModel { card(d, expanded: expanded.contains(d.id), sayStart: (counts[baseTitle(d)] ?? 0) > 1) }
        return RunsPageModel(live: live.map(make), recent: recent.map(make), moreRecent: finished.count - recent.count)
    }

    /// The Mac's card for a synced run. Without names the title is "Run on <Mac>" and the rows are
    /// one line of counts; notes, failure reasons and evidence never sync, so rows say only their
    /// state's plain words.
    public func card(_ d: RunDigest, expanded: Bool = false, sayStart: Bool = false) -> RunCardModel {
        let declared = d.hasDeclaredTasks || d.mirrored
        let quiet = d.lastSeen != nil && !d.state.isTerminal
        var (glyph, tone) = Self.look(asRun(d))
        if quiet || d.abandoned { (glyph, tone) = (.stopped, .quiet) }
        var figures: [String] = []
        let headline: String
        if declared {
            // One number, the best guess of how far along it is, as the Mac shows it.
            headline = "\(headlinePercent(d))%"
            if d.mustHaves.total > 0 { figures.append("must-haves \(d.mustHaves.done) of \(d.mustHaves.total)") }
            if !quiet, let eta = syncedEstimate(d) { figures.append(eta) }
        } else {
            let (finished, total) = (d.counts.finished, d.counts.total)
            headline = total == 0 ? "No agents yet" : "\(finished) of \(total) agent\(total == 1 ? "" : "s") finished"
            if d.counts.running > 0, !quiet { figures.append("\(d.counts.running) running") }
            if d.counts.failed > 0 { figures.append("\(d.counts.failed) failed") }
        }
        if d.tokens > 0 { figures.append("\(NumberFormat.tokens(d.tokens)) tokens") }
        let built = rows(d, expanded: expanded)
        var card = RunCardModel(id: d.id, title: displayTitle(d, sayStart: sayStart), subtitle: subtitle(d), stateText: stateText(d), glyph: glyph,
                            tone: tone, live: !d.state.isTerminal, declared: declared, needsInput: d.needsInput,
                            provider: TaskLimits.provider(named: d.harness), bar: declared ? d.progress : nil, headline: headline,
                            estimate: nil, figures: figures, warning: quiet ? nil : d.warning, rows: built.rows,
                            expandable: built.expandable, expanded: expanded && built.expandable,
                            segments: syncedSegments(d), counts: syncedCounts(d, quiet: quiet), elapsed: syncedElapsed(d, quiet: quiet),
                            question: syncedQuestion(d), timeline: quiet ? nil : syncedTimeline(d), receipt: syncedReceipt(d))
        card.hero = syncedHero(d, quiet: quiet)
        card.verdict = syncedVerdict(d, quiet: quiet, timeline: card.timeline != nil)
        card.rowsTitle = !declared ? "Agents" : d.mirrored ? "Steps" : "Tasks"
        return card
    }

    /// The hero as the Mac's card has it: the percent (or agents finished) and the time left as
    /// a clock, else the time spent.
    func syncedHero(_ d: RunDigest, quiet: Bool) -> RunHeroModel {
        let declared = d.hasDeclaredTasks || d.mirrored
        func clock(_ date: Date) -> String { TimeFormat.clock(date, calendar: calendar, locale: locale) }
        var side: String?, caption: String?, hourglass = false
        if d.state.isTerminal {
            let s = d.receipt?.seconds ?? d.updatedAt.timeIntervalSince(d.startedAt)
            side = Self.duration(s); caption = "start to finish"
        } else if declared, !quiet, d.state == .running, !d.stale, let finish = d.limit?.finishAt ?? d.finishAt, finish > now {
            let low = d.limit?.finishAt == nil ? d.finishLow : nil, high = d.limit?.finishAt == nil ? d.finishHigh : nil
            side = "~" + TimeFormat.compact(finish.timeIntervalSince(now))
            if let low, let high, clock(low) != clock(high) { caption = "done " + Self.clockRange(clock(low), clock(high)) } else { caption = "done ~" + clock(finish) }
            hourglass = true
        } else if let w = d.workingSeconds, w >= 60, !quiet {
            side = Self.duration(w); caption = "working"
        }
        if declared {
            let pct = headlinePercent(d)
            return RunHeroModel(number: "\(pct)", unit: "%", label: syncedCounts(d, quiet: quiet) ?? "done", side: side, sideCaption: caption,
                                hourglass: hourglass, fraction: Double(pct) / 100)
        }
        let (finished, total) = (d.counts.finished, d.counts.total)
        let label = total == 0 ? "no agents yet" : "agent\(total == 1 ? "" : "s") finished" + (d.counts.running > 0 && !quiet && !d.state.isTerminal ? " · \(d.counts.running) running" : "")
        return RunHeroModel(number: "\(finished)", unit: "/\(total)", label: label, side: side, sideCaption: caption, hourglass: hourglass,
                            fraction: total > 0 ? Double(finished) / Double(total) : 0)
    }

    /// The sentence under the badge, from what the Mac shared: what's running when names are on.
    func syncedVerdict(_ d: RunDigest, quiet: Bool, timeline: Bool) -> RunVerdictModel {
        let figure = d.tokens > 0 ? "\(NumberFormat.tokens(d.tokens)) tokens" : nil
        let noun = d.mirrored ? "steps" : "tasks"
        let open = d.counts.total - d.counts.finished
        var primary: String?
        if d.abandoned {
            primary = open > 0 ? "Given up with \(open) \(open == 1 ? "task" : "tasks") open." : "Given up."
        } else if let seen = d.lastSeen, !d.state.isTerminal {
            primary = "\(d.mac) stopped syncing \(TimeFormat.freshness(since: seen, now: now)) ago, so this may be out of date."
        } else {
            switch d.state {
            case .running where d.stale: primary = "No activity for \(TimeFormat.compact(now.timeIntervalSince(d.updatedAt)))."
            case .running:
                let running = (d.rows ?? []).filter { $0.state == .running }
                if let first = running.first {
                    primary = "Working on \(first.title)" + (running.count > 1 ? " and \(running.count - 1) more." : ".")
                } else if d.counts.running > 0 {
                    primary = "\(d.counts.running) \(d.counts.running == 1 ? "task" : "tasks") running."
                }
            case .waiting:
                switch d.waitReason ?? .dependency {
                case .input: primary = nil
                case .limit: primary = timeline ? nil : d.warning
                case .dependency: primary = RunWords.waitingOnTask + "."
                }
            case .stopped: primary = "\(open) \(open == 1 ? "task" : "tasks") left. Pick it up on \(d.mac)."
            case .done:
                let opt = d.receipt?.optionalFailed ?? 0
                primary = opt > 0 ? "Everything that counts is done; \(opt) optional \(opt == 1 ? "task" : "tasks") failed."
                    : (d.hasDeclaredTasks || d.mirrored) ? "All \(d.counts.total) \(noun) done." : "Every agent finished."
            case .partial, .failed:
                primary = "\(d.counts.failed) \(d.counts.failed == 1 ? "task" : "tasks") failed."
            }
        }
        var secondary: [String] = []
        if !d.state.isTerminal {
            if d.mirrored { secondary.append(RunWords.fromSessionPlan) }
            if d.mustHaves.total > 0 { secondary.append("must-haves \(d.mustHaves.done) of \(d.mustHaves.total)") }
        }
        let s = secondary.joined(separator: " · ")
        return RunVerdictModel(figure: figure, primary: primary, secondary: s.isEmpty ? nil : s.prefix(1).uppercased() + s.dropFirst())
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

    /// The Mac's state words; "Mac last seen 2h ago" once its Mac went quiet mid-run.
    public func stateText(_ d: RunDigest) -> String {
        if d.abandoned { return RunWords.abandoned }
        if let seen = d.lastSeen, !d.state.isTerminal {
            let age = TimeFormat.freshness(since: seen, now: now)
            return RunWords.macLastSeen(age == "now" ? "1m" : age)
        }
        return stateText(asRun(d))
    }

    /// The fields the Mac's state words read, so both say exactly the same.
    func asRun(_ d: RunDigest) -> TaskRun {
        TaskRun(id: d.id, title: d.id, harness: d.harness, startedAt: d.startedAt, updatedAt: d.updatedAt, state: d.state, waitReason: d.waitReason,
                stale: d.stale, progress: d.progress, mustHaves: d.mustHaves, etaSeconds: d.etaSeconds, tokens: d.tokens, warning: d.warning,
                hasDeclaredTasks: d.hasDeclaredTasks, abandoned: d.abandoned, mirrored: d.mirrored)
    }

    /// Named rows as the Mac lists them (capped, then "and N more", "N finished", "finished
    /// earlier"), or the counts line. Expanded, every synced row shows.
    func rows(_ d: RunDigest, expanded: Bool = false) -> (rows: [RunRowModel], expandable: Bool) {
        guard let synced = d.rows else {
            guard d.counts.total > 0 else { return ([], false) }
            let worst: (RunGlyph, RunTone) =
                d.counts.needsInput > 0 && d.lastSeen == nil ? (.needsInput, .alert)
                : d.counts.failed > 0 ? (.failed, .alert)
                : d.counts.running > 0 && d.lastSeen == nil ? (.running, .progress)
                : (.done, .quiet)
            return ([RunRowModel(id: "~counts", kind: .counts, glyph: worst.0, tone: worst.1, title: d.counts.line)], false)
        }
        let expandable = synced.count > Self.rowCap
        let cap = expanded && expandable ? synced.count : Self.rowCap
        var out = synced.prefix(cap).enumerated().map { i, row -> RunRowModel in
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
        let more = synced.count - min(synced.count, cap) + d.moreRows
        if more > 0 { out.append(RunRowModel(id: "~more", kind: .more(more), glyph: .more, tone: .quiet, title: "and \(more) more")) }
        if d.finishedRows > 0 {
            out.append(RunRowModel(id: "~finished", kind: .finished(count: d.finishedRows, expanded: false), glyph: .done, tone: .quiet,
                                   title: "\(d.finishedRows) finished"))
        }
        if d.finishedEarlier > 0 {
            out.append(RunRowModel(id: "~earlier", kind: .earlier(d.finishedEarlier), glyph: .done, tone: .quiet, title: "+ \(d.finishedEarlier) finished earlier"))
        }
        return (out, expandable)
    }

    // MARK: Second-pass card fields

    /// The task map: each synced block toned as the Mac tones a row in the same state.
    func syncedSegments(_ d: RunDigest) -> [RunSegment] {
        d.segments.map { s in
            let node = TaskNode(id: "", title: "", state: s.state, waitReason: s.waitReason, stale: s.stale, importance: s.importance)
            var tone = Self.look(node).1
            if d.lastSeen != nil, !s.state.isTerminal { tone = .quiet }
            return RunSegment(weight: s.weight, fill: min(max(s.fill, 0), 1), tone: tone, critical: s.importance == .critical)
        }
    }

    /// "5 of 11 tasks · 3 running" beside the percent (steps for a plan read off the harness).
    func syncedCounts(_ d: RunDigest, quiet: Bool) -> String? {
        guard d.hasDeclaredTasks || d.mirrored, d.counts.total > 0 else { return nil }
        let noun = d.mirrored ? "steps" : (d.counts.total == 1 ? "task" : "tasks")
        var s = "\(d.counts.done) of \(d.counts.total) \(noun)"
        if !quiet, !d.state.isTerminal, d.counts.running > 0 { s += " · \(d.counts.running) running" }
        return s
    }

    /// "1h 12m working" while live; "1h 42m" once finished, as the Mac's card has it.
    func syncedElapsed(_ d: RunDigest, quiet: Bool) -> String? {
        if d.state.isTerminal {
            let seconds = d.receipt?.seconds ?? d.updatedAt.timeIntervalSince(d.startedAt)
            return seconds >= 60 ? Self.duration(seconds) : nil
        }
        guard !quiet, let w = d.workingSeconds, w >= 60 else { return nil }
        return "\(Self.duration(w)) working"
    }

    /// Time left, from the absolute finish the Mac synced: "20–35m left" while the range is wide,
    /// "about 26m left" otherwise. Older Macs send seconds from the last event.
    func syncedEstimate(_ d: RunDigest) -> String? {
        guard !d.state.isTerminal else { return nil }
        if let lo = d.finishLow, let hi = d.finishHigh, hi > now {
            let a = TimeFormat.compact(lo.timeIntervalSince(now)), b = TimeFormat.compact(hi.timeIntervalSince(now))
            if a == b { return "about \(a) left" }
            if a.hasSuffix("m"), b.hasSuffix("m"), a != "<1m" { return "\(a.dropLast())–\(b) left" }
            return "\(a)–\(b) left"
        }
        if let f = d.finishAt { return f > now ? "about \(TimeFormat.compact(f.timeIntervalSince(now))) left" : nil }
        return d.etaSeconds.map { "about \(TimeFormat.compact($0)) left" }
    }

    /// The question, while the run needs you: its wording when the Mac shares it, else where to answer.
    func syncedQuestion(_ d: RunDigest) -> RunQuestionModel? {
        guard d.needsInput else { return nil }
        guard let q = d.question, !q.text.isEmpty else { return RunQuestionModel(asker: "", text: "Answer it on \(d.mac)") }
        return RunQuestionModel(asker: q.asker.map { "\($0) is asking" } ?? "The agent is asking", text: q.text, options: q.options)
    }

    /// Working until the window runs out, paused until it resets, then working to the finish.
    func syncedTimeline(_ d: RunDigest) -> RunTimelineModel? {
        guard !d.state.isTerminal, let l = d.limit, let pauseAt = l.pauseAt, let resumeAt = l.resumeAt, resumeAt > now else { return nil }
        let pause = max(pauseAt, now), resume = max(resumeAt, pause)
        let finish = l.finishAt ?? d.finishAt
        let end = max(finish ?? resume.addingTimeInterval(max(600, resume.timeIntervalSince(now) * 0.25)), resume)
        let span = end.timeIntervalSince(now)
        guard span > 0 else { return nil }
        func at(_ t: Date) -> Double { min(max(t.timeIntervalSince(now) / span, 0), 1) }
        func clock(_ t: Date) -> String { TimeFormat.shortClock(t, calendar: calendar, locale: locale) }
        var spans = [RunTimelineModel.Span(kind: .working, start: 0, end: at(pause)), RunTimelineModel.Span(kind: .paused, start: at(pause), end: at(resume))]
        if end > resume { spans.append(RunTimelineModel.Span(kind: .working, start: at(resume), end: 1)) }
        var ticks = [RunTimelineModel.Tick(label: "now", time: clock(now), at: 0)]
        // Already paused: the window ran out before now, so there's no tick for it.
        if pauseAt > now { ticks.append(RunTimelineModel.Tick(label: "window empty", time: clock(pause), at: at(pause))) }
        ticks.append(RunTimelineModel.Tick(label: "resets", time: clock(resume), at: at(resume)))
        if let finish { ticks.append(RunTimelineModel.Tick(label: "done", time: "~" + clock(finish), at: at(end), strong: true)) }
        var note: [String] = []
        if let share = l.share, share > 0 { note.append("Using \(Int((share * 100).rounded()))% of what \(l.provider.displayName) is spending now") }
        if let need = l.tokensNeeded, let room = l.roomTokens {
            note.append("needs about \(NumberFormat.tokens(need)) more tokens, the window has room for \(NumberFormat.tokens(room))")
        }
        return RunTimelineModel(spans: spans.filter { $0.end > $0.start }, ticks: ticks, note: note.isEmpty ? nil : note.joined(separator: " · "))
    }

    /// How long, how much, how it went and where the time went, once a run is finished.
    func syncedReceipt(_ d: RunDigest) -> RunReceiptModel? {
        guard d.state.isTerminal, let r = d.receipt else { return nil }
        let c = d.counts
        // Counts leave out what doesn't count toward the run; the receipt names failed optional work too.
        let optional = d.hasDeclaredTasks ? r.optionalFailed : 0
        let failed = c.failed + optional, total = c.total + optional
        var note = [d.hasDeclaredTasks ? (d.mirrored ? "steps" : "tasks") : "agents"]
        if failed > 0 { note.append(r.optionalFailed == failed ? "\(failed) optional failed" : "\(failed) failed") }
        var foot: [String] = []
        if r.scopeChanges > 0 { foot.append("Plan changed \(r.scopeChanges) time\(r.scopeChanges == 1 ? "" : "s") after it started") }
        if r.retries > 0 { foot.append("\(r.retries) retr\(r.retries == 1 ? "y" : "ies")") }
        return RunReceiptModel(duration: Self.duration(r.seconds), tokens: NumberFormat.tokens(d.tokens),
                               cost: d.cost.map { "about " + NumberFormat.dollars($0) },
                               tasks: "\(d.hasDeclaredTasks ? c.done : c.finished) of \(total)", tasksNote: note.joined(separator: " · "),
                               time: r.time, footnote: foot.isEmpty ? nil : foot.joined(separator: " · "))
    }

    /// The headline percent, as the Mac's card has it: the best guess of how far along the run is
    /// (`progress.estimate`), rounded down, and never 100 before the run is done.
    func headlinePercent(_ d: RunDigest) -> Int {
        let p = percent(d.progress.estimate)
        return d.state == .done ? p : min(p, 99)
    }

    /// "42%" for a declared run, "7/9" agents otherwise: the compact figure for the watch and
    /// the Live Activity.
    public func shortFigure(_ d: RunDigest) -> String {
        d.hasDeclaredTasks || d.mirrored ? "\(headlinePercent(d))%" : "\(d.counts.finished)/\(d.counts.total)"
    }

    /// The line under a compact title: the Mac, or what ran it when the title already names the Mac.
    public func source(_ d: RunDigest) -> String {
        d.title == nil ? (Self.harnessName(d.harness) ?? "Agent run") : d.mac
    }

    // MARK: Alerts

    /// A run on a Mac that now waits for an answer: the question when the Mac shares it, else
    /// where to answer it.
    public func needsInputAlert(_ d: RunDigest) -> RunAlertCopy {
        let body = d.question.map(\.text).flatMap { $0.isEmpty ? nil : $0 } ?? "Answer it on \(d.mac)"
        return RunAlertCopy(title: RunWords.alertNeedsInput(baseTitle(d)), body: body)
    }

    /// A run that finished, failed or finished with failures.
    public func finishedAlert(_ d: RunDigest) -> RunAlertCopy {
        let title = switch d.state {
        case .failed: RunWords.alertFailed(baseTitle(d))
        case .partial: RunWords.alertPartial(baseTitle(d))
        default: RunWords.alertFinished(baseTitle(d))
        }
        return RunAlertCopy(title: title, body: facts(d))
    }

    /// A run whose agent stopped with tasks still open.
    public func stoppedAlert(_ d: RunDigest) -> RunAlertCopy {
        RunAlertCopy(title: RunWords.alertStopped(baseTitle(d)), body: facts(d))
    }

    /// "On MacBook Pro. 46% done · must-haves 1 of 2 · 2.31M tokens".
    func facts(_ d: RunDigest) -> String {
        var facts: [String] = []
        if d.hasDeclaredTasks {
            facts.append("\(headlinePercent(d))% done")
            if d.mustHaves.total > 0 { facts.append("must-haves \(d.mustHaves.done) of \(d.mustHaves.total)") }
        } else if d.counts.total > 0 {
            facts.append(d.counts.line)
        }
        if d.tokens > 0 { facts.append("\(NumberFormat.tokens(d.tokens)) tokens") }
        let body = (d.title == nil ? "" : "On \(d.mac). ") + facts.joined(separator: " · ")
        return body.isEmpty ? "On \(d.mac)." : body
    }
}
