import Foundation
import HeadroomKit
import HeadroomSync
#if canImport(WatchConnectivity) && os(iOS)
import WatchConnectivity

/// Hands the Watch a compact feed for its complications. The phone is woken by syncs far more
/// often than the watch, and complication transfers have their own daily budget (about 50), so a
/// transfer goes out only when a color changes or half an hour has passed.
@MainActor
public final class WatchRelay: NSObject, WCSessionDelegate {
    private var lastLook: [Int] = []
    private var lastSent = Date.distantPast
    /// The `generatedAt` last put into the application context, the copy a Watch gets when it
    /// activates later. The Watch drops a feed that isn't newer, so resending one is wasted. A
    /// complication transfer doesn't count: it leaves the context as it was.
    private var contextSentAt: Date?

    public override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    public func send(_ feed: WidgetFeed) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              FeedFreshness.isNewer(feed.generatedAt, than: contextSentAt),
              let data = try? SnapshotFile.encoder().encode(WatchFeed.compact(feed)) else { return }
        let look = FeedWriter.colors(FeedWriter.look(feed, kind: ""))
        let changed = look != lastLook
        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0,
           changed || Date().timeIntervalSince(lastSent) > 30 * 60 {
            session.transferCurrentComplicationUserInfo(["feed": data])
            lastSent = Date()
        } else {
            if (try? session.updateApplicationContext(["feed": data])) != nil { contextSentAt = feed.generatedAt }
        }
        lastLook = look
    }

    /// A fresh activation or a new pairing may have a Watch with nothing yet: send the next feed whatever its stamp.
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.contextSentAt = nil }
    }
    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.contextSentAt = nil }
    }
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif

/// The feed as the Watch needs it: no long histories, small enough for a complication transfer.
public enum WatchFeed {
    public static func compact(_ feed: WidgetFeed) -> WidgetFeed {
        var out = feed
        out.providers = feed.providers.map { p in
            var c = p
            c.hourly7d = nil; c.daily30 = nil; c.topModels = nil; c.pastWeeks = nil; c.hourlyCostUSD = nil
            if var w = c.week, let chart = w.chart { w.chart = thin(chart, 60); c.week = w }
            if var s = c.session, let chart = s.chart { s.chart = thin(chart, 60); c.session = s }
            return c
        }
        return out
    }

    static func thin(_ chart: WidgetChart, _ limit: Int) -> WidgetChart {
        var c = chart
        c.points = BurnGauge.thin(chart.points, limit: limit)
        return c
    }
}
