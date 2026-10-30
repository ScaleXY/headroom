import HeadroomKit
import SwiftUI
import WidgetKit

/// The three desktop widgets.
public enum HeadroomWidgetKind: String, CaseIterable, Sendable {
    /// The Burn-o-meter: twin dials for the 5-hour session and the week.
    case burn
    /// The Pace card: what's left, the meter, the glide and the verdict.
    case pace
    /// The 5-hour session: a countdown ring and the last day's trail.
    case session

    public var kind: String { "com.scalexy.headroom.widget.\(rawValue)" }

    public var title: String {
        switch self {
        case .burn: "Burn-o-meter"
        case .pace: "Headroom"
        case .session: "5-Hour Session"
        }
    }

    public var summary: String {
        switch self {
        case .burn: "How fast you're spending, against the pace that lasts to the reset."
        case .pace: "What's left this week, where it's heading and when it renews."
        case .session: "Time to the 5-hour reset, and how the session is going."
        }
    }

    public var families: [WidgetFamily] {
        switch self {
        case .burn, .pace: [.systemSmall, .systemMedium, .systemLarge]
        case .session: [.systemSmall, .systemMedium]
        }
    }
}

/// One widget's content for a family. The extension puts it on `WidgetSurface` with
/// `containerBackground`; the preview renderer composes the two itself.
public struct HeadroomWidgetView: View {
    var kind: HeadroomWidgetKind
    var family: WidgetFamily
    var feed: WidgetFeed?
    var now: Date

    public init(kind: HeadroomWidgetKind, family: WidgetFamily, feed: WidgetFeed?, now: Date) {
        self.kind = kind; self.family = family; self.feed = feed; self.now = now
    }

    public var body: some View {
        Group {
            if let feed, let focus = feed.focus(for: kind), focus.week != nil || focus.session != nil {
                let ctx = Context(feed: feed, focus: focus, copy: Copy(now: now), family: family)
                switch kind {
                case .burn: BurnWidget(ctx: ctx)
                case .pace: PaceWidget(ctx: ctx)
                case .session: SessionWidget(ctx: ctx)
                }
            } else {
                EmptyWidget(kind: kind, family: family, waiting: feed != nil)
            }
        }
        .padding(family == .systemSmall ? 13 : 15)
    }

    /// The surface for this widget: the focus provider's orb and, when it's hot, the state's glow.
    public static func surface(kind: HeadroomWidgetKind, feed: WidgetFeed?) -> WidgetSurface {
        let focus = feed?.focus(for: kind)
        var accent: PacingState?
        switch kind {
        case .burn:
            let ratios = [focus?.session?.burn.ratio, focus?.week?.burn.ratio].compactMap { $0 }
            accent = ratios.max().map { $0.isFinite ? BurnGauge.state($0) : .veryTight }
        case .pace: accent = focus?.week?.state
        case .session:
            if let s = focus?.session { accent = s.level >= .amber ? (s.level == .amber ? .tight : .veryTight) : nil }
        }
        return WidgetSurface(provider: focus?.id, accent: accent)
    }
}

extension WidgetFeed {
    /// The provider a one-provider widget shows: whichever needs watching most for what that widget draws.
    func focus(for kind: HeadroomWidgetKind) -> WidgetProvider? {
        let read = providers.filter { $0.week != nil || $0.session != nil }
        func burn(_ p: WidgetProvider) -> Double {
            let r = [p.session.flatMap { $0.isIdle ? nil : $0.burn.ratio }, p.week?.burn.ratio].compactMap { $0 }.max() ?? 0
            return r.isFinite ? r : 1000
        }
        func session(_ p: WidgetProvider) -> Double {
            guard let s = p.session else { return -1 }
            return s.isIdle ? 0 : 1 + Double(s.level.rawValue) * 2 + s.used
        }
        func week(_ p: WidgetProvider) -> Double {
            guard let w = p.week else { return -1 }
            return Double(w.state.rawValue) * 2 + (1 - w.left)
        }
        let pick: [WidgetProvider]
        switch kind {
        case .burn: pick = read.sorted { burn($0) > burn($1) }
        case .session: pick = read.sorted { session($0) > session($1) }
        case .pace: pick = read.sorted { (p: WidgetProvider, q: WidgetProvider) in
            (p.blockedUntil != nil ? 100 : week(p)) > (q.blockedUntil != nil ? 100 : week(q)) }
        }
        return pick.first ?? providers.first
    }
}

struct Context {
    var feed: WidgetFeed
    var focus: WidgetProvider
    var copy: Copy
    var family: WidgetFamily

    var stale: Bool { copy.now.timeIntervalSince(feed.generatedAt) > 20 * 60 }
    var others: [WidgetProvider] { feed.providers.filter { $0.week != nil || $0.session != nil } }
}

/// "Updated 2h ago" with an amber dot, when the app hasn't written for a while.
struct StaleNote: View {
    var ctx: Context
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if ctx.stale {
            HStack(spacing: 4) {
                Dot(color: Palette(scheme).stale, size: 4)
                Text(ctx.copy.ago(ctx.feed.generatedAt)).font(Fonts.text(8.5, .semibold)).foregroundStyle(Palette(scheme).muted2)
            }
        }
    }
}

// MARK: - Burn-o-meter

struct BurnWidget: View {
    var ctx: Context
    @Environment(\.colorScheme) private var scheme

    private struct Reading {
        var label: String
        var burn: WidgetBurn
        var left: Double
        var resetsAt: Date?
        var idle: Bool
        /// The forecast the session ring and the Pace graph show, so every widget tells the same story.
        var runsOutAt: Date? = nil
        var leftAtReset: Double? = nil
    }

    private var session: Reading? {
        guard let s = ctx.focus.session else { return nil }
        return Reading(label: "5-hour", burn: s.burn, left: s.left, resetsAt: s.resetsAt, idle: s.isIdle,
                       runsOutAt: s.runsOutAt, leftAtReset: s.leftAtReset)
    }

    private var week: Reading? {
        guard let w = ctx.focus.week else { return nil }
        var r = Reading(label: w.caption.contains("month") ? "Month" : "Week", burn: w.burn, left: w.left, resetsAt: w.resetsAt, idle: false)
        if let c = w.chart {
            if c.runsOut { r.runsOutAt = c.start.addingTimeInterval(c.endT * 3600) } else { r.leftAtReset = c.endRemaining }
        }
        return r
    }

    var body: some View {
        switch ctx.family {
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    // The busier of the two: the session while one runs, else the week.
    private var small: some View {
        let r = (session.flatMap { $0.idle ? nil : $0 } ?? week ?? session)!
        let p = Palette(scheme)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                BrandTile(provider: ctx.focus.id, size: 14)
                Caps("Burn", size: 8.5, color: p.muted)
                Spacer(minLength: 2)
                if ctx.stale { StaleNote(ctx: ctx) } else { WindowChip(text: r.label) }
            }
            dial(r, caption: safe(r), scale: true)
                .padding(.top, 6)
                .frame(maxHeight: .infinity)
            status(r, size: 9.5)
        }
    }

    private var medium: some View {
        VStack(spacing: 6) {
            ProviderHeader(provider: ctx.focus, tile: 15, trailing: ctx.stale ? nil : "Burn-o-meter")
                .overlay(alignment: .trailing) { StaleNote(ctx: ctx) }
            HStack(spacing: 10) {
                column(session)
                Rectangle().fill(Palette(scheme).separator).frame(width: 1).padding(.vertical, 8)
                column(week)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var large: some View {
        let p = Palette(scheme)
        return VStack(spacing: 8) {
            ProviderHeader(provider: ctx.focus, tile: 18, trailing: ctx.stale ? nil : "Burn-o-meter")
                .overlay(alignment: .trailing) { StaleNote(ctx: ctx) }
            HStack(spacing: 12) {
                column(session, statusSize: 10)
                Rectangle().fill(p.separator).frame(width: 1).padding(.vertical, 12)
                column(week, statusSize: 10)
            }
            .frame(maxHeight: .infinity)
            TokensPanel(provider: ctx.focus, tone: p.tone(ctx.focus.week?.state ?? .plenty)).fixedSize(horizontal: false, vertical: true)
            if let verdict = ctx.focus.week?.verdict, !verdict.isEmpty {
                Text(verdict).font(Fonts.text(10.5, .medium)).foregroundStyle(p.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func column(_ r: Reading?, statusSize: CGFloat = 9) -> some View {
        if let r {
            VStack(spacing: 4) {
                dial(r, caption: r.label, scale: true).frame(maxHeight: .infinity)
                status(r, size: statusSize)
                if ctx.family == .systemLarge, let safe = safe(r) {
                    Text(safe.prefix(1).uppercased() + safe.dropFirst()).font(Fonts.text(9, .medium)).foregroundStyle(Palette(scheme).muted2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 6) {
                SpeedDial(ratio: nil, average: nil, value: "—", caption: "No limit", dim: true)
                Text("Not tracked on this plan").font(Fonts.text(9, .medium)).foregroundStyle(Palette(scheme).muted2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func dial(_ r: Reading, caption: String?, scale: Bool) -> some View {
        let ratio: Double? = r.left <= 0.0005 ? .infinity : (r.idle ? 0 : r.burn.ratio)
        let readout = SpeedDial.readout(perHour: r.idle ? 0 : r.burn.perHour, ratio: ratio)
        return SpeedDial(ratio: ratio, average: r.idle ? nil : r.burn.averageRatio, value: readout.value, unit: readout.unit,
                         caption: caption, scale: scale, dim: ctx.stale)
    }

    /// "safe to 119%/h": the speed at the dial's 1× mark, the most it can run and still last.
    private func safe(_ r: Reading) -> String? {
        guard !r.idle, r.left > 0.0005, let lasting = r.burn.lastingPerHour, lasting > 0, lasting.isFinite else { return nil }
        return "safe to \(SpeedDial.rate(lasting))%/h"
    }

    private func status(_ r: Reading, size: CGFloat) -> some View {
        let p = Palette(scheme)
        let (text, state) = ctx.copy.burn(r.burn, left: r.left, resetsAt: r.resetsAt, idle: r.idle,
                                          runsOutAt: r.runsOutAt, leftAtReset: r.leftAtReset)
        let color = state.map { $0 == .onPace ? p.ink : p.tone($0).text } ?? p.muted
        return HStack(spacing: 4) {
            Dot(color: color, size: 4.5)
            Text(text).font(Fonts.text(size, .semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// "5H" / "WEEK" in a quiet pill.
struct WindowChip: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        Caps(text, size: 7.5, color: p.muted)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(p.chipFill))
            .overlay(Capsule().strokeBorder(p.chipBorder, lineWidth: 0.5))
    }
}

/// The odometer, the API-rate cost and the last day hour by hour.
struct TokensPanel: View {
    var provider: WidgetProvider
    var tone: Tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Caps("Tokens · last 24 hours", size: 7.5)
                    Odometer(text: NumberFormat.tokens(provider.tokens24h), height: 24)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(NumberFormat.dollars(provider.cost24hUSD, style: .precise))
                        .font(Fonts.number(17)).foregroundStyle(p.ink)
                    Caps("at API rates", size: 7.5)
                }
            }
            HourBars(tokens: provider.hourlyTokens, provider: provider.id, tone: tone).frame(height: 24)
            HStack {
                Caps("24h ago", size: 7)
                Spacer()
                Caps("Now", size: 7, color: tone.text)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.groupFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.groupBorder, lineWidth: 0.5))
    }
}

// MARK: - Pace

struct PaceWidget: View {
    var ctx: Context
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch ctx.family {
        case .systemSmall: small
        case .systemLarge: large
        default:
            if ctx.others.filter({ $0.week != nil }).count > 1 { overview } else { medium }
        }
    }

    private var small: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                BrandTile(provider: ctx.focus.id, size: 16)
                if let plan = ctx.focus.plan { PlanPill(provider: ctx.focus.id, text: plan) }
                Spacer(minLength: 2)
                StaleNote(ctx: ctx)
            }
            Spacer(minLength: 4)
            if let w = ctx.focus.week {
                Hero(left: w.left, size: 40)
                Text(w.caption).font(Fonts.text(10, .medium)).foregroundStyle(p.muted).lineLimit(1).padding(.top, 1)
                CellMeter(state: w.state, cells: w.cells, caret: w.caret, height: 11, dim: ctx.stale).padding(.top, 9)
                RenewLine(week: w, copy: ctx.copy).padding(.top, 3)
            } else if let s = ctx.focus.session {
                Hero(left: s.left, size: 40)
                Text("left this session").font(Fonts.text(10, .medium)).foregroundStyle(p.muted)
            }
        }
    }

    private var medium: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderHeader(provider: ctx.focus, tile: 15)
                StaleNote(ctx: ctx)
                if let w = ctx.focus.week { StateChip(state: w.state, title: w.verdictTitle) }
            }
            if let w = ctx.focus.week {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        Hero(left: w.left, size: 38)
                        Text(w.caption).font(Fonts.text(10, .medium)).foregroundStyle(p.muted).lineLimit(1)
                        CellMeter(state: w.state, cells: w.cells, caret: w.caret, height: 10, dim: ctx.stale).padding(.top, 8)
                        RenewLine(week: w, copy: ctx.copy).padding(.top, 3)
                    }
                    .frame(width: 118)
                    if let chart = w.chart {
                        GlideChartView(chart: chart, tone: p.tone(w.state), nowChip: false)
                    }
                }
            }
        }
    }

    /// Both providers, one row each.
    private var overview: some View {
        let rows = ctx.others.filter { $0.week != nil }.prefix(2)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, provider in
                if i > 0 { Rectangle().fill(Palette(scheme).separator).frame(height: 1).padding(.vertical, 2) }
                OverviewRow(provider: provider, copy: ctx.copy, dim: ctx.stale).frame(maxHeight: .infinity)
            }
        }
    }

    private var large: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                ProviderHeader(provider: ctx.focus, tile: 18)
                StaleNote(ctx: ctx)
            }
            if let w = ctx.focus.week {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Hero(left: w.left, size: 44)
                        Text(w.caption).font(Fonts.text(10.5, .medium)).foregroundStyle(p.muted).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 4) {
                            if w.hourglass { Hourglass(color: p.azure, height: 17) }
                            Text(TimeFormat.compact(max(0, w.resetsAt.timeIntervalSince(ctx.copy.now))))
                                .font(Fonts.number(26)).foregroundStyle(p.ink)
                        }
                        Text(TimeFormat.renewalCaption(w.resetsAt, now: ctx.copy.now, calendar: ctx.copy.calendar, locale: ctx.copy.locale))
                            .font(Fonts.text(10.5, .medium)).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                .padding(.top, 10)
                CellMeter(state: w.state, cells: w.cells, caret: w.caret, height: 13, dim: ctx.stale).padding(.top, 10)
                if let chart = w.chart {
                    GlideChartView(chart: chart, tone: p.tone(w.state)).frame(maxHeight: .infinity).padding(.top, 8)
                }
                HStack {
                    StateChip(state: w.state, title: w.verdictTitle)
                    Spacer()
                    if let m = w.multiple { Text(NumberFormat.multiple(m, suffix: "pace")).font(Fonts.number(10, .semibold)).foregroundStyle(p.muted) }
                }
                .padding(.top, 8)
                Text(w.verdict).font(Fonts.text(11, .medium)).foregroundStyle(p.ink).lineLimit(2).padding(.top, 5)
            }
            if let s = ctx.focus.session {
                SessionRow(session: s, copy: ctx.copy).padding(.top, 10)
            }
        }
    }
}

/// "82%" with a smaller percent sign, as the Pace card sets it.
struct Hero: View {
    var left: Double
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int((max(0, left) * 100).rounded()))")
                .font(.system(size: size, weight: .semibold).monospacedDigit()).tracking(-size * 0.035)
                .foregroundStyle(p.ink).widgetAccentable()
            Text("%").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(p.muted)
                .baselineOffset(size * 0.33)
        }
    }
}

struct RenewLine: View {
    var week: WidgetWeek
    var copy: Copy
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 4) {
            if week.hourglass { Hourglass(color: p.azure, height: 9) }
            Text(copy.renews(week.resetsAt)).font(Fonts.text(9.5, .semibold)).foregroundStyle(week.hourglass ? p.azure : p.muted2).lineLimit(1)
        }
    }
}

/// "Plenty available" with the state's dot.
struct StateChip: View {
    var state: PacingState
    var title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), t = p.tone(state)
        HStack(spacing: 5) {
            Dot(color: t.text, size: 5)
            Text(title.isEmpty ? state.title : title).font(Fonts.text(9.5, .semibold)).foregroundStyle(t.text).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(t.text.opacity(p.dark ? 0.12 : 0.09)))
        .overlay(Capsule().strokeBorder(t.text.opacity(0.22), lineWidth: 0.5))
    }
}

struct OverviewRow: View {
    var provider: WidgetProvider
    var copy: Copy
    var dim: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 10) {
            BrandTile(provider: provider.id, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(provider.id.displayName).font(Fonts.text(12.5, .semibold)).foregroundStyle(p.ink)
                    if let plan = provider.plan { PlanPill(provider: provider.id, text: plan) }
                }
                if let w = provider.week {
                    Text(copy.renews(w.resetsAt)).font(Fonts.text(9.5, .medium)).foregroundStyle(p.muted2).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let w = provider.week {
                CellMeter(state: w.state, cells: w.cells, height: 10, dim: dim).frame(width: 74)
                Text(copy.percent(w.left)).font(Fonts.number(19)).foregroundStyle(p.ink).frame(width: 46, alignment: .trailing)
            }
            if let s = provider.session, !s.isIdle {
                let t = Palette(scheme).session(s)
                ZStack {
                    Ring(fraction: s.left, tone: t, width: 2.6).frame(width: 20, height: 20)
                }
                .frame(width: 20)
            }
        }
    }
}

struct SessionRow: View {
    var session: WidgetSession
    var copy: Copy
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), t = p.session(session)
        HStack(spacing: 9) {
            Ring(fraction: session.left, tone: t, width: 3).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.isIdle ? "5-hour session · ready" : "5-hour session · \(copy.percent(session.left)) left")
                    .font(Fonts.text(11, .semibold)).foregroundStyle(p.ink)
                Text(copy.session(session)).font(Fonts.text(9.5, .medium))
                    .foregroundStyle(session.outlook == .runsOut || session.outlook == .blocked ? t.text : p.muted).lineLimit(1)
            }
            Spacer()
            if let r = session.resetsAt, r > copy.now {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(TimeFormat.countdown(r.timeIntervalSince(copy.now))).font(Fonts.number(15)).foregroundStyle(session.level >= .amber ? t.text : p.ink)
                    Caps("to reset", size: 7)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.groupFill))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.groupBorder, lineWidth: 0.5))
    }
}

// MARK: - 5-hour session

struct SessionWidget: View {
    var ctx: Context
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let s = ctx.focus.session {
            switch ctx.family {
            case .systemSmall: small(s)
            default: medium(s)
            }
        } else {
            EmptyWidget(kind: .session, family: ctx.family, waiting: false, message: "No 5-hour limit on this plan.")
        }
    }

    private func small(_ s: WidgetSession) -> some View {
        let p = Palette(scheme)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                BrandTile(provider: ctx.focus.id, size: 14)
                Caps("5-hour", size: 8.5, color: p.muted)
                Spacer(minLength: 2)
                StaleNote(ctx: ctx)
            }
            CountdownRing(session: s, copy: ctx.copy, width: 8.5).padding(.vertical, 7).frame(maxHeight: .infinity)
            forecast(s, size: 9.5)
        }
    }

    private func medium(_ s: WidgetSession) -> some View {
        let p = Palette(scheme)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    BrandTile(provider: ctx.focus.id, size: 15)
                    Caps("5-hour session", size: 8.5, color: p.muted)
                }
                CountdownRing(session: s, copy: ctx.copy, width: 8).padding(.vertical, 8).frame(maxHeight: .infinity)
                forecast(s, size: 9)
            }
            .frame(width: 118)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Caps(s.isIdle ? "Last 24 hours" : "This session", size: 7.5)
                    Spacer()
                    StaleNote(ctx: ctx)
                }
                if let chart = s.chart {
                    GlideChartView(chart: chart, tone: p.session(s))
                } else {
                    Spacer()
                    Text("Sessions show here as you use them.").font(Fonts.text(10, .medium)).foregroundStyle(p.muted2)
                    Spacer()
                }
            }
        }
    }

    private func forecast(_ s: WidgetSession, size: CGFloat) -> some View {
        let p = Palette(scheme), t = p.session(s)
        let hot = s.outlook == .runsOut || s.outlook == .blocked
        return HStack(spacing: 4) {
            Dot(color: s.isIdle ? p.muted2 : t.text, size: 4.5)
            Text(ctx.copy.session(s)).font(Fonts.text(size, .semibold)).foregroundStyle(hot ? t.text : p.muted)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

/// The ring of what's left of the session, with the live countdown to its reset inside.
struct CountdownRing: View {
    var session: WidgetSession
    var copy: Copy
    var width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), t = p.session(session)
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                Ring(fraction: session.left, tone: t, width: width)
                VStack(spacing: d * 0.015) {
                    if let r = session.resetsAt, r > copy.now {
                        Text(timerInterval: copy.now...r, countsDown: true)
                            .font(.system(size: d * 0.165, weight: .semibold).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(session.level >= .amber ? t.text : p.ink)
                            .widgetAccentable()
                            .frame(width: d * 0.74)
                        Caps(session.outlook == .blocked ? "until back" : "to reset", size: max(6.5, d * 0.065))
                        Text("\(copy.percent(session.left)) left").font(.system(size: d * 0.085, weight: .semibold).monospacedDigit())
                            .foregroundStyle(p.muted).padding(.top, d * 0.02)
                    } else {
                        Text("Ready").font(.system(size: d * 0.17, weight: .semibold)).foregroundStyle(p.ink)
                        Caps("No session", size: max(6.5, d * 0.065))
                    }
                }
            }
            .frame(width: d, height: d)
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - Empty

struct EmptyWidget: View {
    var kind: HeadroomWidgetKind
    var family: WidgetFamily
    var waiting: Bool
    var message: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(spacing: family == .systemSmall ? 8 : 10) {
            HeadroomMarkView(size: family == .systemSmall ? 38 : 46)
            VStack(spacing: 3) {
                Text(message ?? (waiting ? "Waiting for a reading…" : "Open Headroom"))
                    .font(Fonts.text(family == .systemSmall ? 12 : 13, .semibold)).foregroundStyle(p.ink)
                    .multilineTextAlignment(.center)
                if message == nil {
                    Text(waiting ? "Your limits show here as soon as they're read." : "Your limits show here while it runs in the menu bar.")
                        .font(Fonts.text(family == .systemSmall ? 9.5 : 10.5, .medium)).foregroundStyle(p.muted)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
