import Foundation
import HeadroomKit

/// Tokens and API-equivalent cost in one hourly bin.
public struct HourTotal: Sendable, Hashable {
    public var tokens: Int64
    public var dollars: Double
    public init(tokens: Int64, dollars: Double) { self.tokens = tokens; self.dollars = dollars }
}

/// Builds `widgets.json` from the same models the Pace card draws, so a widget and the popover
/// never disagree.
@MainActor
public struct WidgetFeedBuilder {
    public var now: Date

    public init(now: Date) { self.now = now }

    /// Edges of the last 24 hours, oldest first: 25 dates bounding 24 hourly bins.
    public var hourEdges: [Date] { (0...24).map { now.addingTimeInterval(Double($0 - 24) * 3600) } }

    /// The feed for these inputs. `hourly` returns each input's 24 bins over `hourEdges`.
    public func build(_ inputs: [PaceInput], presenter base: Presenter, hourly: (PaceInput) -> [HourTotal],
                      outages: [Provider: String] = [:]) -> WidgetFeed {
        var presenter = base
        // Widgets always get the full picture, whatever the Pace card hides.
        presenter.options.sessionDetail = .detailed
        presenter.options.parts = Set(CardPart.allCases)
        let providers = inputs.map { input -> WidgetProvider in
            var p = provider(input, presenter: presenter, outage: outages[input.provider])
            let hours = hourly(input)
            p.hourlyTokens = hours.map(\.tokens)
            p.tokens24h = p.hourlyTokens.reduce(0, +)
            p.cost24hUSD = (hours.reduce(0) { $0 + $1.dollars } * 100).rounded() / 100
            return p
        }
        return WidgetFeed(generatedAt: now, providers: providers)
    }

    public func provider(_ input: PaceInput, presenter: Presenter, outage: String?) -> WidgetProvider {
        var out = WidgetProvider(id: input.provider)
        out.fault = input.fault?.message(for: input.provider, lastGood: nil)
        guard let r = input.reading else { return out }
        out.plan = r.plan?.pill
        out.readingAt = r.fetchedAt
        let card = presenter.paceCard(input)

        if let headline = r.headline, headline.resetsAt != nil {
            let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: now, policy: presenter.policy)
            let hoursLeft = a.timeLeft / 3600
            out.week = WidgetWeek(
                caption: card.hero?.label ?? "left this week", left: a.remaining, state: input.smoothedState ?? a.state,
                multiple: a.multiple.isFinite ? (a.multiple * 100).rounded() / 100 : nil, cells: a.cells,
                caret: card.meter?.caret, resetsAt: a.resetsAt, hourglass: a.hourglass,
                verdictTitle: card.verdict?.title ?? "", verdict: card.verdict?.primary ?? "",
                burn: WidgetBurn(perHour: a.recentBurnPerHour ?? a.burnPerHour, averagePerHour: a.burnPerHour,
                                 lastingPerHour: hoursLeft > 0 ? a.remaining / hoursLeft : 0),
                chart: card.glide.map { chart($0, limit: 160) }
            )
        }

        if r.session != nil {
            let f = SessionForecast(window: r.session, samples: input.samples[LimitWindow.sessionID()] ?? [], now: now)
            let level = SessionStatus(window: r.session, now: now, policy: presenter.policy)?.level ?? .normal
            let elapsedHours = f.startedAt.map { now.timeIntervalSince($0) / 3600 } ?? 0
            let hoursLeft = f.timeLeft / 3600
            out.session = WidgetSession(
                used: f.isActive ? f.used : 0, resetsAt: f.isActive ? f.resetsAt : nil, startedAt: f.startedAt,
                level: level, outlook: f.outlook, runsOutAt: f.runsOutAt, leftAtReset: f.leftAtReset,
                burn: WidgetBurn(perHour: f.isActive ? f.burnPerHour : 0,
                                 averagePerHour: f.isActive && elapsedHours > 0.05 ? f.used / elapsedHours : nil,
                                 lastingPerHour: f.isActive ? (hoursLeft > 0 ? f.remaining / hoursLeft : 0) : 1),
                chart: card.sessionModule?.glide.map { chart($0, limit: 220) }
            )
        }

        if let mb = presenter.menuBar(input, majorOutage: outage),
           case .blocked(_, let until) = UrgencyResolver.headline(mb.urgency) {
            out.blockedUntil = until
        }
        if let micros = input.weekCostMicros { out.weekCostUSD = (Double(micros) / 10_000).rounded() / 100 }
        return out
    }

    public func chart(_ g: GlideModel, limit: Int) -> WidgetChart {
        let points = g.points.map { WidgetPoint(t: $0.t, u: $0.used, refill: $0.refill) }
        return WidgetChart(start: g.windowStart, hours: g.hours, nowT: g.nowT, points: BurnGauge.thin(points, limit: limit),
                           endT: g.projectionEnd.t, endRemaining: g.projectionEnd.remaining, runsOut: g.runsOut,
                           evenFrom: g.evenPaceFrom)
    }
}
