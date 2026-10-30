import CoreData
import Foundation
import HeadroomKit
import Observation

/// What the iPhone, iPad and Watch apps show: the merged accounts and the widget feed built from
/// them, kept current as records arrive and as time passes (resets roll over by the clock).
@MainActor
@Observable
public final class SyncReaderModel {
    public private(set) var snapshot = SyncSnapshot()
    public private(set) var feed = WidgetFeed(generatedAt: .distantPast, providers: [])
    /// True once the first read finished (the empty state waits for it).
    public private(set) var loaded = false
    public private(set) var lastError: String?
    /// The moment everything is drawn as of; advances every minute.
    public private(set) var now = Date()
    public private(set) var isDemo: Bool

    /// Called after every rebuild, with the new feed (widgets, Live Activity, notifications, watch).
    @ObservationIgnored public var onRebuild: ((SyncReaderModel) -> Void)?

    @ObservationIgnored private var source: any SyncReading
    @ObservationIgnored private var records = SyncRecords()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    public init(source: any SyncReading, isDemo: Bool = false) {
        self.source = source
        self.isDemo = isDemo
    }

    /// Starts reading: now, on every store change (debounced), and once a minute for the clock.
    public func start() {
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        Task { await reload() }
    }

    /// Swaps the live store for demo data, or back.
    public func use(_ source: any SyncReading, isDemo: Bool) async {
        self.source = source
        self.isDemo = isDemo
        await reload()
    }

    /// Re-reads every record and rebuilds.
    public func reload() async {
        pendingReload = nil
        do {
            records = try await source.records()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        rebuild(at: Date())
        loaded = true
    }

    /// Store changes arrive in bursts during an import; wait for it to settle.
    public func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// The clock moved: countdowns, staleness and rollover change without new records.
    public func tick() { rebuild(at: Date()) }

    private func rebuild(at date: Date) {
        now = date
        snapshot = AccountReader(now: date).read(records)
        feed = ReaderFeed.build(snapshot, now: date)
        onRebuild?(self)
    }

    // MARK: What the screens ask

    public var accounts: [MergedAccount] { snapshot.accounts }
    public var activeAccounts: [MergedAccount] { snapshot.accounts.filter(\.isActive) }
    public var inactiveAccounts: [MergedAccount] { snapshot.accounts.filter { !$0.isActive } }
    public var hasMac: Bool { !snapshot.devices.isEmpty }

    /// Every Mac has gone quiet for half an hour (asleep, off, or sync turned off).
    public var macsQuiet: Bool {
        guard let last = snapshot.lastHeard else { return false }
        return now.timeIntervalSince(last) > 30 * 60
    }

    public func widgetProvider(_ account: MergedAccount) -> WidgetProvider? { feed.account(account.id) }
}
