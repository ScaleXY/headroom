import Foundation
import HeadroomKit

// The Runs tab as one list: the most pressing run opened in place (or, with nothing live, the
// day's receipt), then the rest as two-line rows under "Needs you", "Working" and each day.

/// Where a run stands, by who moves next. The list's sections and the lead card's choice follow it.
public enum RunPhase: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Waiting on a person's answer.
    case asks
    /// The agent ended its turn with work open: the person moves next.
    case yourTurn
    /// The agent has it: running, quiet, at a limit, or waiting on another task.
    case working
    /// Done, failed, left or closed.
    case settled

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A run's row: the name (drawn by the renderer, two lines at most), then the state's key in its
/// colour and what's going on; on the right a figure over a time.
public struct RunLineModel: Sendable, Hashable {
    /// "Asks you", "Your turn · 14m", "3 running", "Quiet 18m", "Done", "Left at 95%".
    public var key: String
    public var keyTone: RunTone
    /// "2 open · must-haves done", "Refund webhooks, Receipts", "12 tasks · 1h 26m working".
    public var detail: String?
    /// "62%", "7/9" while live; the cost once settled.
    public var figure: String?
    /// "~1h 50m" left, "44m" worked, or the clock time a settled run settled at.
    public var time: String?

    public init(key: String, keyTone: RunTone = .neutral, detail: String? = nil, figure: String? = nil, time: String? = nil) {
        self.key = key; self.keyTone = keyTone; self.detail = detail; self.figure = figure; self.time = time
    }
}

/// What the lead card adds to a run's card: a badge with how long it's been, what's left (with
/// work that's yours marked) or what it's doing, and a note when it's paused at a limit.
public struct RunLeadModel: Sendable, Hashable {
    /// "Asks you", "Your turn", "3 running", "Quiet 18m", "Paused at the limit".
    public var badge: String
    public var tone: RunTone
    /// "6m ago", "8m · worked 24m this turn".
    public var since: String?
    /// "What's left" for your turn (yours first), the open tasks under way while working.
    public var rows: [RunRowModel]
    /// "What's left · 3", "Doing".
    public var rowsTitle: String?
    /// "Working on Rewrite the routes and 2 more.", or the limit: "Paused at the limit · back 3:30 PM".
    public var note: String?
    public var noteTone: RunTone

    public init(badge: String, tone: RunTone, since: String? = nil, rows: [RunRowModel] = [], rowsTitle: String? = nil, note: String? = nil,
                noteTone: RunTone = .quiet) {
        self.badge = badge; self.tone = tone; self.since = since; self.rows = rows; self.rowsTitle = rowsTitle; self.note = note; self.noteTone = noteTone
    }
}

/// The settled runs of one calendar day, with a total that covers every one of them (the ones
/// past the cap and the short sessions too), so the header and the rows always agree.
public struct RunDaySection: Sendable, Hashable, Identifiable {
    public var id: String
    /// "Today", "Yesterday".
    public var title: String
    /// "4 runs · 7h 36m · $45.53": every settled run of the day on the tab.
    public var summary: String
    public var cards: [RunCardModel]
    /// Rows past the ones listed ("+ 2 more").
    public var more: Int
    /// Sessions too small to list one by one, folded into `shortLine`.
    public var short: [RunCardModel]
    /// "3 short sessions · 12m · $2.19".
    public var shortLine: String?
    public var runs: Int
    public var worked: Double
    public var cost: Double?
    public var outcomes: RunOutcomes

    public init(id: String, title: String, summary: String, cards: [RunCardModel], more: Int = 0, short: [RunCardModel] = [], shortLine: String? = nil,
                runs: Int, worked: Double, cost: Double? = nil, outcomes: RunOutcomes = RunOutcomes([])) {
        self.id = id; self.title = title; self.summary = summary; self.cards = cards; self.more = more; self.short = short; self.shortLine = shortLine
        self.runs = runs; self.worked = worked; self.cost = cost; self.outcomes = outcomes
    }
}

/// With nothing live, the lead card is the day's receipt: what it cost, how long the agents
/// worked, and how the runs ended.
public struct RunDayReceipt: Sendable, Hashable {
    /// "Nothing running · today so far".
    public var title: String
    /// "$45.53", when any run is priced.
    public var cost: String?
    /// "API value across 4 runs", or "4 runs" when nothing is priced.
    public var costCaption: String
    /// "7h 36m"
    public var worked: String
    public var workedCaption: String
    /// "3 done · 1 left at 95%".
    public var outcomes: String
    /// A block per run, as wide as its share of the day's work.
    public var segments: [RunSegment]

    public init(title: String, cost: String?, costCaption: String, worked: String, workedCaption: String, outcomes: String, segments: [RunSegment]) {
        self.title = title; self.cost = cost; self.costCaption = costCaption; self.worked = worked; self.workedCaption = workedCaption
        self.outcomes = outcomes; self.segments = segments
    }
}

/// How settled runs ended, and what they cost together.
public struct RunOutcomes: Sendable, Hashable {
    public var done = 0, failed = 0, left = 0, closed = 0
    /// The left run's percent, when exactly one was left.
    public var leftAt: Int?
    /// Summed costs in dollars, when any run is priced.
    public var cost: Double?

    public init(_ cards: [RunCardModel]) {
        for c in cards { add(glyph: c.glyph, percent: c.percent, cost: c.cost) }
    }

    mutating func add(glyph: RunGlyph, percent: Int?, cost: Double?) {
        switch glyph {
        case .failed, .partial: failed += 1
        case .skipped: closed += 1
        case .left, .stopped, .yourTurn: left += 1; leftAt = left == 1 ? percent : nil
        default: done += 1
        }
        if let cost { self.cost = (self.cost ?? 0) + cost }
    }

    /// "3 done", "1 with failures", "1 left at 95%", "1 closed".
    public var words: [String] {
        [done > 0 ? "\(done) done" : nil, failed > 0 ? "\(failed) with failures" : nil,
         left > 0 ? (left == 1 ? "1 " + RunWords.left(at: leftAt).lowercased() : "\(left) left") : nil,
         closed > 0 ? "\(closed) closed" : nil].compactMap { $0 }
    }
}

extension RunsPresenter {
    /// Work under this makes a settled session that only mirrored its harness's plan, with no
    /// agents, too small to list on its own (the alerts' test for a run worth watching).
    public static let shortWork: TimeInterval = 15 * 60
    /// A turn that ended after this much work says so; a shorter one, or a session that simply
    /// ended, doesn't.
    public static let turnAlertWork: TimeInterval = 10 * 60

    /// A run the agent planned (or that spawned agents) always is; a session's own plan list only
    /// once it has had a quarter of an hour of work.
    public static func worthWatching(_ r: TaskRun) -> Bool {
        !r.mirrored || r.time.working >= shortWork || r.nodes.contains { $0.attempts.count > 0 }
    }

    /// Who moves next.
    public static func phase(_ r: TaskRun) -> RunPhase {
        if r.isSettled { return .settled }
        if r.needsInput { return .asks }
        return r.yourTurn ? .yourTurn : .working
    }

    /// Seconds worked; a run with no split (older records, mirrored runs from older Macs) falls
    /// back to the time it was open.
    public static func worked(_ r: TaskRun) -> Double {
        r.time.total > 0 ? r.time.working : max(0, r.updatedAt.timeIntervalSince(r.startedAt))
    }

    /// The run at API rates in dollars; nil without pricing or a priced model.
    func costValue(_ r: TaskRun) -> Double? {
        pricing.flatMap { Self.cost(r.tokensByModel, pricing: $0) }.map { Double($0.micros) / 1_000_000 }
    }

    // MARK: Line

    /// The two-line row for a run of this Mac.
    func line(_ r: TaskRun, card c: RunCardModel) -> RunLineModel {
        let leaves = pageLeaves(r).filter { !$0.state.isTerminal }
        let yours = leaves.filter { $0.state == .waiting && $0.waitReason == .you }.count
        switch Self.phase(r) {
        case .asks:
            let q = question(r)
            return RunLineModel(key: "Asks you", keyTone: .alert, detail: q.map { "“\($0.text)”" }, figure: figure(c),
                                time: r.question.map { TimeFormat.compact(now.timeIntervalSince($0.askedAt)) })
        case .yourTurn:
            return RunLineModel(key: turnKey(r), keyTone: .neutral, detail: openDetail(open: leaves.count, yours: yours, r), figure: figure(c),
                                time: Self.worked(r) >= 60 ? Self.duration(Self.worked(r)) : nil)
        case .working:
            let status = c.page?.status ?? self.status(r)
            let tone: RunTone = r.stale || r.waitReason == .limit ? .warn : r.state == .running ? .progress : .neutral
            return RunLineModel(key: status.key, keyTone: tone, detail: status.detail, figure: figure(c), time: c.hero?.side)
        case .settled:
            // The key stays short; "must-haves done" is in the detail.
            let key = r.left ? RunWords.left(at: r.hasDeclaredTasks ? shownPercent(r) : nil) : c.stateText
            return RunLineModel(key: key, keyTone: settledTone(c), detail: settledDetail(r, leaves: leaves.count),
                                figure: c.cost.map { NumberFormat.dollars($0, style: .precise) },
                                time: TimeFormat.clock(r.updatedAt, calendar: calendar, locale: locale))
        }
    }

    /// "Your turn · 8m": how long since the turn ended.
    func turnKey(_ r: TaskRun) -> String {
        RunWords.yourTurn(since: TimeFormat.compact(now.timeIntervalSince(r.turnEndedAt ?? r.updatedAt)))
    }

    /// "3 open · 1 yours · must-haves done".
    func openDetail(open: Int, yours: Int, _ r: TaskRun) -> String? {
        var parts: [String] = []
        if open > 0 { parts.append("\(open) open") }
        if yours > 0 { parts.append(RunWords.forYou(yours)) }
        if r.mustHavesDone { parts.append(RunWords.mustHavesDone) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "12 tasks · 1h 26m working", or for a left run what it left.
    func settledDetail(_ r: TaskRun, leaves open: Int) -> String? {
        var parts: [String] = []
        if r.left || (r.abandoned && open > 0) {
            if let d = openDetail(open: open, yours: 0, r) { parts.append(d) }
        } else if r.hasDeclaredTasks {
            let n = r.jobNodes.filter { $0.leaf && $0.counted }.count + (r.finishedEarlier ?? 0)
            if n > 0 { parts.append("\(n) \(r.mirrored ? (n == 1 ? "step" : "steps") : (n == 1 ? "task" : "tasks"))") }
        } else {
            let (_, total) = agentCounts(r)
            if total > 0 { parts.append("\(total) agent\(total == 1 ? "" : "s")") }
        }
        let w = Self.worked(r)
        if w >= 60 { parts.append(RunWords.working(Self.duration(w))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "62%" or "7/9".
    func figure(_ c: RunCardModel) -> String? { c.hero.map { $0.number + $0.unit } }

    func settledTone(_ c: RunCardModel) -> RunTone { c.glyph == .failed || c.glyph == .partial ? .alert : .neutral }

    // MARK: Lead

    /// What the lead card shows beyond the card: the badge, and what's left or under way.
    func lead(_ r: TaskRun, card c: RunCardModel) -> RunLeadModel? {
        let leaves = pageLeaves(r).filter { !$0.state.isTerminal }
        // Lines to read, not to open: the run's page has the details.
        func row(_ n: TaskNode) -> RunRowModel { var row = taskRow(n, depth: 0, run: r, rolled: []); row.opens = false; return row }
        switch Self.phase(r) {
        case .settled:
            return nil
        case .asks:
            let since = r.question.map { TimeFormat.compact(now.timeIntervalSince($0.askedAt)) + " ago" }
            return RunLeadModel(badge: "Asks you", tone: .alert, since: since)
        case .yourTurn:
            // Yours first: those are what the person can do now.
            let ordered = leaves.enumerated().sorted { a, b in
                let ya = a.element.waitReason == .you && a.element.state == .waiting, yb = b.element.waitReason == .you && b.element.state == .waiting
                return (ya ? 0 : 1, a.element.attention, a.offset) < (yb ? 0 : 1, b.element.attention, b.offset)
            }.map(\.element)
            var since = TimeFormat.compact(now.timeIntervalSince(r.turnEndedAt ?? r.updatedAt)) + " ago"
            if let t = r.turnSeconds, t >= 60 { since += " · worked \(Self.duration(t)) this turn" }
            return RunLeadModel(badge: RunWords.yourTurn, tone: .neutral, since: since, rows: ordered.prefix(3).map(row),
                                rowsTitle: leaves.isEmpty ? nil : "What's left · \(leaves.count)")
        case .working:
            let status = c.page?.status ?? self.status(r)
            let tone: RunTone = r.stale || r.waitReason == .limit ? .warn : r.state == .running ? .progress : .neutral
            var note: String?, noteTone = RunTone.quiet
            if let limit = c.page?.limit {
                note = "Pauses at the limit around \(limit.pause), back \(limit.resume)"; noteTone = .warn
            } else if r.state == .waiting, r.waitReason == .limit {
                let back = r.limitOutlook?.resumeAt.map { TimeFormat.clock($0, calendar: calendar, locale: locale) }
                note = back.map { "Picks up again around \($0), when the window resets" } ?? "Picks up again when the window resets"; noteTone = .warn
            } else {
                note = c.verdict?.primary
            }
            return RunLeadModel(badge: status.key, tone: tone, since: nil, note: note, noteTone: noteTone)
        }
    }

    // MARK: Assembling the list

    /// A run on the list, before its card is built: what the sections and totals need.
    struct ListEntry {
        var id: String
        var title: String
        var updatedAt: Date
        var attention: TaskAttention
        var phase: RunPhase
        /// Its Mac stopped syncing mid-run.
        var away = false
        var worked: Double
        var cost: Double?
        var short: Bool
        var glyph: RunGlyph
        var percent: Int?
        var card: (_ sayStart: Bool) -> RunCardModel
    }

    /// Live runs (who moves next, then most pressing), the lead among them, and the settled ones
    /// by day. Totals come from every entry, built or not.
    func assemble(_ entries: [ListEntry], allRecent: Bool) -> RunsPageModel {
        let live = entries.filter { $0.phase != .settled }.sorted { a, b in
            if a.away != b.away { return b.away }
            return (a.phase, a.attention, b.updatedAt, a.id) < (b.phase, b.attention, a.updatedAt, b.id)
        }
        let settled = entries.filter { $0.phase == .settled }.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let today = calendar.startOfDay(for: now)
        let days: [(String, String, [ListEntry])] = [("today", RunWords.today, settled.filter { $0.updatedAt >= today }),
                                                     ("yesterday", RunWords.yesterday, settled.filter { $0.updatedAt < today })]
        let cap = allRecent ? Self.recentExpandedCap : Self.recentCap
        // Runs with the same name say when they started.
        var listedDays: [(id: String, title: String, all: [ListEntry], listed: [ListEntry], short: [ListEntry])] = []
        var named: [ListEntry] = live
        for (id, title, all) in days where !all.isEmpty {
            let short = all.filter(\.short), long = all.filter { !$0.short }
            let listed = Array(long.prefix(cap))
            listedDays.append((id, title, all, listed, short))
            named += listed + short
        }
        var counts: [String: Int] = [:]
        for e in named { counts[e.title, default: 0] += 1 }
        func make(_ e: ListEntry) -> RunCardModel { e.card((counts[e.title] ?? 0) > 1) }

        let liveCards = live.map(make)
        var sections: [RunDaySection] = []
        for d in listedDays {
            var outcomes = RunOutcomes([])
            var worked = 0.0
            for e in d.all { outcomes.add(glyph: e.glyph, percent: e.percent, cost: e.cost); worked += e.worked }
            let shortCards = d.short.map(make)
            var shortLine: String?
            if !d.short.isEmpty {
                let w = d.short.reduce(0) { $0 + $1.worked }
                let c = d.short.compactMap(\.cost)
                shortLine = ([RunWords.shortSessions(d.short.count), Self.duration(w)] + (c.isEmpty ? [] : [NumberFormat.dollars(c.reduce(0, +), style: .precise)]))
                    .joined(separator: " · ")
            }
            sections.append(RunDaySection(id: d.id, title: d.title, summary: summary(runs: d.all.count, worked: worked, cost: outcomes.cost),
                                          cards: d.listed.map(make), more: d.all.count - d.short.count - d.listed.count, short: shortCards,
                                          shortLine: shortLine, runs: d.all.count, worked: worked, cost: outcomes.cost, outcomes: outcomes))
        }
        let recent = sections.flatMap(\.cards)
        var page = RunsPageModel(live: liveCards, recent: recent, moreRecent: settled.count - recent.count,
                                 allRecent: allRecent && settled.count - sections.reduce(0) { $0 + $1.short.count } > Self.recentCap)
        page.leadID = liveCards.first?.id
        page.days = sections
        if liveCards.isEmpty, let t = sections.first(where: { $0.id == "today" }) {
            page.receipt = dayReceipt(t, entries: days[0].2)
        }
        return page
    }

    /// "4 runs · 7h 36m · $45.53".
    func summary(runs: Int, worked: Double, cost: Double?) -> String {
        ([RunWords.runs(runs), Self.duration(worked)] + (cost.map { [NumberFormat.dollars($0, style: .precise)] } ?? [])).joined(separator: " · ")
    }

    func dayReceipt(_ s: RunDaySection, entries: [ListEntry]) -> RunDayReceipt {
        let total = max(entries.reduce(0) { $0 + $1.worked }, 1)
        // Oldest first, as the day went.
        let segs = entries.reversed().map { e -> RunSegment in
            let failed = e.glyph == .failed || e.glyph == .partial
            let settledOpen = e.glyph == .left || e.glyph == .skipped
            return RunSegment(weight: max(e.worked, 1) / total, fill: 1, tone: settledOpen ? .quiet : .neutral, failed: failed)
        }
        return RunDayReceipt(title: RunWords.nothingRunning, cost: s.cost.map { NumberFormat.dollars($0, style: .precise) },
                             costCaption: s.cost != nil ? "API value across \(RunWords.runs(s.runs))" : RunWords.runs(s.runs),
                             worked: Self.duration(s.worked), workedCaption: "of agent work", outcomes: s.outcomes.words.joined(separator: " · "),
                             segments: Array(segs.suffix(Self.maxSegments)))
    }

    /// An entry for a run of this Mac.
    func entry(_ r: TaskRun, expanded: Set<String>, opened: Set<String>) -> ListEntry {
        let (glyph, _) = Self.look(r)
        let phase = Self.phase(r)
        return ListEntry(id: r.id, title: baseTitle(r), updatedAt: r.updatedAt, attention: r.attention, phase: phase, worked: Self.worked(r),
                         cost: costValue(r), short: phase == .settled && !Self.worthWatching(r), glyph: glyph,
                         percent: r.hasDeclaredTasks ? shownPercent(r) : nil) {
            card(r, expanded: expanded.contains(r.id), sayStart: $0, opened: opened)
        }
    }
}
