import AppKit
import CoreData
import Foundation
import HeadroomCore
import HeadroomKit
import HeadroomSync
import os

private let syncLog = Logger(subsystem: "com.scalexy.headroom", category: "sync")

/// Posts this Mac's readings, history and activity to the user's private iCloud database, where
/// Headroom on iPhone, iPad and Apple Watch reads them. It only ever writes records stamped with
/// this Mac's ID, so Macs never conflict; the readers do the merging.
///
/// Cadence: a reading goes out at once when a color changes (pacing state, 5-hour level, fault) and
/// at most once a minute otherwise; activity at most every 5 minutes; a heartbeat every 10.
@MainActor
final class CloudPublisher {
    enum Status: Equatable {
        case off
        case unavailable(SyncCapability.Unavailable)
        case starting
        case synced(Date)
        case failed(String)
    }

    private(set) var status: Status = .off { didSet { if status != oldValue { onStatus?() } } }
    /// Called when `status` changes (Settings shows it).
    var onStatus: (() -> Void)?

    static let liveInterval: TimeInterval = 60
    static let activityInterval: TimeInterval = 300
    static let heartbeatInterval: TimeInterval = 600
    /// Activity kept in iCloud; the Activity tab's month view needs 30 days.
    static let activityDays = 35
    /// Accounts this Mac hasn't reported for this long are removed.
    static let staleAfter: TimeInterval = 90 * 86400

    let deviceID = DeviceIdentity.deviceID
    private var store: SyncStore?
    private weak var model: AppModel?
    /// Record key → the payload bytes last written.
    private var published: [String: Data] = [:]
    /// Account key → what a reader would color it, to send color changes at once.
    private var looks: [String: [Int]] = [:]
    private var lastLiveWrite = Date.distantPast
    private var lastActivityWrite = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var lastCollect = Date.distantPast
    private var power: DevicePowerState = .awake
    private var pending: Task<Void, Never>?
    private var dedupeTask: Task<Void, Never>?
    private var heartbeat: Timer?
    private var observers: [NSObjectProtocol] = []
    private var running = false

    var isRunning: Bool { running }

    // MARK: Lifecycle

    func start(model: AppModel) async {
        guard !running else { return }
        self.model = model
        status = .starting
        if let reason = await SyncCapability.check() {
            status = .unavailable(reason)
            return
        }
        do {
            let url = PlistStore<Int>.standardDirectory().appendingPathComponent("Sync/Headroom.store")
            store = SyncStore(container: try SyncContainer.make(.file(url), cloudKit: true))
        } catch {
            syncLog.error("sync store failed to open: \(String(describing: error), privacy: .public)")
            status = .failed("Couldn't open the sync store.")
            return
        }
        running = true
        observe()
        if model.settings.syncSince == nil { model.settings.syncSince = Date() }
        // Give the first import a moment, so a reinstalled Mac updates its old records instead of copying them.
        try? await Task.sleep(for: .seconds(20))
        guard running, let store else { return }
        try? await store.dedupe(deviceID: deviceID)
        await seed(from: store)
        await flush(force: true)
    }

    func stop() {
        running = false
        pending?.cancel(); pending = nil
        dedupeTask?.cancel(); dedupeTask = nil
        heartbeat?.invalidate(); heartbeat = nil
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        store = nil
        published.removeAll()
        looks.removeAll()
        status = .off
    }

    /// Something changed on the Mac: publish soon (coalesced).
    func update() {
        guard running, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.flush(force: false)
        }
    }

    /// Writes "quitting" so readers stop expecting this Mac. Best effort: the export may not finish.
    func quit() async {
        guard running else { return }
        power = .quitting
        await writeDevice(force: true)
    }

    /// Deletes every record this Mac wrote, then stops.
    func removeFromICloud() async {
        guard let store else { stop(); return }
        pending?.cancel()
        do {
            try await store.removeAll(deviceID: deviceID)
            // Mirroring exports in the background; give it a moment before the container goes away.
            try? await Task.sleep(for: .seconds(5))
        } catch {
            syncLog.error("remove failed: \(String(describing: error), privacy: .public)")
        }
        model?.settings.syncSince = nil
        stop()
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.power = .sleeping; Task { await self?.writeDevice(force: true) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.power = .awake; self?.update() }
        })
        // After each import, clean up any copies of this Mac's own records.
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDedupe() }
        })
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func scheduleDedupe() {
        guard dedupeTask == nil, let store else { return }
        let id = deviceID
        dedupeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            try? await store.dedupe(deviceID: id)
            self?.dedupeTask = nil
        }
    }

    /// Learns what this Mac already has in iCloud, so unchanged records aren't rewritten.
    private func seed(from store: SyncStore) async {
        guard let records = try? await store.records() else { return }
        for e in records.live where e.deviceID == deviceID { published[liveKey(e.provider, e.accountKey)] = try? PayloadCodec.encode(e.payload) }
        for e in records.archives where e.deviceID == deviceID { published[archiveKey(e.provider, e.accountKey)] = try? PayloadCodec.encode(e.payload) }
        for e in records.activity where e.deviceID == deviceID {
            published[activityKey(e.provider, e.accountKey, e.payload.day)] = try? PayloadCodec.encode(e.payload)
        }
    }

    // MARK: Publishing

    private func flush(force: Bool) async {
        pending = nil
        guard running, let store, let model else { return }
        let now = Date()
        var deferred = false
        do {
            await writeDevice(force: force)

            for item in livePayloads(model, now: now) {
                let key = liveKey(item.provider, item.accountKey)
                guard let data = try? PayloadCodec.encode(item.payload), data != published[key] else { continue }
                // Accounts no longer signed in here are written once (backfill), then left as they were.
                if !item.current, published[key] != nil { continue }
                let urgent = looks[key] != item.look
                if !force, !urgent, now.timeIntervalSince(lastLiveWrite) < Self.liveInterval { deferred = true; continue }
                try await store.upsertLive(deviceID: deviceID, provider: item.provider, accountKey: item.accountKey, payload: item.payload, now: now)
                published[key] = data
                looks[key] = item.look
                lastLiveWrite = now
            }

            for item in archivePayloads(model) {
                let key = archiveKey(item.provider, item.accountKey)
                guard let data = try? PayloadCodec.encode(item.payload), data != published[key] else { continue }
                try await store.upsertArchive(deviceID: deviceID, provider: item.provider, accountKey: item.accountKey, payload: item.payload, now: now)
                published[key] = data
            }

            if force || now.timeIntervalSince(lastActivityWrite) >= Self.activityInterval {
                for (k, payload) in activityPayloads(model, now: now) {
                    let key = activityKey(k.provider, k.accountKey, k.day)
                    guard let data = try? PayloadCodec.encode(payload), data != published[key] else { continue }
                    try await store.upsertActivity(deviceID: deviceID, provider: k.provider, accountKey: k.accountKey, payload: payload, now: now)
                    published[key] = data
                }
                lastActivityWrite = now
            } else {
                deferred = true
            }

            if now.timeIntervalSince(lastCollect) > 86400 {
                let today = Int((now.timeIntervalSince1970 / 86400).rounded(.down))
                try await store.collectGarbage(deviceID: deviceID, activityBefore: today - Self.activityDays,
                                               staleBefore: now.addingTimeInterval(-Self.staleAfter))
                lastCollect = now
            }
            status = .synced(now)
        } catch {
            syncLog.error("publish failed: \(String(describing: error), privacy: .public)")
            status = .failed("Couldn't save to iCloud. Headroom will try again.")
        }
        if deferred, pending == nil {
            let wait = max(5, Self.liveInterval - now.timeIntervalSince(lastLiveWrite))
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.flush(force: false)
            }
        }
    }

    private func writeDevice(force: Bool) async {
        guard let store, let model else { return }
        let now = Date()
        let payload = devicePayload(model)
        guard let data = try? PayloadCodec.encode(payload) else { return }
        do {
            if data != published["device"] {
                try await store.upsertDevice(deviceID, payload: payload, lastSeenAt: now, now: now)
                published["device"] = data
                lastHeartbeat = now
            } else if force || now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval {
                try await store.touchDevice(deviceID, lastSeenAt: now)
                lastHeartbeat = now
            }
        } catch {
            syncLog.error("device write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Payloads

    private func liveKey(_ p: Provider?, _ k: String) -> String { "live|\(p?.rawValue ?? "")|\(k)" }
    private func archiveKey(_ p: Provider?, _ k: String) -> String { "archive|\(p?.rawValue ?? "")|\(k)" }
    private func activityKey(_ p: Provider?, _ k: String, _ day: Int) -> String { "activity|\(p?.rawValue ?? "")|\(k)|\(day)" }

    /// The synced key for an account: its hash, or a key scoped to this Mac when the provider gave none.
    private func syncKey(_ p: Provider, _ account: String?) -> String {
        account ?? PayloadBuilder.deviceScopedKey(p, deviceID: deviceID)
    }

    /// The account each provider is signed in with on this Mac now.
    private func currentAccounts(_ model: AppModel) -> [Provider: String] {
        var out: [Provider: String] = [:]
        for p in Provider.allCases where model.settings.enabledProviders.contains(p) {
            if let r = model.faults[p]?.lastGood { out[p] = syncKey(p, r.accountKey) }
        }
        return out
    }

    private func devicePayload(_ model: AppModel) -> DevicePayload {
        let s = model.settings
        var prices: [String: Double] = [:]
        for p in Provider.allCases { if let v = s.planPriceOverride(p) { prices[p.rawValue] = v } }
        let info = Bundle.main.infoDictionary
        return DevicePayload(
            name: DeviceIdentity.name, model: DeviceIdentity.model,
            appVersion: info?["HeadroomVersion"] as? String ?? info?["CFBundleShortVersionString"] as? String ?? "dev",
            enabledProviders: Provider.allCases.filter { s.enabledProviders.contains($0) },
            currentAccounts: Dictionary(uniqueKeysWithValues: currentAccounts(model).map { ($0.key.rawValue, $0.value) }),
            sessionWarnAt: s.sessionWarnAt, planPriceOverrides: prices,
            outages: Dictionary(uniqueKeysWithValues: model.majorOutages.map { ($0.key.rawValue, $0.value) }),
            state: power, syncSince: s.syncSince)
    }

    private func livePayloads(_ model: AppModel, now: Date) -> [(provider: Provider, accountKey: String, payload: AccountLivePayload, current: Bool, look: [Int])] {
        let current = currentAccounts(model)
        let policy = model.settings.policy
        return model.history.accounts.compactMap { hkey, acct in
            guard let (p, account) = Self.split(hkey) else { return nil }
            let key = syncKey(p, account)
            let isCurrent = current[p] == key
            let machine = model.faults[p]
            let reading = isCurrent ? machine?.lastGood : nil
            let fault = isCurrent ? machine?.fault : nil
            let payload = PayloadBuilder.live(reading: reading, history: acct, fault: fault, faultAt: machine?.lastFailureAt,
                                              isCurrent: isCurrent, email: reading?.accountEmail)
            let level = SessionStatus(window: reading?.session, now: now, policy: policy)?.level.rawValue ?? -1
            let look = [acct.tracker?.shown?.rawValue ?? -1, level, fault == nil ? 0 : 1]
            return (p, key, payload, isCurrent, look)
        }
    }

    private func archivePayloads(_ model: AppModel) -> [(provider: Provider, accountKey: String, payload: AccountArchivePayload)] {
        model.history.accounts.compactMap { hkey, acct in
            guard let (p, account) = Self.split(hkey), !acct.weeks.isEmpty || !acct.sessions.isEmpty else { return nil }
            return (p, syncKey(p, account), PayloadBuilder.archive(acct))
        }
    }

    /// The last 35 days of this Mac's activity by quarter-hour and model, each slot attributed to
    /// the account signed in at the time. Projects never leave the Mac.
    private func activityPayloads(_ model: AppModel, now: Date) -> [ActivityDayKey: ActivityDayPayload] {
        let since = Int32(ActivitySlot.slot(for: now.addingTimeInterval(-Double(Self.activityDays) * 86400)))
        let current = currentAccounts(model)
        var merged: [String: (provider: Provider, accountKey: String, slot: ActivitySlot)] = [:]
        for s in model.buckets.allSlots where s.key.slot >= since {
            let p = s.key.provider
            let start = Date(timeIntervalSince1970: TimeInterval(Int(s.key.slot) * ActivitySlot.seconds))
            let key = model.timeline.account(p, at: start) ?? current[p] ?? syncKey(p, nil)
            let c = s.totals.cost
            let slot = ActivitySlot(slot: Int(s.key.slot), model: s.model, tokens: s.totals.tokens, micros: s.totals.micros,
                                    unpricedTokens: s.totals.unpricedTokens, classMicros: [c.input, c.cacheWrite, c.cacheRead, c.output])
            let id = "\(p.rawValue)|\(key)|\(s.key.slot)|\(s.model)"
            if var m = merged[id] {
                // The bucket store also splits by project; projects are summed away here.
                m.slot.tokens += slot.tokens
                m.slot.micros += slot.micros
                m.slot.unpricedTokens += slot.unpricedTokens
                m.slot.classMicros = zip(m.slot.classMicros, slot.classMicros).map { $0 + $1 }
                merged[id] = m
            } else {
                merged[id] = (p, key, slot)
            }
        }
        return PayloadBuilder.activityDays(Array(merged.values))
    }

    /// `HistoryStore` keys are `provider:accountKey` (or `provider:default`).
    nonisolated static func split(_ key: String) -> (Provider, String?)? {
        guard let colon = key.firstIndex(of: ":"), let p = Provider(rawValue: String(key[..<colon])) else { return nil }
        let account = String(key[key.index(after: colon)...])
        return (p, account == "default" ? nil : account)
    }
}
