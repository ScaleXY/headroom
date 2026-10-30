import Foundation
import HeadroomKit
#if canImport(WatchConnectivity) && os(iOS)
import WatchConnectivity

/// Hands the Watch a compact feed for its complications. The phone is woken by syncs far more
/// often than the watch, and complication transfers have their own daily budget (about 50), so a
/// transfer goes out only when a color changes or half an hour has passed.
@MainActor
public final class WatchRelay: NSObject, WCSessionDelegate {
    private var lastLook: [Int] = []
    private var lastSent = Date.distantPast

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
              let data = try? SnapshotFile.encoder().encode(WatchFeed.compact(feed)) else { return }
        let look = FeedWriter.colors(FeedWriter.look(feed, kind: ""))
        let changed = look != lastLook
        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0,
           changed || Date().timeIntervalSince(lastSent) > 30 * 60 {
            session.transferCurrentComplicationUserInfo(["feed": data])
            lastSent = Date()
        } else {
            try? session.updateApplicationContext(["feed": data])
        }
        lastLook = look
    }

    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
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
