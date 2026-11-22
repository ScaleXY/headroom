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

/// One block of a run's task map: a counted leaf, as wide as its share of the run. Drawn in a row,
/// they replace the single bar, so a reader sees closed tasks, part-way tasks and untouched ones.
public struct RunSegment: Sendable, Hashable {
    /// The leaf's share of the run (the widths sum to 1 across a card's segments).
    public var weight: Double
    /// How far along the leaf is, 0…1 (1 when closed done).
    public var fill: Double
    public var tone: RunTone
    /// A must-have: drawn with a tick beneath it.
    public var critical: Bool
    public var title: String?
    /// The leaf failed: drawn in the failure treatment, never as "needs you" (`tone` is `.alert`
    /// for a failed must-have and for a question alike).
    public var failed: Bool

    public init(weight: Double, fill: Double, tone: RunTone, critical: Bool = false, title: String? = nil, failed: Bool = false) {
        self.weight = weight; self.fill = fill; self.tone = tone; self.critical = critical; self.title = title; self.failed = failed
    }
}

/// What a run is waiting on a person to answer, shown at the top of its card.
public struct RunQuestionModel: Sendable, Hashable {
    /// "Switch the queries over is asking", or "The agent is asking".
    public var asker: String
    public var text: String
    public var options: [String]

    public init(asker: String, text: String, options: [String] = []) { self.asker = asker; self.text = text; self.options = options }
}

/// A live run against its provider's 5-hour window: working, paused at the limit, working again.
public struct RunTimelineModel: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case working, paused }
    /// Spans along the track, as fractions 0…1 of its width.
    public struct Span: Sendable, Hashable {
        public var kind: Kind
        public var start: Double
        public var end: Double
        public init(kind: Kind, start: Double, end: Double) { self.kind = kind; self.start = start; self.end = end }
    }
    /// Labelled ticks: "now 1:40", "window empty 2:10", "resets 3:00", "done ~3:25".
    public struct Tick: Sendable, Hashable {
        public var label: String
        public var time: String
        public var at: Double
        public var strong: Bool
        public init(label: String, time: String, at: Double, strong: Bool = false) { self.label = label; self.time = time; self.at = at; self.strong = strong }
    }
    public var spans: [Span]
    public var ticks: [Tick]
    /// "Using 62% of what Claude is spending now · needs about 1.1M more tokens, the window has room for 0.6M".
    public var note: String?

    public init(spans: [Span], ticks: [Tick], note: String? = nil) { self.spans = spans; self.ticks = ticks; self.note = note }
}

/// A finished run's receipt: how long, how much, how it went, and where the time went.
public struct RunReceiptModel: Sendable, Hashable {
    /// "1h 42m"
    public var duration: String
    /// "296K"
    public var tokens: String
    /// "about $4.10", when the models are priced.
    public var cost: String?
    /// "4 of 5", and "tasks · 1 optional failed".
    public var tasks: String
    public var tasksNote: String
    /// Working, waiting on you, waiting on a limit, idle: seconds each, for a split bar.
    public var time: TaskTimeSplit
    /// "Plan grew by 2 tasks after it started · 1 retry".
    public var footnote: String?

    public init(duration: String, tokens: String, cost: String? = nil, tasks: String, tasksNote: String, time: TaskTimeSplit, footnote: String? = nil) {
        self.duration = duration; self.tokens = tokens; self.cost = cost; self.tasks = tasks; self.tasksNote = tasksNote; self.time = time; self.footnote = footnote
    }
}

/// What a person can do with a run from its card. The Mac acts on these; the phone shows none.
public struct RunActionSet: Sendable, Hashable {
    /// Bring the app hosting the session forward (the run knows its host or folder).
    public var openSession: Bool
    /// Copy a command that resumes the session in a terminal.
    public var copyResume: Bool
    public var hide: Bool
    /// Give up on a run that isn't finished.
    public var abandon: Bool

    public init(openSession: Bool = false, copyResume: Bool = false, hide: Bool = false, abandon: Bool = false) {
        self.openSession = openSession; self.copyResume = copyResume; self.hide = hide; self.abandon = abandon
    }
    public static let none = RunActionSet()
    public var any: Bool { openSession || copyResume || hide || abandon }
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
    /// The row opened: labelled lines ("Evidence", "Failed because", "Took") shown beneath it.
    /// Nil while closed; empty when there's nothing more to say.
    public var details: [RunDetailLine]?
    /// Has more to show when opened (a full note, evidence, failure, time, agents).
    public var opens: Bool

    public init(id: String, kind: Kind = .task, glyph: RunGlyph, tone: RunTone, depth: Int = 0, title: String, marker: String? = nil,
                steps: String? = nil, tokens: String? = nil, detail: String? = nil, detailTone: RunTone = .quiet, quiet: Bool = false,
                details: [RunDetailLine]? = nil, opens: Bool = false) {
        self.id = id; self.kind = kind; self.glyph = glyph; self.tone = tone; self.depth = depth; self.title = title; self.marker = marker
        self.steps = steps; self.tokens = tokens; self.detail = detail; self.detailTone = detailTone; self.quiet = quiet
        self.details = details; self.opens = opens
    }

    /// The finished summary row: clicking it shows or hides the finished rows.
    public var toggles: Bool { if case .finished = kind { true } else { false } }
}

/// The card's hero, as Pace has it: a big number with a raised unit and a label under it; on
/// the right a countdown or a duration with its caption.
public struct RunHeroModel: Sendable, Hashable {
    /// "62", or "7" agents.
    public var number: String
    /// "%", or "/9".
    public var unit: String
    /// "5 of 10 tasks · 3 running", "agents finished".
    public var label: String
    /// "~25m" left, "1h 6m" working, "1h 42m" start to finish.
    public var side: String?
    public var sideCaption: String?
    /// The side figure is time left (drawn with the hourglass, as Pace's renewal).
    public var hourglass: Bool
    /// How far along, 0…1, for a meter when there's no task map to draw.
    public var fraction: Double

    public init(number: String, unit: String, label: String, side: String? = nil, sideCaption: String? = nil, hourglass: Bool = false, fraction: Double = 0) {
        self.number = number; self.unit = unit; self.label = label; self.side = side; self.sideCaption = sideCaption; self.hourglass = hourglass
        self.fraction = fraction
    }
}

/// Under the meter: the state badge with a figure on its right, then a plain sentence and a
/// quieter one, as Pace's verdict.
public struct RunVerdictModel: Sendable, Hashable {
    /// "2.31M tokens".
    public var figure: String?
    /// "Working on Rewrite the routes and 2 more."
    public var primary: String?
    /// "Must-haves 2 of 3 · done around 2:40–3:00 PM at this rate."
    public var secondary: String?

    public init(figure: String? = nil, primary: String? = nil, secondary: String? = nil) {
        self.figure = figure; self.primary = primary; self.secondary = secondary
    }
}

/// A labelled line in an opened row.
public struct RunDetailLine: Sendable, Hashable {
    public var label: String
    public var value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
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
    /// The task map that replaces `bar` when there are counted leaves to draw.
    public var segments: [RunSegment]
    /// "5 of 11 tasks · 3 running", beside the percent.
    public var counts: String?
    /// "1h 12m working" (live) or how long it took (finished).
    public var elapsed: String?
    /// What it's asking, while it needs you.
    public var question: RunQuestionModel?
    /// Against the provider's window, while live and there's a forecast.
    public var timeline: RunTimelineModel?
    /// Finished runs only.
    public var receipt: RunReceiptModel?
    public var actions: RunActionSet
    /// The hero and verdict, for surfaces drawn in the Pace card's grammar.
    public var hero: RunHeroModel?
    public var verdict: RunVerdictModel?
    /// The rows' header: "Tasks", "Steps" for a session's own plan, "Agents" with nothing declared.
    public var rowsTitle = "Tasks"
    /// The run's own page: status line, facts, limit, grouped tasks and lanes.
    public var page: RunPageModel?
    /// The Mac a run synced from, on another Mac's Runs tab; nil for a run of this Mac's own.
    public var mac: String?

    public init(id: String, title: String, subtitle: String, stateText: String, glyph: RunGlyph, tone: RunTone, live: Bool, declared: Bool,
                needsInput: Bool = false, provider: Provider? = nil, bar: TaskProgress? = nil, headline: String, estimate: String? = nil,
                figures: [String] = [], warning: String? = nil, rows: [RunRowModel] = [], expandable: Bool = false, expanded: Bool = false,
                segments: [RunSegment] = [], counts: String? = nil, elapsed: String? = nil, question: RunQuestionModel? = nil,
                timeline: RunTimelineModel? = nil, receipt: RunReceiptModel? = nil, actions: RunActionSet = .none) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.stateText = stateText; self.glyph = glyph; self.tone = tone
        self.live = live; self.declared = declared; self.needsInput = needsInput; self.provider = provider; self.bar = bar
        self.headline = headline; self.estimate = estimate; self.figures = figures; self.warning = warning; self.rows = rows
        self.expandable = expandable; self.expanded = expanded
        self.segments = segments; self.counts = counts; self.elapsed = elapsed; self.question = question
        self.timeline = timeline; self.receipt = receipt; self.actions = actions
        self.hero = nil; self.verdict = nil
    }
}

/// The Runs tab: live runs first, then the ones that finished in the last day.
public struct RunsPageModel: Sendable, Hashable {
    public var live: [RunCardModel]
    public var recent: [RunCardModel]
    /// Finished runs of the last day past the ones shown.
    public var moreRecent: Int
    /// Every finished run of the last day is listed ("+ N more" was opened).
    public var allRecent: Bool

    public init(live: [RunCardModel] = [], recent: [RunCardModel] = [], moreRecent: Int = 0, allRecent: Bool = false) {
        self.live = live; self.recent = recent; self.moreRecent = moreRecent; self.allRecent = allRecent
    }

    public var isEmpty: Bool { live.isEmpty && recent.isEmpty }

    public static let emptyTitle = "No runs yet"
    public static let emptyBody = "Runs show up here while an agent works through a plan or spawns subagents. Connect Claude Code or Codex to see their questions, progress and a receipt for each run."
    public static let emptyAction = "Connect your agents"
    public static let recentTitle = "Finished in the last day"
}

/// The menu bar's run indicator: the most pressing live run's progress, and whether any needs you.
public struct RunsMenuBarModel: Sendable, Hashable {
    public var fraction: Double
    /// "42%", or "7/9" agents for a run with nothing declared.
    public var text: String
    public var needsInput: Bool
    public var spoken: String
    /// Live runs in all, so "46% · 3" can say the figure is one of several.
    public var liveCount: Int
    /// Runs waiting on you ("2 need you").
    public var needsInputCount: Int
    /// The run shown has gone quiet: show that instead of a stale percent.
    public var quiet: Bool

    public init(fraction: Double, text: String, needsInput: Bool, spoken: String, liveCount: Int = 1, needsInputCount: Int = 0, quiet: Bool = false) {
        self.fraction = fraction; self.text = text; self.needsInput = needsInput; self.spoken = spoken
        self.liveCount = liveCount; self.needsInputCount = needsInputCount; self.quiet = quiet
    }
}

// MARK: - Presenter

/// Turns folded runs into cards with every word resolved, for the Mac popover and the iPhone.
public struct RunsPresenter: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    /// Prices a finished run's receipt; nil leaves the cost out.
    public var pricing: PricingEngine?

    /// Rows per card before "and N more".
    public static let rowCap = 10
    public static let expandedRowCap = 40
    /// Deeper work is rolled into its ancestor at this depth.
    public static let maxDepth = 2
    /// Finished runs stay on the tab this long.
    public static let recentWindow: TimeInterval = 86400
    public static let recentCap = 4
    /// Finished runs listed once "+ N more" is opened.
    public static let recentExpandedCap = 24
    /// Past this many counted leaves the map would be hairlines: the three-part bar stands in.
    public static let maxSegments = 48

    public init(now: Date, calendar: Calendar = Display.calendar, locale: Locale = Display.locale, pricing: PricingEngine? = nil) {
        self.now = now; self.calendar = calendar; self.locale = locale; self.pricing = pricing
    }

    /// Finished, or given up on: it sits with the finished runs and shows a receipt.
    public static func isFinished(_ r: TaskRun) -> Bool { r.state.isTerminal || r.abandoned }

    /// The key of an opened row in `page(_:expanded:opened:allRecent:)`'s `opened`.
    public static func rowKey(run: String, row: String) -> String { run + "\u{1F}" + row }

    /// `runs` most pressing first (`sortedForDisplay`, as `AppModel.taskRuns` has them). `expanded`
    /// holds runs showing all their rows, `opened` rows showing their details (`rowKey`), and
    /// `allRecent` lists every finished run of the last day.
    public func page(_ runs: [TaskRun], expanded: Set<String> = [], opened: Set<String> = [], allRecent: Bool = false) -> RunsPageModel {
        // Hidden runs never show; a run waiting on you stays however long it has waited.
        let shown = runs.filter { r in
            !r.hidden && (now.timeIntervalSince(r.updatedAt) < Self.recentWindow || (!Self.isFinished(r) && r.needsInput))
        }
        let live = shown.filter { !Self.isFinished($0) }
        let finished = shown.filter(Self.isFinished).sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let recent = Array(finished.prefix(allRecent ? Self.recentExpandedCap : Self.recentCap))
        // Runs with the same name say when they started.
        var counts: [String: Int] = [:]
        for r in live + recent { counts[baseTitle(r), default: 0] += 1 }
        func make(_ r: TaskRun) -> RunCardModel {
            card(r, expanded: expanded.contains(r.id), sayStart: (counts[baseTitle(r)] ?? 0) > 1, opened: opened)
        }
        return RunsPageModel(live: live.map(make), recent: recent.map(make), moreRecent: finished.count - recent.count,
                             allRecent: allRecent && finished.count > Self.recentCap)
    }

    /// The indicator for the most pressing run that's running or waiting; nil when none is.
    public func menuBar(_ runs: [TaskRun]) -> RunsMenuBarModel? {
        let live = runs.filter { ($0.state == .running || $0.state == .waiting) && !$0.hidden && !$0.abandoned && $0.isActive(now: now) }
        guard let r = live.first else { return nil }
        let asking = live.filter(\.needsInput).count
        let quiet = r.state == .running && r.stale
        let name = displayTitle(r)
        let fraction: Double, figure: String, spokenFigure: String
        if r.hasDeclaredTasks {
            let pct = shownPercent(r)
            (fraction, figure, spokenFigure) = (max(r.progress.done, r.progress.estimate), "\(pct)%", "\(pct)% done.")
        } else {
            let (finished, total) = agentCounts(r)
            (fraction, figure, spokenFigure) = (total > 0 ? Double(finished) / Double(total) : 0, "\(finished)/\(total)", "\(finished) of \(total) agents finished.")
        }
        let quietFor = TimeFormat.compact(now.timeIntervalSince(r.updatedAt))
        let text = asking > 1 ? RunWords.needYou(asking) : quiet ? RunWords.quietShort(quietFor) : figure
        var spoken = "\(name): " + (quiet ? RunWords.quiet(quietFor) + "." : spokenFigure)
        if live.count > 1 { spoken += " " + RunWords.spokenLive(live.count) }
        if asking > 0 { spoken += " " + RunWords.spokenNeedInput(asking) }
        return RunsMenuBarModel(fraction: fraction, text: text, needsInput: asking > 0, spoken: spoken, liveCount: live.count,
                                needsInputCount: asking, quiet: quiet && asking < 2)
    }

    // MARK: Card

    public func card(_ r: TaskRun, expanded: Bool = false, sayStart: Bool = false, opened: Set<String> = []) -> RunCardModel {
        let declared = r.hasDeclaredTasks
        let finished = Self.isFinished(r)
        let (glyph, tone) = Self.look(r)
        var figures: [String] = []
        var headline: String
        var counts: String?
        var segments: [RunSegment] = []
        if declared {
            // The best guess, rounded down: the map beside it shows what it's made of.
            headline = "\(shownPercent(r))%"
            counts = self.counts(r, live: !finished)
            if r.mirrored { figures.append(RunWords.fromSessionPlan) }
            if r.mustHaves.total > 0 { figures.append("must-haves \(r.mustHaves.done) of \(r.mustHaves.total)") }
            if !finished, let eta = etaText(r) { figures.append(eta) }
            if !finished { segments = Self.segments(r) }
        } else {
            // No percent and no ETA: nobody knows how many more agents will come.
            let (done, total) = agentCounts(r)
            headline = total == 0 ? "No agents yet" : "\(done) of \(total) agent\(total == 1 ? "" : "s") finished"
            let running = r.nodes.filter { $0.state == .running }.count
            let failed = r.nodes.filter { $0.state == .failed }.count
            if running > 0 { figures.append("\(running) running") }
            if failed > 0 { figures.append("\(failed) failed") }
        }
        if r.tokens > 0 { figures.append("\(NumberFormat.tokens(r.tokens)) tokens") }
        let built = rows(r, expanded: expanded, opened: opened)
        let expandable = built.finished > 0 || built.pressing > Self.rowCap
        let timeline = finished ? nil : self.timeline(r)
        // A run given up on while it waited keeps its state, but asks nothing any more.
        let asking = r.needsInput && !r.abandoned
        var card = RunCardModel(id: r.id, title: displayTitle(r, sayStart: sayStart), subtitle: subtitle(r), stateText: stateText(r), glyph: glyph,
                            tone: tone, live: !finished, declared: declared, needsInput: asking,
                            provider: TaskLimits.provider(named: r.harness), bar: declared ? r.progress : nil, headline: headline,
                            estimate: nil, figures: figures, warning: timeline == nil ? r.warning : nil, rows: built.rows,
                            expandable: expandable, expanded: expanded && expandable,
                            segments: segments, counts: counts, elapsed: elapsed(r), question: asking ? question(r) : nil,
                            timeline: timeline, receipt: finished ? receipt(r) : nil, actions: Self.actions(r))
        card.hero = hero(r)
        card.verdict = verdict(r, timeline: timeline != nil)
        card.rowsTitle = !declared ? "Agents" : r.mirrored ? "Steps" : "Tasks"
        card.page = pageModel(r, showDone: expanded, opened: opened)
        return card
    }

    // MARK: Hero and verdict

    func hero(_ r: TaskRun) -> RunHeroModel {
        let finished = Self.isFinished(r)
        var side: String?, caption: String?, hourglass = false
        func clock(_ d: Date) -> String { TimeFormat.clock(d, calendar: calendar, locale: locale) }
        if finished {
            side = Self.duration(r.updatedAt.timeIntervalSince(r.startedAt)); caption = "start to finish"
        } else if !r.hasDeclaredTasks {
            // Nobody knows how many more agents will come: no forecast, only the time spent.
            if r.time.working >= 60 { side = Self.duration(r.time.working); caption = "working" }
        } else if let o = r.limitOutlook, let finish = o.finishAt, o.pauseAt != nil, finish > now, r.state == .running, !r.stale {
            // The window will pause it: the time left counts the pause.
            side = "~" + TimeFormat.compact(finish.timeIntervalSince(now)); caption = "done ~\(clock(finish))"; hourglass = true
        } else if r.state == .running, !r.stale, let lo = r.etaLowSeconds, let hi = r.etaHighSeconds, hi >= lo {
            let a = now.addingTimeInterval(Self.roundDown5(lo)), b = now.addingTimeInterval(Self.roundUp5(hi))
            side = "~" + TimeFormat.compact((lo + hi) / 2)
            caption = clock(a) == clock(b) ? "done ~\(clock(a))" : "done \(Self.clockRange(clock(a), clock(b)))"
            hourglass = true
        } else if r.state == .running, !r.stale, let eta = r.etaSeconds {
            side = "~" + TimeFormat.compact(eta); caption = "done ~\(clock(now.addingTimeInterval(eta)))"; hourglass = true
        } else if r.time.working >= 60 {
            side = Self.duration(r.time.working); caption = "working"
        }
        if r.hasDeclaredTasks {
            return RunHeroModel(number: "\(shownPercent(r))", unit: "%", label: counts(r, live: !finished).map { $0 } ?? "done",
                                side: side, sideCaption: caption, hourglass: hourglass, fraction: Double(shownPercent(r)) / 100)
        }
        let (done, total) = agentCounts(r)
        let running = r.nodes.filter { $0.state == .running }.count
        let label = total == 0 ? "no agents yet" : "agent\(total == 1 ? "" : "s") finished" + (running > 0 && !finished ? " · \(running) running" : "")
        return RunHeroModel(number: "\(done)", unit: "/\(total)", label: label, side: side, sideCaption: caption, hourglass: hourglass,
                            fraction: total > 0 ? Double(done) / Double(total) : 0)
    }

    /// "10:15–10:35 AM": one meridiem when both share it.
    static func clockRange(_ a: String, _ b: String) -> String {
        for suffix in [" AM", " PM"] where a.hasSuffix(suffix) && b.hasSuffix(suffix) { return String(a.dropLast(suffix.count)) + "–" + b }
        return a + "–" + b
    }

    /// What's happening, in a sentence; then the figures that matter for it.
    func verdict(_ r: TaskRun, timeline: Bool) -> RunVerdictModel {
        let figure = r.tokens > 0 ? "\(NumberFormat.tokens(r.tokens)) tokens" : nil
        let leaves = r.nodes.filter { $0.leaf && ($0.counted || !r.hasDeclaredTasks) }
        let open = leaves.filter { !$0.state.isTerminal }.count
        var primary: String?
        var secondary: [String] = []
        func working(_ nodes: [TaskNode]) -> String? {
            guard let first = nodes.first else { return nil }
            return "Working on \(first.title)" + (nodes.count > 1 ? " and \(nodes.count - 1) more." : ".")
        }
        if r.abandoned {
            primary = open > 0 ? "Given up with \(open) \(open == 1 ? "task" : "tasks") open." : "Given up."
        } else {
            switch r.state {
            case .running where r.stale:
                primary = "No activity for \(TimeFormat.compact(now.timeIntervalSince(r.updatedAt))). It may be waiting on something outside Headroom's view."
            case .running:
                primary = working(leaves.filter { $0.state == .running })
            case .waiting:
                switch r.waitReason ?? .dependency {
                case .input: primary = nil
                case .limit: primary = timeline ? nil : r.warning ?? RunWords.waitingOnLimit(r.warning) + "."
                case .dependency: primary = RunWords.waitingOnTask + "."
                }
            case .stopped:
                primary = "\(open) \(open == 1 ? "task" : "tasks") left. Open the session to pick it up, or mark the run abandoned."
            case .done:
                let optionalFailed = r.nodes.filter { $0.leaf && $0.importance == .optional && ($0.state == .failed || $0.state == .partial) }
                if let first = optionalFailed.first {
                    primary = "Everything that counts is done; \(first.title), which was optional, failed."
                } else {
                    primary = r.hasDeclaredTasks ? (leaves.count == 1 ? "Done." : "All \(leaves.count) \(r.mirrored ? "steps" : "tasks") done.") : "Every agent finished."
                }
            case .partial, .failed:
                let lost = leaves.filter { $0.state == .failed || $0.state == .partial }
                if let first = lost.first {
                    primary = "\(first.title) failed" + (lost.count > 1 ? ", and \(lost.count - 1) more." : ".")
                } else {
                    primary = RunWords.partial + "."
                }
            }
        }
        if !Self.isFinished(r) {
            if r.mirrored { secondary.append(RunWords.fromSessionPlan) }
            if r.mustHaves.total > 0 { secondary.append("must-haves \(r.mustHaves.done) of \(r.mustHaves.total)") }
        } else if let foot = receipt(r).footnote {
            secondary.append(foot)
        }
        // Failures worked around another way: said plainly, not as failures.
        let replaced = r.nodes.filter { $0.leaf && $0.replacedBy != nil }
        if let first = replaced.first {
            let next = Self.title(of: first.replacedBy!, in: r)
            secondary.insert(replaced.count == 1 ? "\(first.title) gave way to \(next)" : "\(replaced.count) approaches gave way to others", at: 0)
        }
        let s = secondary.joined(separator: " · ")
        return RunVerdictModel(figure: figure, primary: primary, secondary: s.isEmpty ? nil : s.prefix(1).uppercased() + s.dropFirst())
    }

    /// What the run is: the agent's declared title, else the title Claude Code or Codex gave the
    /// session. Where it runs (repo, folder, branch, Mac) goes in the subtitle, not here. Never
    /// the session id.
    public func displayTitle(_ r: TaskRun, sayStart: Bool = false) -> String {
        let base = baseTitle(r)
        return sayStart ? base + " · " + TimeFormat.shortDayTime(r.startedAt, now: now, calendar: calendar, locale: locale) : base
    }

    func baseTitle(_ r: TaskRun) -> String {
        r.bestTitle ?? Self.untitled(r.harness)
    }

    /// A run nobody named: what ran it ("run", not "session": that's the 5-hour window here).
    /// Runs with the same name say when they started.
    static func untitled(_ harness: String?) -> String {
        harnessName(harness).map { "\($0) run" } ?? "Agent run"
    }

    /// The run's name where nothing sits under it (a dialog, an alert, Recent runs): its title,
    /// else what ran it and where ("Claude Code run · acme/storefront").
    public func label(_ r: TaskRun) -> String {
        if let t = r.bestTitle { return t }
        let place = Self.place(repo: r.repo, project: r.project, branch: nil).first
        return Self.untitled(r.harness) + (place.map { " · " + $0 } ?? "")
    }

    /// Where a run works: the GitHub org and repo (else the project folder), and the branch
    /// unless it's the default one.
    static func place(repo: String?, project: String?, branch: String?) -> [String] {
        var parts: [String] = []
        if let r = repo?.trimmingCharacters(in: .whitespaces), !r.isEmpty { parts.append(r) }
        else if let p = project?.trimmingCharacters(in: .whitespaces), !p.isEmpty { parts.append(p) }
        if let b = branch?.trimmingCharacters(in: .whitespaces), !b.isEmpty, !["main", "master", "trunk", "develop"].contains(b), b != "HEAD" {
            parts.append(b)
        }
        return parts
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
        var parts = Self.place(repo: r.repo, project: r.project, branch: r.branch).filter { $0 != baseTitle(r) }
        if let h = Self.harnessName(r.harness), baseTitle(r) != Self.untitled(r.harness) { parts.append(h) }
        let age = TimeFormat.freshness(since: r.updatedAt, now: now)
        let ago = age == "now" ? "just now" : "\(age) ago"
        parts.append(Self.isFinished(r) ? "finished \(ago)" : "updated \(ago)")
        return parts.joined(separator: " · ")
    }

    /// The run's state in plain words (`RunWords`).
    public func stateText(_ r: TaskRun) -> String {
        if !r.abandoned, r.state == .running, r.stale { return RunWords.quiet(TimeFormat.compact(now.timeIntervalSince(r.updatedAt))) }
        return RunWords.state(r.state, waitReason: r.waitReason, abandoned: r.abandoned, limitWarning: r.warning)
    }

    /// `TaskLimits` names the limit in the warning it writes.
    static func limitWords(_ warning: String?) -> String { RunWords.waitingOnLimit(warning) }

    /// Rose (`.alert` with `.needsInput`) is for a run that needs you; a failure is `.alert` with
    /// `.failed`, which surfaces draw in their failure colour.
    static func look(_ r: TaskRun) -> (RunGlyph, RunTone) {
        if r.abandoned { return (.skipped, .quiet) }
        switch r.state {
        case .running where r.stale: return (.stale, .warn)
        case .running: return (.running, .progress)
        case .waiting where r.waitReason == .input: return (.needsInput, .alert)
        case .waiting where r.waitReason == .limit: return (.waiting, .warn)
        case .waiting: return (.waiting, .neutral)
        case .stopped: return (.stopped, .warn)
        case .done: return (.done, .neutral)
        case .partial: return (.partial, .warn)
        case .failed: return (.failed, .alert)
        }
    }

    /// Finished agents over agents seen, compacted ones included.
    func agentCounts(_ r: TaskRun) -> (finished: Int, total: Int) {
        let earlier = r.finishedEarlier ?? 0
        return (r.nodes.filter(\.state.isTerminal).count + earlier, r.nodes.count + earlier)
    }

    /// Whole percent, rounded down (never "100%" before it's done); the nudge keeps 0.57 at 57.
    func percent(_ f: Double) -> Int { Int((min(max(f, 0), 1) * 100 + 1e-9).rounded(.down)) }

    /// The headline figure: the estimate, rounded down, and never 100% until the run is done.
    func shownPercent(_ r: TaskRun) -> Int {
        let p = percent(max(r.progress.done, r.progress.estimate))
        return r.state == .done ? p : min(p, 99)
    }

    /// "5 of 11 tasks · 3 running": closed counted leaves over all of them ("steps" for a mirrored plan).
    func counts(_ r: TaskRun, live: Bool) -> String? {
        var total = 0, done = 0, running = 0
        for n in r.nodes where n.leaf && n.counted {
            total += 1
            if n.state == .done { done += 1 }
            if n.state == .running { running += 1 }
        }
        guard total > 0 else { return nil }
        let noun = r.mirrored ? (total == 1 ? "step" : "steps") : (total == 1 ? "task" : "tasks")
        return "\(done) of \(total) \(noun)" + (live && running > 0 ? " · \(running) running" : "")
    }

    /// "20–35m left" from the range, else "about 25m left".
    func etaText(_ r: TaskRun) -> String? {
        if let lo = r.etaLowSeconds, let hi = r.etaHighSeconds, hi > lo {
            let a = TimeFormat.compact(Self.roundDown5(lo)), b = TimeFormat.compact(Self.roundUp5(hi))
            if a == b { return "about \(a) left" }
            if a.last == b.last, a.last == "m" || a.last == "h" { return "\(a.dropLast())–\(b) left" }
            return "\(a)–\(b) left"
        }
        return r.etaSeconds.map { "about \(TimeFormat.compact($0)) left" }
    }

    static func roundDown5(_ s: Double) -> Double { s < 600 ? s : (s / 300).rounded(.down) * 300 }
    static func roundUp5(_ s: Double) -> Double { s < 600 ? s : (s / 300).rounded(.up) * 300 }

    /// "1h 12m working" while live (working time only); how long it took once finished.
    func elapsed(_ r: TaskRun) -> String? {
        if Self.isFinished(r) { return Self.duration(r.updatedAt.timeIntervalSince(r.startedAt)) }
        return r.time.working >= 60 ? Self.duration(r.time.working) + " working" : nil
    }

    /// "<1m", "48m", "1h 12m", "3h", "2d 4h".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "<1m" }
        let minutes = Int((s / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        let hours = minutes / 60
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    // MARK: Map

    /// The counted leaves as blocks, closed first, then under way, then untouched (plan order
    /// within each). Empty when the fold gave no shares or there are too many to draw.
    static func segments(_ r: TaskRun) -> [RunSegment] {
        let leaves = r.nodes.filter { $0.leaf && $0.counted && $0.share > 0 }
        guard !leaves.isEmpty, leaves.count <= maxSegments else { return [] }
        let total = leaves.reduce(0) { $0 + $1.share }
        guard total > 0 else { return [] }
        func group(_ n: TaskNode) -> Int {
            switch n.state {
            case .done, .partial, .failed, .skipped, .cancelled: 0
            case .running, .waiting: 1
            case .planned, .parked: 2
            }
        }
        return leaves.enumerated().sorted { (group($0.element), $0.offset) < (group($1.element), $1.offset) }.map { _, n in
            let (_, tone) = look(n)
            let fill: Double = switch n.state {
            case .done, .failed: 1
            case .planned: 0
            default: min(max(n.progress.estimate, 0), 1)
            }
            return RunSegment(weight: n.share / total, fill: fill, tone: n.state == .done ? .progress : tone,
                              critical: n.importance == .critical, title: n.title, failed: n.state == .failed)
        }
    }

    // MARK: Question, actions

    /// What the run is asking: the harness's question, else the waiting task's note.
    func question(_ r: TaskRun) -> RunQuestionModel? {
        func title(_ id: String?) -> String? { id.flatMap { id in r.nodes.first { $0.id == id }?.title } }
        if let q = r.question {
            // A run can wait on you without saying why: the block still says something.
            return RunQuestionModel(asker: RunWords.asking(title(q.task)), text: q.text.isEmpty ? RunWords.waitingForAnswer : q.text, options: q.options)
        }
        if let n = r.nodes.first(where: { $0.state == .waiting && $0.waitReason == .input }), let note = n.waitNote, !note.isEmpty {
            return RunQuestionModel(asker: RunWords.asking(n.title), text: note)
        }
        return nil
    }

    /// Open needs the session's app or folder; a resume command needs Claude Code or Codex and a
    /// session id; anything can be hidden; only an unfinished run can be given up on.
    public static func actions(_ r: TaskRun) -> RunActionSet {
        let open = !(r.host ?? "").isEmpty || !(r.cwd ?? "").isEmpty
        let harness = (r.harness ?? "").lowercased()
        let resumable = ["claude-code", "claude", "codex"].contains(harness) && UUID(uuidString: r.id) != nil
        return RunActionSet(openSession: open, copyResume: resumable, hide: true, abandon: !isFinished(r))
    }

    // MARK: Timeline

    /// Working until the window empties, paused until it resets, working again until done. Only
    /// when the run is forecast to hit the limit before it finishes.
    func timeline(_ r: TaskRun) -> RunTimelineModel? {
        guard let o = r.limitOutlook, let pause = o.pauseAt, let resume = o.resumeAt, let finish = o.finishAt,
              now < pause, pause < resume, resume < finish else { return nil }
        let span = finish.timeIntervalSince(now)
        func at(_ d: Date) -> Double { min(max(d.timeIntervalSince(now) / span, 0), 1) }
        func clock(_ d: Date) -> String { TimeFormat.clock(d, calendar: calendar, locale: locale) }
        let spans = [RunTimelineModel.Span(kind: .working, start: 0, end: at(pause)),
                     RunTimelineModel.Span(kind: .paused, start: at(pause), end: at(resume)),
                     RunTimelineModel.Span(kind: .working, start: at(resume), end: 1)]
        let ticks = [RunTimelineModel.Tick(label: "now", time: clock(now), at: 0),
                     RunTimelineModel.Tick(label: "window empty", time: clock(pause), at: at(pause), strong: true),
                     RunTimelineModel.Tick(label: "resets", time: clock(resume), at: at(resume)),
                     RunTimelineModel.Tick(label: "done", time: "~" + clock(finish), at: 1, strong: true)]
        var notes: [String] = []
        if let share = o.share, share > 0 {
            notes.append("Using \(NumberFormat.percent(min(share, 1))) of what \(o.provider.displayName) is spending now")
        }
        if let need = o.tokensNeeded, need > 0 {
            var s = "needs about \(NumberFormat.tokens(need)) more tokens"
            if let room = o.roomTokens { s += ", the window has room for \(NumberFormat.tokens(max(room, 0)))" }
            notes.append(notes.isEmpty ? s.prefix(1).uppercased() + s.dropFirst() : s)
        }
        return RunTimelineModel(spans: spans, ticks: ticks, note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: Receipt

    func receipt(_ r: TaskRun) -> RunReceiptModel {
        let cost = pricing.flatMap { Self.cost(r.tokensByModel, pricing: $0) }.map { "about " + NumberFormat.dollars(micros: $0.micros, style: .precise) }
        let (tasks, note) = Self.receiptTasks(r)
        var foot: [String] = []
        if r.scopeChanges > 0 { foot.append("Plan changed \(r.scopeChanges == 1 ? "once" : "\(r.scopeChanges) times") after it started") }
        let retries = r.nodes.reduce(0) { $0 + $1.attempts.retries }
        if retries > 0 { foot.append(retries == 1 ? "1 retry" : "\(retries) retries") }
        return RunReceiptModel(duration: Self.duration(r.updatedAt.timeIntervalSince(r.startedAt)), tokens: NumberFormat.tokens(r.tokens),
                               cost: cost, tasks: tasks, tasksNote: note, time: r.time, footnote: foot.isEmpty ? nil : foot.joined(separator: " · "))
    }

    /// "4 of 5" and "tasks · 1 optional failed": the plan's leaves (or the agents seen) and how
    /// the ones that didn't finish ended.
    static func receiptTasks(_ r: TaskRun) -> (String, String) {
        // A mirrored plan's items count like declared tasks; helper agents under a plan don't.
        let leaves = r.nodes.filter { $0.leaf && ($0.declared || !r.hasDeclaredTasks || (r.mirrored && $0.counted)) }
        let earlier = r.hasDeclaredTasks ? 0 : (r.finishedEarlier ?? 0)
        var done = earlier, failed = 0, optionalFailed = 0, cancelled = 0, skipped = 0, open = 0
        var replaced = 0
        for n in leaves {
            // Worked around: neither done nor failed, and out of the total.
            if n.replacedBy != nil { replaced += 1; continue }
            switch n.state {
            case .done: done += 1
            case .failed, .partial: if n.importance == .optional { optionalFailed += 1 } else { failed += 1 }
            case .cancelled: cancelled += 1
            case .skipped: skipped += 1
            case .planned, .running, .waiting, .parked: open += 1
            }
        }
        let total = leaves.count + earlier - replaced
        let noun = !r.hasDeclaredTasks ? (total == 1 ? "agent" : "agents") : r.mirrored ? (total == 1 ? "step" : "steps") : (total == 1 ? "task" : "tasks")
        var parts = [noun]
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if failed > 0 { parts.append("\(failed) failed") }
        if optionalFailed > 0 { parts.append("\(optionalFailed) optional failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if open > 0 { parts.append("\(open) left open") }
        return ("\(done) of \(total)", parts.joined(separator: " · "))
    }

    /// Share of fresh tokens (`TaskRun.tokens` leaves cache reads out) taken as output when only
    /// the total per model is known; the rest is priced as input. Hence "about".
    static let outputShare = 0.15

    /// The run's tokens at API rates; nil when none of its models has a rate.
    public static func cost(_ tokensByModel: [String: Int64], pricing: PricingEngine) -> Cost? {
        var total = Cost.zero, any = false
        for (model, n) in tokensByModel where n > 0 && pricing.isPriced(model: model) {
            let output = Int64((Double(n) * outputShare).rounded())
            total += pricing.price(tokens: TokenCounts(newInput: n - output, output: output), model: model)
            any = true
        }
        return any ? total : nil
    }

    // MARK: Rows

    /// Pressing work first at every level (by the most pressing thing beneath each row), three
    /// levels at most, finished rows folded into one unless `expanded`, capped with "and N more".
    /// Linear in the nodes apart from sorting siblings, and only the rows shown are formatted.
    /// `pressing` counts the rows that aren't finished, shown or not.
    public func rows(_ r: TaskRun, expanded: Bool, opened: Set<String> = []) -> (rows: [RunRowModel], finished: Int, pressing: Int) {
        let l = layout(r, expanded: expanded)
        let nodes = r.nodes
        let cap = expanded ? Self.expandedRowCap : Self.rowCap
        let shown = l.visible.prefix(cap)
        var out = shown.map {
            taskRow(nodes[$0.node], depth: $0.depth, run: r, rolled: $0.depth == Self.maxDepth ? descendants($0.node, nodes, l.children) : [],
                    opened: opened.contains(Self.rowKey(run: r.id, row: nodes[$0.node].id)))
        }
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
        return (out, finished, l.visible.count - (expanded ? finished : 0))
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
    func taskRow(_ n: TaskNode, depth: Int, run: TaskRun, rolled: [TaskNode], opened: Bool = false) -> RunRowModel {
        let (glyph, tone) = Self.look(n)
        var steps: String?
        if let s = n.steps, n.leaf { steps = "\(s.done)/\(s.total)" }
        else if !rolled.isEmpty { steps = "\(rolled.filter(\.state.isTerminal).count)/\(rolled.count)" }
        var (detail, detailTone) = note(n, limitWarning: run.warning, run: run)
        // A deeper task that needs looking at speaks for the row it's rolled into.
        if let worst = rolled.min(by: { $0.attention < $1.attention }), worst.attention < n.attention, worst.attention < .running {
            let (d, t) = note(worst, limitWarning: run.warning, run: run)
            detail = worst.title + (d.map { ": " + $0 } ?? "")
            detailTone = t
        }
        var extra: [String] = []
        if n.attempts.retries > 0 { extra.append("retried \(n.attempts.retries)×") }
        if n.attempts.active > 1 { extra.append("\(n.attempts.active) agents") }
        // Observed agents never report an outcome, so only a declared plan expects one.
        let unconfirmed = run.hasDeclaredTasks && !n.confirmed && n.state.isTerminal
        if unconfirmed { extra.append("unconfirmed") }
        if !extra.isEmpty { detail = ([detail].compactMap { $0 } + extra).joined(separator: " · ") }
        let quiet = !n.counted || n.state == .skipped || n.state == .cancelled
        let lines = details(n, unconfirmed: unconfirmed, run: run)
        return RunRowModel(id: n.id, glyph: glyph, tone: quiet && tone != .alert ? .quiet : tone, depth: depth, title: n.title,
                           marker: n.importance == .normal ? nil : n.importance.rawValue, steps: steps,
                           tokens: n.tokens > 0 ? NumberFormat.tokens(n.tokens) : nil, detail: detail, detailTone: detailTone, quiet: quiet,
                           details: opened && !lines.isEmpty ? lines : nil, opens: !lines.isEmpty)
    }

    /// What an opened row shows, in full: the question or wait, evidence, why it failed or was
    /// dropped, its note, how long it took and with how many agents, its tokens. Empty when
    /// there's nothing beyond the row itself (tokens alone are already on the row).
    func details(_ n: TaskNode, unconfirmed: Bool, run: TaskRun? = nil) -> [RunDetailLine] {
        var out: [RunDetailLine] = []
        func add(_ label: String, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { out.append(RunDetailLine(label: label, value: v)) }
        }
        if n.state == .waiting { add(n.waitReason == .input ? "Asking" : "Waiting", n.waitNote) }
        add("Evidence", n.evidence)
        if let next = n.replacedBy { add("Replaced by", Self.title(of: next, in: run)) }
        switch n.state {
        case .failed, .partial: add("Failed because", n.failure)
        case .cancelled, .skipped: add("Reason", n.failure)
        default: break
        }
        if n.note != n.evidence { add("Note", n.note) }
        if unconfirmed { add("Outcome", "Inferred from its agents ending, not reported") }
        var took: [String] = []
        if n.workingSeconds >= 60 { took.append(Self.duration(n.workingSeconds)) }
        if n.attempts.count > 0 {
            took.append(n.attempts.count == 1 ? "1 agent" : "\(n.attempts.count) agents")
            took.append(n.attempts.retries == 0 ? "no retries" : n.attempts.retries == 1 ? "1 retry" : "\(n.attempts.retries) retries")
        }
        if !took.isEmpty { add(n.state.isTerminal ? "Took" : "So far", took.joined(separator: " · ")) }
        guard !out.isEmpty else { return [] }
        if n.tokens > 0 { add("Tokens", NumberFormat.tokens(n.tokens)) }
        return out
    }

    /// The note that matters for the node's state, and its tone.
    /// `limitWarning` is the run's warning, which names the limit.
    func note(_ n: TaskNode, limitWarning: String? = nil, run: TaskRun? = nil) -> (String?, RunTone) {
        // An approach that failed and was worked around: what took over, quietly.
        if let next = n.replacedBy { return (RunWords.replaced(by: Self.title(of: next, in: run)), .quiet) }
        switch n.state {
        case .waiting:
            switch n.waitReason ?? .dependency {
            case .input: return (n.waitNote ?? RunWords.needsInput, .alert)
            case .limit: return (n.waitNote ?? RunWords.waitingOnLimit(limitWarning), .warn)
            case .dependency: return (n.waitNote ?? RunWords.waitingOnTask, .neutral)
            }
        case .failed: return (n.failure ?? RunWords.failed, n.importance == .optional ? .warn : .alert)
        case .partial: return (n.failure ?? RunWords.partial, .warn)
        case .running where n.stale:
            let quiet = RunWords.quiet(TimeFormat.compact(now.timeIntervalSince(n.lastActivityAt ?? now)))
            return (n.note.map { quiet + " · " + $0 } ?? quiet, .warn)
        case .running: return (n.note, .quiet)
        case .parked: return (n.note ?? RunWords.paused, .quiet)
        case .done: return (n.evidence ?? n.note, .quiet)
        case .cancelled: return (n.failure ?? RunWords.cancelled, .quiet)
        case .skipped: return (n.note ?? RunWords.skipped, .quiet)
        case .planned: return (n.note, .quiet)
        }
    }

    /// A task's title from its id, within the run; the id itself when it isn't there.
    static func title(of id: String, in run: TaskRun?) -> String { run?.nodes.first { $0.id == id }?.title ?? id }

    static func look(_ n: TaskNode) -> (RunGlyph, RunTone) {
        if n.replacedBy != nil { return (.skipped, .quiet) }
        return switch n.state {
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

extension RunCardModel {
    /// The compact view's word in place of the time when the run isn't simply running: what needs
    /// you or holds it up ("asks", "quiet", "limit", "waiting", "stopped"); nil otherwise.
    public var compactFlag: String? {
        switch glyph {
        case .needsInput: "asks"
        case .stale: "quiet"
        case .waiting where tone == .warn: "limit"
        case .waiting: "waiting"
        // A Mac that stopped syncing reads "Mac last seen…": its run isn't stopped, its Mac is away.
        case .stopped where live: stateText.hasPrefix("Mac last seen") ? "offline" : "stopped"
        default: nil
        }
    }
}
