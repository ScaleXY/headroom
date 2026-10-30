import HeadroomKit
import SwiftUI
import WidgetKit

#if !os(watchOS)

// The widgets only the iPhone and iPad have: every account at once, the activity chart, the
// 5-hour session at large and the Pace dashboard at extra large (iPad).

/// Which accounts the Accounts widget lists.
public enum AccountsFilter: String, CaseIterable, Sendable {
    case all, claude, codex

    func admits(_ p: WidgetProvider) -> Bool {
        switch self {
        case .all: true
        case .claude: p.id == .claude
        case .codex: p.id == .codex
        }
    }
}

// MARK: - Accounts

/// One row per account, most urgent first: week meter and percent, renewal, and the session ring.
public struct AccountsWidget: View {
    public var feed: WidgetFeed
    public var family: WidgetFamily
    public var now: Date
    public var filter: AccountsFilter
    public var includeInactive: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.drawnOffscreen) private var offscreen

    public init(feed: WidgetFeed, family: WidgetFamily, now: Date, filter: AccountsFilter = .all, includeInactive: Bool = false) {
        self.feed = feed; self.family = family; self.now = now; self.filter = filter; self.includeInactive = includeInactive
    }

    var rows: [WidgetProvider] {
        feed.providers
            .filter { ($0.week != nil || $0.session != nil) && filter.admits($0) && (includeInactive || $0.isActive != false) }
            .sorted { urgency($0) > urgency($1) }
    }

    func urgency(_ p: WidgetProvider) -> Double {
        if p.blockedUntil != nil { return 100 }
        return Double(p.week?.state.rawValue ?? 0) * 2 + (1 - (p.week?.left ?? 1)) + (p.session.map { $0.isIdle ? 0 : Double($0.level.rawValue) } ?? 0)
    }

    var limit: Int {
        switch family {
        case .systemMedium: 3
        case .systemLarge: 6
        default: 8
        }
    }

    public var body: some View {
        let p = Palette(scheme), copy = Copy(now: now)
        let shown = Array(rows.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HeadroomMarkView(size: 16)
                Caps("Accounts", size: 8.5, color: p.muted)
                Spacer()
                if now.timeIntervalSince(feed.generatedAt) > 20 * 60 {
                    Dot(color: p.stale, size: 4)
                    Text(copy.ago(feed.generatedAt)).font(Fonts.text(8.5, .semibold)).foregroundStyle(p.muted2)
                }
            }
            .padding(.bottom, 8)
            if shown.isEmpty {
                Spacer()
                Text("No accounts yet").font(Fonts.text(12, .semibold)).foregroundStyle(p.muted).frame(maxWidth: .infinity)
                Spacer()
            } else if family == .systemExtraLarge {
                let half = (shown.count + 1) / 2
                HStack(alignment: .top, spacing: 16) {
                    column(Array(shown.prefix(half)), copy: copy)
                    column(Array(shown.dropFirst(half)), copy: copy)
                }
                Spacer(minLength: 0)
            } else {
                column(shown, copy: copy)
                Spacer(minLength: 0)
            }
        }
    }

    private func column(_ list: [WidgetProvider], copy: Copy) -> some View {
        let p = Palette(scheme)
        return VStack(spacing: family == .systemMedium ? 6 : 9) {
            ForEach(list, id: \.key) { a in
                let row = VStack(alignment: .leading, spacing: 2) {
                    OverviewRow(provider: a, copy: copy, dim: now.timeIntervalSince(feed.generatedAt) > 20 * 60)
                    if family != .systemMedium, let email = a.email {
                        Text(email).font(Fonts.text(9.5, .medium)).foregroundStyle(p.muted2).lineLimit(1).privacySensitive()
                            .padding(.leading, 36)
                    }
                }
                if offscreen { row } else { Link(destination: URL(string: "headroom://account/\(a.key)")!) { row } }
            }
        }
    }
}

// MARK: - Activity

/// Tokens by hour (24 hours, or 7 days) or by day (30 days), with cost at API prices.
public struct ActivityWidget: View {
    public var provider: WidgetProvider
    public var family: WidgetFamily
    public var now: Date
    @Environment(\.colorScheme) private var scheme

    public init(provider: WidgetProvider, family: WidgetFamily, now: Date) {
        self.provider = provider; self.family = family; self.now = now
    }

    var series: (tokens: [Int64], caption: String, cost: Double) {
        switch family {
        case .systemMedium:
            return (provider.hourlyTokens, "Last 24 hours", provider.cost24hUSD)
        case .systemLarge:
            // 168 hours in four-hour bars: thin enough to read, wide enough to see.
            let hours = provider.hourly7d ?? provider.hourlyTokens
            let week = stride(from: 0, to: hours.count, by: 4).map { hours[$0..<min($0 + 4, hours.count)].reduce(0, +) }
            let cost = provider.daily30.map { $0.suffix(7).reduce(0) { $0 + $1.costUSD } } ?? provider.cost24hUSD
            return (week, "Last 7 days", cost)
        default:
            let days = provider.daily30 ?? []
            return (days.map(\.tokens), "Last 30 days", days.reduce(0) { $0 + $1.costUSD })
        }
    }

    public var body: some View {
        let p = Palette(scheme)
        let s = series
        let tone = p.tone(provider.week?.state ?? .plenty)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BrandTile(provider: provider.id, size: 16)
                Text(provider.shortLabel ?? provider.id.displayName).font(Fonts.text(12, .semibold)).foregroundStyle(p.ink).lineLimit(1)
                Spacer()
                Caps(s.caption, size: 8, color: p.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NumberFormat.tokens(s.tokens.reduce(0, +))).font(Fonts.number(24)).foregroundStyle(p.ink)
                Text("tokens").font(Fonts.text(11, .medium)).foregroundStyle(p.muted)
                Spacer()
                Text(NumberFormat.dollars(s.cost)).font(Fonts.number(17)).foregroundStyle(tone.text)
            }
            HourBars(tokens: s.tokens, provider: provider.id, tone: tone).frame(maxHeight: .infinity)
            if family != .systemMedium, let models = provider.topModels, !models.isEmpty {
                VStack(spacing: 4) {
                    ForEach(models, id: \.name) { m in
                        HStack {
                            Text(m.name).font(Fonts.text(10.5, .medium)).foregroundStyle(p.ink).lineLimit(1)
                            Spacer()
                            Text(NumberFormat.tokens(m.tokens)).font(Fonts.number(10.5, .medium)).foregroundStyle(p.muted)
                            Text(NumberFormat.dollars(m.costUSD)).font(Fonts.number(10.5, .semibold)).foregroundStyle(p.ink).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            if family == .systemExtraLarge, let weeks = provider.pastWeeks, !weeks.isEmpty {
                HStack(alignment: .bottom, spacing: 6) {
                    Caps("Past weeks", size: 7.5, color: p.muted)
                    ForEach(weeks, id: \.end) { w in
                        RoundedRectangle(cornerRadius: 2).fill(w.ranOut ? p.rose : p.azure.opacity(0.75))
                            .frame(width: 12, height: max(3, 26 * w.finalUsed))
                    }
                }
                .frame(height: 30, alignment: .bottom)
            }
            if let weekly = provider.planWeeklyUSD, let weekCost = provider.weekCostUSD, family == .systemLarge {
                Text("\(NumberFormat.dollars(weekCost)) this week at API prices · plan \(NumberFormat.dollars(weekly))/wk")
                    .font(Fonts.text(9.5, .medium)).foregroundStyle(p.muted2).lineLimit(1)
            }
        }
    }
}

// MARK: - 5-hour session, large

/// The countdown ring, the session's graph with its trail, the forecast and the recent sessions.
public struct SessionLargeWidget: View {
    public var ctx: WidgetContext
    public var tracking: Bool?
    public var trackButton: AnyView?
    @Environment(\.colorScheme) private var scheme

    public init(ctx: WidgetContext, tracking: Bool? = nil, trackButton: AnyView? = nil) {
        self.ctx = ctx; self.tracking = tracking; self.trackButton = trackButton
    }

    public var body: some View {
        let p = Palette(scheme)
        if let s = ctx.focus.session {
            let t = p.session(s)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    BrandTile(provider: ctx.focus.id, size: 16)
                    Text(ctx.focus.shortLabel ?? ctx.focus.id.displayName).font(Fonts.text(12, .semibold)).foregroundStyle(p.ink)
                    Caps("5-hour", size: 8.5, color: p.muted)
                    Spacer()
                    StaleNote(ctx: ctx)
                    if let trackButton { trackButton }
                }
                HStack(spacing: 14) {
                    CountdownRing(session: s, copy: ctx.copy, width: 9).frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.isIdle ? "Ready" : "\(ctx.copy.percent(s.left)) left").font(Fonts.number(26)).foregroundStyle(p.ink)
                        CellMeter(state: s.tone, cells: PacingEngine.cells(remaining: s.left), height: 11)
                        Text(ctx.copy.session(s)).font(Fonts.text(11.5, .medium))
                            .foregroundStyle(s.outlook == .runsOut || s.outlook == .blocked ? t.text : p.muted).lineLimit(2)
                    }
                }
                if let chart = s.chart {
                    GlideChartView(chart: chart, tone: t).frame(maxHeight: .infinity)
                }
                if let recent = ctx.focus.recentSessions, !recent.isEmpty {
                    HStack(alignment: .bottom, spacing: 5) {
                        Caps("Recent", size: 7.5, color: p.muted)
                        ForEach(recent, id: \.resetsAt) { r in
                            RoundedRectangle(cornerRadius: 2).fill(r.hitLimit ? p.rose : p.tone(.plenty).text.opacity(0.75))
                                .frame(width: 10, height: max(3, 24 * r.peak))
                        }
                    }
                    .frame(height: 28, alignment: .bottom)
                }
            }
        } else {
            EmptyWidget(kind: .session, family: ctx.family, waiting: false, message: "No 5-hour limit on this plan.")
        }
    }
}

// MARK: - Pace, extra large (iPad)

/// The Pace card's pieces beside the 5-hour session and the Burn-o-meter.
public struct PaceDashboardWidget: View {
    public var ctx: WidgetContext
    @Environment(\.colorScheme) private var scheme

    public init(ctx: WidgetContext) { self.ctx = ctx }

    public var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeader(provider: ctx.focus, tile: 16, trailing: ctx.focus.shortLabel == ctx.focus.id.displayName ? nil : ctx.focus.email)
                if let w = ctx.focus.week {
                    HStack(alignment: .lastTextBaseline) {
                        Hero(left: w.left, size: 38)
                        Spacer()
                        RenewLine(week: w, copy: ctx.copy)
                    }
                    CellMeter(state: w.state, cells: w.cells, caret: w.caret, height: 11, dim: ctx.stale)
                    if let chart = w.chart {
                        GlideChartView(chart: chart, tone: p.tone(w.state)).frame(maxHeight: .infinity)
                    }
                    HStack(spacing: 8) {
                        StateChip(state: w.state, title: w.verdictTitle)
                        Text(w.verdict).font(Fonts.text(10.5, .medium)).foregroundStyle(p.ink).lineLimit(1)
                    }
                } else {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(spacing: 10) {
                if ctx.focus.session != nil {
                    SessionWidget(ctx: WidgetContext(feed: ctx.feed, focus: ctx.focus, copy: ctx.copy, family: .systemMedium))
                        .frame(maxHeight: .infinity)
                }
                BurnWidget(ctx: WidgetContext(feed: ctx.feed, focus: ctx.focus, copy: ctx.copy, family: .systemSmall))
                    .frame(maxHeight: .infinity)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.groupFill))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#endif
