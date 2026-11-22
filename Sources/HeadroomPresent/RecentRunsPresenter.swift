import Foundation
import HeadroomKit

/// A finished run's receipt, small enough to keep for two weeks after its journal is pruned.
/// Written by the app's `RunHistory`; read by the Activity tab's "Recent runs".
public struct RunRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var project: String?
    public var harness: String?
    public var startedAt: Date
    public var endedAt: Date
    public var state: TaskRunState
    public var abandoned: Bool
    public var hidden: Bool
    public var tokens: Int64
    /// Kept so the cost can be priced with today's rates when shown.
    public var tokensByModel: [String: Int64]
    public var time: TaskTimeSplit
    /// "4 of 5" and "tasks · 1 optional failed", as the receipt said.
    public var tasks: String
    public var tasksNote: String

    public init(id: String, title: String, project: String? = nil, harness: String? = nil, startedAt: Date, endedAt: Date, state: TaskRunState,
                abandoned: Bool = false, hidden: Bool = false, tokens: Int64 = 0, tokensByModel: [String: Int64] = [:], time: TaskTimeSplit = .zero,
                tasks: String = "", tasksNote: String = "") {
        self.id = id; self.title = title; self.project = project; self.harness = harness; self.startedAt = startedAt; self.endedAt = endedAt
        self.state = state; self.abandoned = abandoned; self.hidden = hidden; self.tokens = tokens; self.tokensByModel = tokensByModel
        self.time = time; self.tasks = tasks; self.tasksNote = tasksNote
    }

    /// The summary of a finished run, titled as its card was.
    public init(_ r: TaskRun) {
        let (tasks, note) = RunsPresenter.receiptTasks(r)
        self.init(id: r.id, title: RunsPresenter(now: r.updatedAt).label(r), project: r.project, harness: r.harness,
                  startedAt: r.startedAt, endedAt: r.updatedAt, state: r.state, abandoned: r.abandoned, hidden: r.hidden, tokens: r.tokens,
                  tokensByModel: r.tokensByModel, time: r.time, tasks: tasks, tasksNote: note)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, project, harness, state, abandoned, hidden, tokens, time, tasks
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case tokensByModel = "tokens_by_model"
        case tasksNote = "tasks_note"
    }
}

/// One line of "Recent runs": what, when, how long, how much, how it ended.
public struct RecentRunRow: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// "today 2:10 PM", "yesterday 9 PM", "Tue 4 PM".
    public var when: String
    /// "1h 42m"
    public var duration: String
    /// "$4.10", when the models are priced.
    public var cost: String?
    public var glyph: RunGlyph
    public var tone: RunTone
    /// "Done", "Finished with failures", …: for the tooltip and VoiceOver.
    public var outcome: String
}

public struct RecentRunsModel: Sendable, Hashable {
    public var rows: [RecentRunRow]
    /// Runs of the last two weeks past the ones listed.
    public var more: Int
    /// "3 runs · 6h 10m · $18.40" over everything kept.
    public var summary: String

    public static let title = "Recent runs"
}

/// The Activity tab's list of finished runs, newest first.
public struct RecentRunsPresenter: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    public var pricing: PricingEngine?

    public static let cap = 6

    public init(now: Date, calendar: Calendar = Display.calendar, locale: Locale = Display.locale, pricing: PricingEngine? = nil) {
        self.now = now; self.calendar = calendar; self.locale = locale; self.pricing = pricing
    }

    /// Nil when there's nothing to list.
    public func model(_ records: [RunRecord]) -> RecentRunsModel? {
        let shown = records.filter { !$0.hidden }.sorted { ($0.endedAt, $1.id) > ($1.endedAt, $0.id) }
        guard !shown.isEmpty else { return nil }
        var micros: Int64 = 0, priced = false, seconds = 0.0
        for r in shown {
            seconds += r.endedAt.timeIntervalSince(r.startedAt)
            if let p = pricing, let c = RunsPresenter.cost(r.tokensByModel, pricing: p) { micros += c.micros; priced = true }
        }
        var summary = "\(shown.count) run\(shown.count == 1 ? "" : "s") · \(RunsPresenter.duration(seconds))"
        if priced { summary += " · " + NumberFormat.dollars(micros: micros) }
        let rows = shown.prefix(Self.cap).map(row)
        return RecentRunsModel(rows: rows, more: shown.count - rows.count, summary: summary)
    }

    func row(_ r: RunRecord) -> RecentRunRow {
        let (glyph, tone): (RunGlyph, RunTone) = switch r.state {
        case _ where r.abandoned: (.skipped, .quiet)
        case .done: (.done, .neutral)
        case .partial: (.partial, .warn)
        case .failed: (.failed, .alert)
        default: (.stopped, .quiet)
        }
        let cost = pricing.flatMap { RunsPresenter.cost(r.tokensByModel, pricing: $0) }.map { NumberFormat.dollars(micros: $0.micros, style: .precise) }
        return RecentRunRow(id: r.id, title: r.title, when: when(r.endedAt), duration: RunsPresenter.duration(r.endedAt.timeIntervalSince(r.startedAt)),
                            cost: cost, glyph: glyph, tone: tone,
                            outcome: RunWords.state(r.state, waitReason: nil, abandoned: r.abandoned))
    }

    /// "today 2:10 PM", "yesterday 9 PM", "Tue 4 PM", then "Nov 2".
    func when(_ d: Date) -> String {
        let time = TimeFormat.shortClock(d, calendar: calendar, locale: locale)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "today " + time
        case 1: return "yesterday " + time
        case 2...6: return TimeFormat.weekdayShort(d, calendar: calendar, locale: locale) + " " + time
        default: return TimeFormat.monthDay(d, calendar: calendar, locale: locale)
        }
    }
}
