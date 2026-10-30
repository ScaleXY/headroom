import Foundation
import HeadroomCore
import HeadroomKit
import WidgetKit

/// Builds `widgets.json` from the same models the Pace card draws, so a widget and the popover
/// never disagree.
@MainActor
struct WidgetFeedBuilder {
    var now: Date

    func build(model: AppModel) -> WidgetFeed {
        build(model.paceInputs(), presenter: model.presenter(now: now), buckets: model.buckets, outages: model.majorOutages)
    }

    func build(_ inputs: [PaceInput], presenter base: Presenter, buckets: UsageBuckets, outages: [Provider: String] = [:]) -> WidgetFeed {
        var presenter = base
        // Widgets always get the full picture, whatever the Pace card hides.
        presenter.options.sessionDetail = .detailed
        presenter.options.parts = Set(CardPart.allCases)
        let edges = (0...24).map { now.addingTimeInterval(Double($0 - 24) * 3600) }
        let providers = inputs.map { input -> WidgetProvider in
            var p = provider(input, presenter: presenter, outage: outages[input.provider])
            let hours = buckets.series(input.provider, edges: edges)
            p.hourlyTokens = hours.map(\.tokens.total)
            p.tokens24h = p.hourlyTokens.reduce(0, +)
            p.cost24hUSD = (hours.reduce(0) { $0 + $1.dollars } * 100).rounded() / 100
            return p
        }
        return WidgetFeed(generatedAt: now, providers: providers)
    }

    func provider(_ input: PaceInput, presenter: Presenter, outage: String?) -> WidgetProvider {
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

    private func chart(_ g: GlideModel, limit: Int) -> WidgetChart {
        let points = g.points.map { WidgetPoint(t: $0.t, u: $0.used, refill: $0.refill) }
        return WidgetChart(start: g.windowStart, hours: g.hours, nowT: g.nowT, points: BurnGauge.thin(points, limit: limit),
                           endT: g.projectionEnd.t, endRemaining: g.projectionEnd.remaining, runsOut: g.runsOut,
                           evenFrom: g.evenPaceFrom)
    }
}

/// Keeps `widgets.json` current and asks WidgetKit to redraw, sparingly: WidgetKit budgets
/// reloads, so small moves wait a few minutes while a change of color goes out at once.
@MainActor
final class WidgetPublisher {
    private var lastBody: Data?
    private var lastLook: [Int]?
    private var lastReload = Date.distantPast
    private var pending: DispatchWorkItem?

    func update(_ feed: WidgetFeed) {
        var body = feed
        body.generatedAt = .distantPast
        guard let encoded = try? SnapshotFile.encoder().encode(body), encoded != lastBody else { return }
        lastBody = encoded
        guard let data = try? SnapshotFile.encoder().encode(feed) else { return }
        let url = WidgetFeed.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)

        let look = Self.look(feed)
        let urgent = lastLook.map { Self.colors($0) != Self.colors(look) } ?? true
        lastLook = look
        if urgent || Date().timeIntervalSince(lastReload) >= 300 {
            reload()
        } else if pending == nil {
            let work = DispatchWorkItem { [weak self] in self?.reload() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 300 - Date().timeIntervalSince(lastReload), execute: work)
        }
    }

    private func reload() {
        pending?.cancel()
        pending = nil
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What a widget visibly shows, coarsely: states and levels first, then whole percents and the needle.
    private static func look(_ feed: WidgetFeed) -> [Int] {
        feed.providers.flatMap { p -> [Int] in
            let ratio = { (b: WidgetBurn?) in b?.ratio.map { $0.isFinite ? Int(($0 * 10).rounded()) : 999 } ?? -1 }
            return [p.week?.state.rawValue ?? -1, p.session?.level.rawValue ?? -1, p.blockedUntil == nil ? 0 : 1, p.fault == nil ? 0 : 1,
                    BurnGauge.state(p.week?.burn.ratio ?? 0).rawValue, BurnGauge.state(p.session?.burn.ratio ?? 0).rawValue,
                    Int(((p.week?.left ?? 0) * 100).rounded()), Int(((p.session?.left ?? 0) * 100).rounded()),
                    ratio(p.week?.burn), ratio(p.session?.burn)]
        }
    }

    private static func colors(_ look: [Int]) -> [Int] {
        stride(from: 0, to: look.count, by: 10).flatMap { look[$0..<min($0 + 6, look.count)] }
    }
}
