import Foundation
import HeadroomKit
import HeadroomWidgetUI
import WidgetKit

/// Keeps `feed.json` current for the widget extension and asks WidgetKit to redraw sparingly:
/// WidgetKit budgets background reloads, so only the kinds whose content changed reload, a change
/// of color at once and anything else at most every five minutes (the Mac's `WidgetPublisher` rules).
@MainActor
public final class FeedWriter {
    private var lastData: Data?
    private var looks: [String: [Int]] = [:]
    private var reloaded: [String: Date] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    /// Reloads requested (for checking against the budget in TestFlight logs).
    public private(set) var reloadCount = 0

    public init() {}

    /// Every widget and complication kind the app's extensions offer.
    public static var kinds: [String] {
        HeadroomWidgetKind.allCases.map(\.kind) + ComplicationKind.allCases.map(\.kind)
    }

    public func write(_ feed: WidgetFeed, foreground: Bool) {
        var body = feed
        body.generatedAt = .distantPast
        guard let encoded = try? SnapshotFile.encoder().encode(body), encoded != lastData else { return }
        lastData = encoded
        var previous: Data?
        FeedFile.write(feed, previous: &previous)

        for kind in Self.kinds {
            let look = Self.look(feed, kind: kind)
            let urgent = looks[kind].map { Self.colors($0) != Self.colors(look) } ?? true
            guard looks[kind] != look else { continue }
            looks[kind] = look
            let last = reloaded[kind] ?? .distantPast
            // In the foreground reloads are free; in the background they spend the daily budget.
            if foreground || urgent || Date().timeIntervalSince(last) >= 300 {
                reload(kind)
            } else if pending[kind] == nil {
                let work = DispatchWorkItem { [weak self] in self?.reload(kind) }
                pending[kind] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 300 - Date().timeIntervalSince(last), execute: work)
            }
        }
    }

    private func reload(_ kind: String) {
        pending[kind]?.cancel()
        pending[kind] = nil
        reloaded[kind] = Date()
        reloadCount += 1
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// What a kind visibly shows, coarsely: states and levels first, then whole percents and burns.
    static func look(_ feed: WidgetFeed, kind: String) -> [Int] {
        let activity = kind.hasSuffix(".activity")
        return feed.providers.flatMap { p -> [Int] in
            if activity { return [Int(p.tokens24h / 10_000), Int(p.cost24hUSD)] }
            let ratio = { (b: WidgetBurn?) in b?.ratio.map { $0.isFinite ? Int(($0 * 10).rounded()) : 999 } ?? -1 }
            return [p.week?.state.rawValue ?? -1, p.session?.level.rawValue ?? -1, p.blockedUntil == nil ? 0 : 1, p.fault == nil ? 0 : 1,
                    BurnGauge.state(p.week?.burn.ratio ?? 0).rawValue, BurnGauge.state(p.session?.burn.ratio ?? 0).rawValue,
                    Int(((p.week?.left ?? 0) * 100).rounded()), Int(((p.session?.left ?? 0) * 100).rounded()),
                    ratio(p.week?.burn), ratio(p.session?.burn)]
        }
    }

    static func colors(_ look: [Int]) -> [Int] {
        guard look.count >= 6 else { return look }
        return stride(from: 0, to: look.count, by: 10).flatMap { look[$0..<min($0 + 6, look.count)] }
    }
}
