import Foundation
import HeadroomKit

/// Presentation models: everything a card draws, already formatted. Built by `Presenter`
/// from live state or by `DemoScenarios` from fixtures, so every UI state is reachable.

public struct Freshness: Equatable {
    public enum Status: Equatable { case fresh, stale, error }
    public var text: String
    public var status: Status
    /// Hover text (the fault reason when red).
    public var tooltip: String?

    public init(text: String, status: Status, tooltip: String? = nil) {
        self.text = text
        self.status = status
        self.tooltip = tooltip
    }
}

public struct SessionBannerModel: Equatable {
    public var level: SessionLevel
    /// Used fraction 0…1 for the ring.
    public var used: Double
    public var title: String
    public var subtitle: String
    public var countdown: String
    public var caption: String

    public init(level: SessionLevel, used: Double, title: String, subtitle: String, countdown: String, caption: String) {
        self.level = level
        self.used = used
        self.title = title
        self.subtitle = subtitle
        self.countdown = countdown
        self.caption = caption
    }
}

/// The detailed 5-hour panel: where the session stands, a timeline and where it's heading.
public struct SessionModuleModel: Equatable {
    public var level: SessionLevel
    public var outlook: SessionForecast.Outlook
    /// Color of the forecast dot and the timeline fill below the warning level.
    public var tone: PacingState
    public var used: Double
    /// Elapsed share of the 5 hours (the "now" tick).
    public var elapsed: Double
    /// Used share at the reset at the recent burn, when known.
    public var projectedUsed: Double?
    public var title: String
    public var subtitle: String
    public var countdown: String
    public var caption: String
    public var forecast: String
    public var startLabel: String?
    public var endLabel: String?
    /// Shown right under the header once it warns; below the week otherwise.
    public var onTop: Bool
    /// The session's own five cells and graph (Settings → Pace card); the slim timeline stands in when both are off.
    public var meter: MeterModel? = nil
    public var glide: GlideModel? = nil

    public init(level: SessionLevel, outlook: SessionForecast.Outlook, tone: PacingState, used: Double, elapsed: Double, projectedUsed: Double? = nil, title: String, subtitle: String, countdown: String, caption: String, forecast: String, startLabel: String? = nil, endLabel: String? = nil, onTop: Bool, meter: MeterModel? = nil, glide: GlideModel? = nil) {
        self.level = level
        self.outlook = outlook
        self.tone = tone
        self.used = used
        self.elapsed = elapsed
        self.projectedUsed = projectedUsed
        self.title = title
        self.subtitle = subtitle
        self.countdown = countdown
        self.caption = caption
        self.forecast = forecast
        self.startLabel = startLabel
        self.endLabel = endLabel
        self.onTop = onTop
        self.meter = meter
        self.glide = glide
    }
}

public struct HeroModel: Equatable {
    public var percentLeft: Int
    public var label: String
    public var renewValue: String
    public var renewCaption: String
    public var hourglass: Bool

    public init(percentLeft: Int, label: String, renewValue: String, renewCaption: String, hourglass: Bool) {
        self.percentLeft = percentLeft
        self.label = label
        self.renewValue = renewValue
        self.renewCaption = renewCaption
        self.hourglass = hourglass
    }
}

public struct MeterModel: Equatable {
    public var state: PacingState
    public var cells: Int
    /// Even-pace caret position along the track (τ), nil to hide.
    public var caret: Double?
    /// 1 normally, 0.5 for faults, 0.4 when blocked.
    public var opacity: Double

    public init(state: PacingState, cells: Int, caret: Double? = nil, opacity: Double) {
        self.state = state
        self.cells = cells
        self.caret = caret
        self.opacity = opacity
    }
}

public struct GlideModel: Equatable {
    public struct Point: Equatable {
        public var t: Double
        public var used: Double
        /// Starts again after a reset: the line steps straight up to here instead of joining the last point.
        public var refill = false

        public init(t: Double, used: Double, refill: Bool = false) {
            self.t = t
            self.used = used
            self.refill = refill
        }
    }
    /// Window length in hours (168 for a week).
    public var hours: Double
    /// Local window start, for day boundaries and labels.
    public var windowStart: Date
    public var nowT: Double
    /// Used fraction history (t in hours since start). Gaps longer than 2 h are drawn dotted.
    public var points: [Point]
    /// Projection end: hour and remaining fraction there.
    public var projectionEnd: (t: Double, remaining: Double)
    /// When the projection runs out before renewal.
    public var runsOut: Bool
    public var endLabel: String?
    public var state: PacingState
    /// Override line color (history view uses the brand color).
    public var brandLine: Provider? = nil
    /// Where the even-pace diagonal starts (it always ends at `hours`); nil hides it.
    public var evenPaceFrom: Double? = 0

    public static func == (a: GlideModel, b: GlideModel) -> Bool {
        a.hours == b.hours && a.windowStart == b.windowStart && a.nowT == b.nowT && a.points == b.points
            && a.projectionEnd.t == b.projectionEnd.t && a.projectionEnd.remaining == b.projectionEnd.remaining
            && a.runsOut == b.runsOut && a.endLabel == b.endLabel && a.state == b.state && a.brandLine == b.brandLine
            && a.evenPaceFrom == b.evenPaceFrom
    }

    public init(hours: Double, windowStart: Date, nowT: Double, points: [Point], projectionEnd: (t: Double, remaining: Double), runsOut: Bool, endLabel: String? = nil, state: PacingState, brandLine: Provider? = nil, evenPaceFrom: Double? = 0) {
        self.hours = hours
        self.windowStart = windowStart
        self.nowT = nowT
        self.points = points
        self.projectionEnd = projectionEnd
        self.runsOut = runsOut
        self.endLabel = endLabel
        self.state = state
        self.brandLine = brandLine
        self.evenPaceFrom = evenPaceFrom
    }
}

public struct VerdictModel: Equatable {
    public var state: PacingState
    public var title: String
    public var multiple: String
    public var primary: String
    public var secondary: String

    public init(state: PacingState, title: String, multiple: String, primary: String, secondary: String) {
        self.state = state
        self.title = title
        self.multiple = multiple
        self.primary = primary
        self.secondary = secondary
    }
}

public struct CalloutModel: Equatable {
    public enum Kind: Equatable { case capEmpty, capTight, earlyReset }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DetailRowModel: Equatable {
    public enum Icon: Equatable {
        case ring(used: Double, level: SessionLevel)
        case hourglass(highlight: Bool)
        case coin(Provider)
    }
    public var icon: Icon
    public var label: String
    public var value: String
    public var suffix: String?
    public var highlight: Bool = false
    public var tooltip: String? = nil

    public init(icon: Icon, label: String, value: String, suffix: String? = nil, highlight: Bool = false, tooltip: String? = nil) {
        self.icon = icon
        self.label = label
        self.value = value
        self.suffix = suffix
        self.highlight = highlight
        self.tooltip = tooltip
    }
}

/// One live agent run's share (0…1) of what its provider is spending right now.
public struct RunSpend: Equatable, Sendable {
    public var title: String
    public var share: Double

    public init(title: String, share: Double) {
        self.title = title
        self.share = share
    }
}

/// "What's spending it": the 5-hour window's current spend as a split bar, each live run by name
/// and then the rest. Shown only while a run spends the provider.
public struct SpendSplitModel: Equatable {
    public struct Slice: Equatable {
        public var label: String
        /// 0…1; the slices add up to 1.
        public var share: Double
        /// "62%"; the slices' percents add up to 100.
        public var percent: String
        /// Everything that isn't a tracked run.
        public var isOther: Bool

        public init(label: String, share: Double, percent: String, isOther: Bool) {
            self.label = label
            self.share = share
            self.percent = percent
            self.isOther = isOther
        }
    }
    public var title: String
    public var slices: [Slice]

    public init(title: String, slices: [Slice]) {
        self.title = title
        self.slices = slices
    }
}

public struct FaultBannerModel: Equatable {
    public var message: String
    public var detail: String?

    public init(message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }
}

public struct PaceCardModel: Equatable {
    public var provider: Provider
    public var plan: String?
    public var freshness: Freshness
    public var session: SessionBannerModel?
    public var sessionModule: SessionModuleModel? = nil
    public var hero: HeroModel?
    public var meter: MeterModel?
    public var glide: GlideModel?
    public var verdict: VerdictModel?
    public var callout: CalloutModel?
    public var rows: [DetailRowModel]
    public var fault: FaultBannerModel?
    /// Settings can hide the week's meter and graph; the models stay for sharing and the menu bar.
    public var showsMeter = true
    public var showsGlide = true
    /// What's spending the 5-hour window, while a live run spends this provider.
    public var spending: SpendSplitModel? = nil
    /// The lane under the week glide: 5-hour sessions, or each day's use without a 5-hour window.
    /// Nil when Settings hides it or there's no glide.
    public var lane: LimitsLaneModel? = nil
    /// The keys row above the chart (empty without a glide).
    public var keys: [LimitsKey] = []
    /// One sentence under the chart when the live session runs out before its reset, or is paused.
    public var chartCaption: String? = nil
    /// The four cells under the chart (empty without a headline window).
    public var stats: [StatCell] = []

    public init(provider: Provider, plan: String? = nil, freshness: Freshness, session: SessionBannerModel? = nil, sessionModule: SessionModuleModel? = nil, hero: HeroModel? = nil, meter: MeterModel? = nil, glide: GlideModel? = nil, verdict: VerdictModel? = nil, callout: CalloutModel? = nil, rows: [DetailRowModel], fault: FaultBannerModel? = nil, showsMeter: Bool = true, showsGlide: Bool = true) {
        self.provider = provider
        self.plan = plan
        self.freshness = freshness
        self.session = session
        self.sessionModule = sessionModule
        self.hero = hero
        self.meter = meter
        self.glide = glide
        self.verdict = verdict
        self.callout = callout
        self.rows = rows
        self.fault = fault
        self.showsMeter = showsMeter
        self.showsGlide = showsGlide
    }
}

// MARK: - Activity

public enum ActivityRange: Int, CaseIterable, Equatable { case day, week, month
    public var label: String { ["24H", "7D", "30D"][rawValue] }
}

/// The "Include cached reads" switch: `.all` when on, `.newOnly` when off. Raw values are persisted.
public enum ActivityMode: Int, Equatable { case all, newOnly
    public var includesCachedReads: Bool { self == .all }
}

public enum BreakdownKind: Int, CaseIterable, Equatable { case model, project, tokenClass
    public var title: String { ["By model", "By project", "By token class"][rawValue] }
}

public struct ActivityBar: Equatable {
    public var start: Date
    public var end: Date
    public var tokens: TokenCounts
    public var micros: Int64

    public init(start: Date, end: Date, tokens: TokenCounts, micros: Int64) {
        self.start = start
        self.end = end
        self.tokens = tokens
        self.micros = micros
    }
}

public struct BreakdownRow: Equatable {
    public var name: String
    public var micros: Int64
    public var share: Double

    public init(name: String, micros: Int64, share: Double) {
        self.name = name
        self.micros = micros
        self.share = share
    }
}

public struct ActivityCardModel: Equatable {
    public var provider: Provider
    public var bars: [ActivityBar]
    /// Selected bar index range [lower, upper).
    public var selection: Range<Int>
    public var axisLabels: [(index: Int, text: String)]
    public var spanLabel: String
    public var spanLong: String
    public var totals: TokenCounts
    public var micros: Int64
    public var breakdown: [BreakdownKind: [BreakdownRow]]
    public var footnote: String?

    public static func == (a: ActivityCardModel, b: ActivityCardModel) -> Bool {
        a.provider == b.provider && a.bars == b.bars && a.selection == b.selection && a.spanLabel == b.spanLabel
            && a.totals == b.totals && a.micros == b.micros && a.breakdown == b.breakdown
            && a.axisLabels.map(\.index) == b.axisLabels.map(\.index) && a.axisLabels.map(\.text) == b.axisLabels.map(\.text)
    }

    public init(provider: Provider, bars: [ActivityBar], selection: Range<Int>, axisLabels: [(index: Int, text: String)], spanLabel: String, spanLong: String, totals: TokenCounts, micros: Int64, breakdown: [BreakdownKind: [BreakdownRow]], footnote: String? = nil) {
        self.provider = provider
        self.bars = bars
        self.selection = selection
        self.axisLabels = axisLabels
        self.spanLabel = spanLabel
        self.spanLong = spanLong
        self.totals = totals
        self.micros = micros
        self.breakdown = breakdown
        self.footnote = footnote
    }
}

extension ActivityCardModel {
    /// Part of the range is selected (not the whole of it): the header shows the span chip with its ×.
    public var isSubRange: Bool { !bars.isEmpty && selection.count < bars.count }
    /// Tokens over the whole range, whatever is selected.
    public var rangeTokens: TokenCounts { bars.reduce(TokenCounts.zero) { $0 + $1.tokens } }
    /// API value over the whole range, whatever is selected.
    public var rangeMicros: Int64 { bars.reduce(Int64(0)) { $0 + $1.micros } }

    /// The tokens the card's header counts: everything, or only new tokens with cached reads off.
    public func shownTokens(_ mode: ActivityMode) -> Int64 { mode.includesCachedReads ? totals.total : totals.fresh }

    /// The composition bar and its three-column key, for the selection.
    public func composition(_ mode: ActivityMode) -> [TokenPart] { TokenPart.parts(totals, mode: mode) }
}

/// One class of tokens in an Activity card's composition bar, chart bars and key.
public struct TokenPart: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case cachedReads, newInput, cacheWrite, output

        public var label: String {
            switch self {
            case .cachedReads: "Cached reads"
            case .newInput: "New input"
            case .cacheWrite: "Cache write"
            case .output: "Output"
            }
        }

        /// Alpha of the provider tone this class is drawn in (redesign §2 rule 5: 26 / 62 / 100%).
        public var toneStrength: Double {
            switch self {
            case .cachedReads, .cacheWrite: ProviderTone.cachedReads
            case .newInput: ProviderTone.newInput
            case .output: ProviderTone.output
            }
        }
    }

    public var kind: Kind
    public var tokens: Int64
    /// Share of the parts' sum (0 when there are no tokens).
    public var share: Double
    public var label: String { kind.label }

    public init(kind: Kind, tokens: Int64, share: Double) {
        self.kind = kind
        self.tokens = tokens
        self.share = share
    }

    /// With cached reads: cached reads, new input (cache writes included) and output. Without:
    /// new input, cache write and output. Always three parts, in that order.
    public static func parts(_ t: TokenCounts, mode: ActivityMode) -> [TokenPart] {
        let raw: [(Kind, Int64)] = mode.includesCachedReads
            ? [(.cachedReads, t.cacheRead), (.newInput, t.newInput + t.cacheWrite), (.output, t.output)]
            : [(.newInput, t.newInput), (.cacheWrite, t.cacheWrite), (.output, t.output)]
        let sum = raw.reduce(Int64(0)) { $0 + $1.1 }
        return raw.map { TokenPart(kind: $0.0, tokens: $0.1, share: sum > 0 ? Double($0.1) / Double(sum) : 0) }
    }
}

/// Activity's summary card: the API value of the range across the enabled providers, and the
/// split between them (redesign §5).
public struct ActivitySummaryModel: Equatable, Sendable {
    public struct Slice: Equatable, Sendable {
        public var provider: Provider
        public var micros: Int64
        /// Share of the summary's API value (by tokens when nothing is priced).
        public var share: Double

        public init(provider: Provider, micros: Int64, share: Double) {
            self.provider = provider
            self.micros = micros
            self.share = share
        }
    }

    /// "API value · last 24 hours" (drawn uppercased).
    public var eyebrow: String
    public var micros: Int64
    /// Every token with cached reads on, new tokens only with it off.
    public var tokens: Int64
    public var includesCachedReads: Bool
    /// Cached reads' share of all tokens, whatever the switch says.
    public var cachedShare: Double
    /// "tokens · 96% cached", or "new tokens" with cached reads off.
    public var tokensCaption: String
    /// One per enabled provider, in the cards' order.
    public var slices: [Slice]

    /// The split and its legend only mean something with two providers.
    public var showsSplit: Bool { slices.count > 1 }

    /// Cells of an `n`-cell split given to the first provider: never all or none while both have a share.
    public func leadingCells(_ n: Int = ActivitySummaryModel.splitCells) -> Int {
        guard let first = slices.first, slices.count > 1 else { return n }
        let k = Int((first.share * Double(n)).rounded())
        let others = slices.dropFirst().contains { $0.share > 0 }
        return first.share > 0 && others ? min(max(k, 1), n - 1) : k
    }

    public static let splitCells = 20

    public init(eyebrow: String, micros: Int64, tokens: Int64, includesCachedReads: Bool, cachedShare: Double, tokensCaption: String, slices: [Slice]) {
        self.eyebrow = eyebrow
        self.micros = micros
        self.tokens = tokens
        self.includesCachedReads = includesCachedReads
        self.cachedShare = cachedShare
        self.tokensCaption = tokensCaption
        self.slices = slices
    }
}

// MARK: - Past weeks

public struct WeekColumn: Equatable {
    public var used: Double
    public var projected: Double? = nil
    public var ranOutHoursEarly: Int? = nil
    public var sessionHits: Int = 0
    public var earlyResets: Int = 0
    public var isCurrent: Bool = false
    public var caption: String

    public init(used: Double, projected: Double? = nil, ranOutHoursEarly: Int? = nil, sessionHits: Int = 0, earlyResets: Int = 0, isCurrent: Bool = false, caption: String) {
        self.used = used
        self.projected = projected
        self.ranOutHoursEarly = ranOutHoursEarly
        self.sessionHits = sessionHits
        self.earlyResets = earlyResets
        self.isCurrent = isCurrent
        self.caption = caption
    }
}

public struct PastWeeksModel: Equatable {
    public var provider: Provider
    public var weeks: [WeekColumn]
    /// Index after which a plan change happened, with the new plan's pill.
    public var planChange: (after: Int, pill: String)?
    public var chips: [(color: ChipDot, text: String)]
    public var collecting: Bool
    /// The last seven days of 5-hour sessions (moved here from Activity's old sessions section):
    /// nil without a 5-hour limit or any finished session. Also one of `chips`.
    public var sessionsHit: SessionsHit?

    /// `amber`: sessions hit the limit; `muted`: a count of nothing to worry about.
    public enum ChipDot: Equatable { case rose, azure, spark, amber, muted }

    /// "3 of 13 sessions hit".
    public struct SessionsHit: Equatable, Sendable {
        public var hit: Int
        public var total: Int
        public var text: String { "\(hit) of \(total) sessions hit" }
        public var chip: (color: ChipDot, text: String) { (hit > 0 ? .amber : .muted, text) }

        public init(hit: Int, total: Int) {
            self.hit = hit
            self.total = total
        }
    }

    public static func == (a: PastWeeksModel, b: PastWeeksModel) -> Bool {
        a.provider == b.provider && a.weeks == b.weeks && a.planChange?.after == b.planChange?.after
            && a.planChange?.pill == b.planChange?.pill && a.chips.map(\.text) == b.chips.map(\.text) && a.chips.map(\.color) == b.chips.map(\.color)
            && a.collecting == b.collecting && a.sessionsHit == b.sessionsHit
    }

    public init(provider: Provider, weeks: [WeekColumn], planChange: (after: Int, pill: String)? = nil, chips: [(color: ChipDot, text: String)], collecting: Bool,
                sessionsHit: SessionsHit? = nil) {
        self.provider = provider
        self.weeks = weeks
        self.planChange = planChange
        self.chips = chips
        self.collecting = collecting
        self.sessionsHit = sessionsHit
    }
}

public struct FooterModel: Equatable {
    public var text: String
    public var status: Freshness.Status

    public init(text: String, status: Freshness.Status) {
        self.text = text
        self.status = status
    }
}

// MARK: - 5-hour sessions

public struct SessionBar: Equatable {
    public var peak: Double
    public var hitLimit: Bool
    public var inProgress: Bool
    /// Weekday under the first session of each day.
    public var dayLabel: String?
    public var tooltip: String

    public init(peak: Double, hitLimit: Bool, inProgress: Bool, dayLabel: String? = nil, tooltip: String) {
        self.peak = peak
        self.hitLimit = hitLimit
        self.inProgress = inProgress
        self.dayLabel = dayLabel
        self.tooltip = tooltip
    }
}

public struct SessionHistoryModel: Equatable {
    public var provider: Provider
    /// Oldest first; the session in progress last.
    public var bars: [SessionBar]
    public var warnAt: Double
    public var chips: [(color: PastWeeksModel.ChipDot, text: String)]

    public static func == (a: SessionHistoryModel, b: SessionHistoryModel) -> Bool {
        a.provider == b.provider && a.bars == b.bars && a.warnAt == b.warnAt && a.chips.map(\.text) == b.chips.map(\.text)
    }

    public init(provider: Provider, bars: [SessionBar], warnAt: Double, chips: [(color: PastWeeksModel.ChipDot, text: String)]) {
        self.provider = provider
        self.bars = bars
        self.warnAt = warnAt
        self.chips = chips
    }
}

// MARK: - Limits chart: the lane under the week, its keys, caption and stat strip

/// What runs under the week glide on the Limits card, on the same time axis (hours since the
/// window start, like `GlideModel.Point.t`).
public struct LimitsLaneModel: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// One bar per 5-hour session (the account reports a 5-hour window).
        case sessions
        /// One bar per local day: that day's share of the window (no 5-hour window).
        case daily
    }
    public var kind: Kind
    /// Window length in hours (the glide's `hours`).
    public var hours: Double
    /// Finished sessions that overlap the window, clipped to it, oldest first.
    public var sessions: [LaneSession] = []
    /// The 5-hour session running now, clipped to the window.
    public var current: LaneCurrentSession? = nil
    /// One per local day of the window, in order (daily lane).
    public var days: [LaneDay] = []
    /// Used share where a session warns: the dashed amber line, and amber bars from here.
    public var warnAt: Double = 0.75

    public init(kind: Kind, hours: Double, sessions: [LaneSession] = [], current: LaneCurrentSession? = nil, days: [LaneDay] = [], warnAt: Double = 0.75) {
        self.kind = kind
        self.hours = hours
        self.sessions = sessions
        self.current = current
        self.days = days
        self.warnAt = warnAt
    }

    /// Sessions this window that hit the limit, the running one included.
    public var limitHits: Int { sessions.filter(\.hitLimit).count + (current?.hitLimit == true ? 1 : 0) }
}

/// One finished 5-hour session in the lane: a bar from its start to its reset, as tall as its peak.
public struct LaneSession: Equatable, Sendable {
    /// Hours since the window start, clipped to the window.
    public var start: Double
    public var end: Double
    /// Peak used share, 0…1.
    public var peak: Double
    public var hitLimit: Bool
    /// "Tue 9 AM – 2 PM · peaked at 84%".
    public var tooltip: String

    public init(start: Double, end: Double, peak: Double, hitLimit: Bool, tooltip: String) {
        self.start = start
        self.end = end
        self.peak = peak
        self.hitLimit = hitLimit
        self.tooltip = tooltip
    }
}

/// The session running now: an outlined track over its 5 hours, filled to now, with a dotted cap
/// where the recent rate takes it by the reset.
public struct LaneCurrentSession: Equatable, Sendable {
    /// Hours since the window start, clipped to the window.
    public var start: Double
    /// The reset.
    public var end: Double
    /// Used share now, 0…1.
    public var used: Double
    /// Used share at the reset at the recent rate, when known (nil once blocked).
    public var projectedUsed: Double?
    /// When it runs out at the recent rate, if that comes before the reset (hours since the window start).
    public var runsOutAt: Double?
    public var level: SessionLevel
    public var tooltip: String

    public var hitLimit: Bool { level == .blocked }

    public init(start: Double, end: Double, used: Double, projectedUsed: Double? = nil, runsOutAt: Double? = nil, level: SessionLevel, tooltip: String) {
        self.start = start
        self.end = end
        self.used = used
        self.projectedUsed = projectedUsed
        self.runsOutAt = runsOutAt
        self.level = level
        self.tooltip = tooltip
    }
}

/// One local day in the daily-use lane.
public struct LaneDay: Equatable, Sendable {
    /// Hours since the window start; the first and last days are cut at the window's edges.
    public var start: Double
    public var end: Double
    /// Share of the window used that day (the drop in what's left across it), 0…1; nil for days still ahead.
    public var used: Double?
    /// An even day's share: the day's hours ÷ the window's hours.
    public var even: Double
    public var isToday: Bool
    /// Above 1.5× an even day.
    public var isHeavy: Bool
    /// "14%" over the bar, when there's a bar.
    public var label: String?
    /// "Tuesday · 14% of the week (an even day is 14%)"; nil for days still ahead.
    public var tooltip: String?

    public init(start: Double, end: Double, used: Double?, even: Double, isToday: Bool, isHeavy: Bool, label: String? = nil, tooltip: String? = nil) {
        self.start = start
        self.end = end
        self.used = used
        self.even = even
        self.isToday = isToday
        self.isHeavy = isHeavy
        self.label = label
        self.tooltip = tooltip
    }
}

/// One entry in the keys row above the Limits chart. The first is drawn at full strength, the rest dimmed.
public struct LimitsKey: Equatable, Sendable {
    public enum Mark: String, Equatable, Sendable { case line, bar, dash, cross }
    public enum Tone: Equatable, Sendable {
        /// The week's state color.
        case state(PacingState)
        /// Neutral ink (the lane's bars).
        case neutral
        /// The chart's label color (the even-day mark).
        case faint
        case amber, rose
    }
    public var mark: Mark
    public var text: String
    public var tone: Tone

    public init(mark: Mark, text: String, tone: Tone) {
        self.mark = mark
        self.text = text
        self.tone = tone
    }
}

/// One cell of the stat strip under the Limits chart.
public struct StatCell: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case plain, state(PacingState), amber, rose }
    /// Tiny uppercase label: "WEEK", "5-HOUR".
    public var label: String
    /// "54%", "Paused", "2h 12m".
    public var value: String
    /// "left", "12:12 PM", "this week".
    public var sub: String
    public var tone: Tone

    public init(label: String, value: String, sub: String, tone: Tone = .plain) {
        self.label = label
        self.value = value
        self.sub = sub
        self.tone = tone
    }
}
