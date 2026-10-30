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

public enum ActivityMode: Int, Equatable { case all, newOnly }

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

    public enum ChipDot: Equatable { case rose, azure, spark }

    public static func == (a: PastWeeksModel, b: PastWeeksModel) -> Bool {
        a.provider == b.provider && a.weeks == b.weeks && a.planChange?.after == b.planChange?.after
            && a.planChange?.pill == b.planChange?.pill && a.chips.map(\.text) == b.chips.map(\.text) && a.collecting == b.collecting
    }

    public init(provider: Provider, weeks: [WeekColumn], planChange: (after: Int, pill: String)? = nil, chips: [(color: ChipDot, text: String)], collecting: Bool) {
        self.provider = provider
        self.weeks = weeks
        self.planChange = planChange
        self.chips = chips
        self.collecting = collecting
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
