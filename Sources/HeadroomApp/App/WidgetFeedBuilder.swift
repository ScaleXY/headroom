import Foundation
import HeadroomCore
import HeadroomKit
import HeadroomPresent
import WidgetKit

extension WidgetFeedBuilder {
    func build(model: AppModel) -> WidgetFeed {
        build(model.paceInputs(), presenter: model.presenter(now: now), buckets: model.buckets, outages: model.majorOutages)
    }

    /// The feed with each provider's last 24 hours read from the bucket store.
    func build(_ inputs: [PaceInput], presenter: Presenter, buckets: UsageBuckets, outages: [Provider: String] = [:]) -> WidgetFeed {
        let edges = hourEdges
        return build(inputs, presenter: presenter, hourly: { input in
            buckets.series(input.provider, edges: edges).map { HourTotal(tokens: $0.tokens.total, dollars: $0.dollars) }
        }, outages: outages)
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
