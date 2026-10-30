import Foundation
import HeadroomKit
import HeadroomSync
import Observation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the Watch shows: the newer of its own iCloud mirror and the feed the iPhone relays.
/// The mirror works without the phone; the relay arrives more often, for complications.
@MainActor
@Observable
public final class WatchModel {
    public let reader: SyncReaderModel
    public private(set) var relayed: WidgetFeed?
    @ObservationIgnored private var lastWritten: Data?

    public init(live: (any SyncReading)?) {
        reader = SyncReaderModel(source: live ?? FixtureSyncStore(DemoRecords.make()), isDemo: live == nil)
        reader.onRebuild = { [weak self] _ in self?.publish() }
    }

    public static func demo(now: Date = Date()) -> WatchModel {
        let m = WatchModel(live: nil)
        Task { await m.reader.use(FixtureSyncStore(DemoRecords.make(now: now)), isDemo: true) }
        return m
    }

    public func start() { reader.start() }

    /// The feed to draw: whichever source heard from the Macs more recently.
    public var feed: WidgetFeed {
        let own = reader.feed
        guard let relayed else { return own }
        if own.providers.isEmpty { return relayed }
        return relayed.generatedAt > own.generatedAt ? relayed : own
    }

    public var now: Date { reader.now }

    public var accounts: [WidgetProvider] {
        feed.providers.filter { ($0.week != nil || $0.session != nil) && $0.isActive != false }
            .sorted { urgency($0) > urgency($1) }
    }

    func urgency(_ p: WidgetProvider) -> Double {
        if p.blockedUntil != nil { return 100 }
        let session = p.session.map { $0.isIdle ? 0 : Double($0.level.rawValue) * 1.5 } ?? 0
        return Double(p.week?.state.rawValue ?? 0) * 2 + session + (1 - (p.week?.left ?? 1))
    }

    /// A feed from the iPhone.
    public func receive(_ data: Data) {
        guard let feed = try? SnapshotFile.decoder().decode(WidgetFeed.self, from: data),
              feed.generatedAt > (relayed?.generatedAt ?? .distantPast) else { return }
        relayed = feed
        publish()
    }

    /// Leaves the current feed for the complications and asks them to redraw when it changed.
    private func publish() {
        var previous = lastWritten
        if FeedFile.write(feed, previous: &previous) {
            lastWritten = previous
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }
}

#if canImport(WatchConnectivity) && os(watchOS)
/// Receives the iPhone's compact feed (complication transfers and application context).
public final class PhoneRelayReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let deliver: @Sendable (Data) -> Void

    public init(deliver: @escaping @Sendable (Data) -> Void) {
        self.deliver = deliver
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let data = session.receivedApplicationContext["feed"] as? Data { deliver(data) }
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["feed"] as? Data { deliver(data) }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext["feed"] as? Data { deliver(data) }
    }
}
#endif
