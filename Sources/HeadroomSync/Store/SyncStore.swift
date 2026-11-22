import Foundation
import HeadroomKit
import SwiftData

/// Where the store lives and whether it mirrors to iCloud.
public enum SyncContainer {
    /// The iCloud container shared by the Mac, iPhone, iPad and Watch apps.
    public static let cloudKitIdentifier = "iCloud.com.scalexy.headroom"

    public enum Location: Sendable {
        /// A file the Mac owns (`~/Library/Application Support/Headroom/Sync/Headroom.store`).
        case file(URL)
        /// The App Group container, shared by the iOS or watchOS app and nothing else that writes.
        case appGroup(String)
        /// Tests and fixtures.
        case memory
    }

    public static func make(_ location: Location, cloudKit: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HeadroomSchemaV1.self)
        let database: ModelConfiguration.CloudKitDatabase = cloudKit ? .private(cloudKitIdentifier) : .none
        let config: ModelConfiguration
        switch location {
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            config = ModelConfiguration("Headroom", schema: schema, url: url, cloudKitDatabase: database)
        case .appGroup(let group):
            config = ModelConfiguration("Headroom", schema: schema, groupContainer: .identifier(group), cloudKitDatabase: database)
        case .memory:
            config = ModelConfiguration("Headroom", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: HeadroomMigrationPlan.self, configurations: [config])
    }
}

/// The SwiftData store, off the main actor. Macs write through it (only their own records);
/// iPhone, iPad and Watch only read.
public actor SyncStore: ModelActor, SyncReading {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(container: ModelContainer) {
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
    }

    // MARK: Reading

    /// A payload as decoded, with the bytes it came from: a record whose bytes haven't changed
    /// since the last read skips the decompress and JSON decode (about 20 ms for an account's
    /// activity, and nearly all of 35 days of it is unchanged between reloads).
    private struct Decoded<P> {
        let data: Data
        let value: P
    }

    private var deviceCache: [PersistentIdentifier: Decoded<DevicePayload>] = [:]
    private var liveCache: [PersistentIdentifier: Decoded<AccountLivePayload>] = [:]
    private var archiveCache: [PersistentIdentifier: Decoded<AccountArchivePayload>] = [:]
    private var activityCache: [PersistentIdentifier: Decoded<ActivityDayPayload>] = [:]
    /// How many payloads `records()` has really decoded (the rest came from the caches). For tests.
    private(set) var decodeCount = 0

    public func records() throws -> SyncRecords {
        var out = SyncRecords()
        var seen = Set<PersistentIdentifier>()
        for r in try modelContext.fetch(FetchDescriptor<DeviceRecord>()) {
            seen.insert(r.persistentModelID)
            guard let p = decode(r.payload, version: r.payloadVersion, id: r.persistentModelID, cache: &deviceCache, into: &out) else { continue }
            out.devices.append(DeviceEnvelope(deviceID: r.deviceID, updatedAt: r.updatedAt, lastSeenAt: r.lastSeenAt, payload: p))
        }
        deviceCache = deviceCache.filter { seen.contains($0.key) }
        seen.removeAll()
        for r in try modelContext.fetch(FetchDescriptor<AccountLiveRecord>()) {
            seen.insert(r.persistentModelID)
            guard let p = decode(r.payload, version: r.payloadVersion, id: r.persistentModelID, cache: &liveCache, into: &out) else { continue }
            out.live.append(Envelope(deviceID: r.deviceID, provider: Provider(rawValue: r.provider), accountKey: r.accountKey,
                                     updatedAt: r.updatedAt, payload: p))
        }
        liveCache = liveCache.filter { seen.contains($0.key) }
        seen.removeAll()
        for r in try modelContext.fetch(FetchDescriptor<AccountArchiveRecord>()) {
            seen.insert(r.persistentModelID)
            guard let p = decode(r.payload, version: r.payloadVersion, id: r.persistentModelID, cache: &archiveCache, into: &out) else { continue }
            out.archives.append(Envelope(deviceID: r.deviceID, provider: Provider(rawValue: r.provider), accountKey: r.accountKey,
                                         updatedAt: r.updatedAt, payload: p))
        }
        archiveCache = archiveCache.filter { seen.contains($0.key) }
        seen.removeAll()
        for r in try modelContext.fetch(FetchDescriptor<ActivityDayRecord>()) {
            seen.insert(r.persistentModelID)
            guard let p = decode(r.payload, version: r.payloadVersion, id: r.persistentModelID, cache: &activityCache, into: &out) else { continue }
            out.activity.append(Envelope(deviceID: r.deviceID, provider: Provider(rawValue: r.provider), accountKey: r.accountKey,
                                         day: r.day, updatedAt: r.updatedAt, payload: p))
        }
        activityCache = activityCache.filter { seen.contains($0.key) }
        return out
    }

    /// The version check comes first, so the too-new and unreadable counts don't depend on the cache.
    private func decode<P: Decodable>(_ data: Data?, version: Int, id: PersistentIdentifier,
                                      cache: inout [PersistentIdentifier: Decoded<P>], into out: inout SyncRecords) -> P? {
        guard version <= PayloadVersion.current else { out.tooNew += 1; out.unreadable += 1; return nil }
        guard let data else { out.unreadable += 1; return nil }
        if let hit = cache[id], hit.data == data { return hit.value }
        decodeCount += 1
        guard let p = try? PayloadCodec.decode(P.self, from: data) else { out.unreadable += 1; cache[id] = nil; return nil }
        cache[id] = Decoded(data: data, value: p)
        return p
    }

    /// What every Mac but `deviceID` synced about its runs: each one's device record (the newest
    /// of any copies, so a run is never listed twice; Macs with no runs left out) and, for the Macs
    /// with a finished run to price, their activity from `day` on. Read-only: another Mac's
    /// records are never written, deduped or deleted here.
    public func otherMacs(than deviceID: String, activitySince day: Int) throws -> OtherMacs {
        var scratch = SyncRecords()
        var newest: [String: DeviceEnvelope] = [:]
        var seen = Set<PersistentIdentifier>()
        for r in try modelContext.fetch(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID != deviceID })) {
            seen.insert(r.persistentModelID)
            guard let p = decode(r.payload, version: r.payloadVersion, id: r.persistentModelID, cache: &deviceCache, into: &scratch) else { continue }
            if let kept = newest[r.deviceID], (kept.updatedAt, kept.lastSeenAt) >= (r.updatedAt, r.lastSeenAt) { continue }
            newest[r.deviceID] = DeviceEnvelope(deviceID: r.deviceID, updatedAt: r.updatedAt, lastSeenAt: r.lastSeenAt, payload: p)
        }
        // Only a Mac reads this way, and after its first look it reads nothing else: what that
        // look decoded needn't stay in memory.
        deviceCache = deviceCache.filter { seen.contains($0.key) }
        // Chosen before the Macs with no runs are dropped, so a stale copy can't bring ended runs back.
        var out = OtherMacs(devices: newest.values.filter { $0.payload.runs != nil }.sorted { $0.deviceID < $1.deviceID })
        let priced = Set(out.devices.filter { $0.payload.runs?.contains { $0.state.isTerminal && $0.receipt?.models?.isEmpty == false } == true }.map(\.deviceID))
        seen.removeAll()
        if !priced.isEmpty {
            for r in try modelContext.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.deviceID != deviceID && $0.day >= day }))
            where priced.contains(r.deviceID) {
                seen.insert(r.persistentModelID)
                guard let p = decode(r.payload, version: r.payloadVersion, id: r.persistentModelID, cache: &activityCache, into: &scratch) else { continue }
                out.activity.append(Envelope(deviceID: r.deviceID, provider: Provider(rawValue: r.provider), accountKey: r.accountKey,
                                             day: r.day, updatedAt: r.updatedAt, payload: p))
            }
            out.activity.sort { ($0.key, $0.updatedAt) < ($1.key, $1.updatedAt) }
        }
        activityCache = activityCache.filter { seen.contains($0.key) }
        return out
    }

    // MARK: Writing (Macs only, and only their own records)

    public func upsertDevice(_ deviceID: String, payload: DevicePayload, lastSeenAt: Date, now: Date = Date()) throws {
        let data = try PayloadCodec.encode(payload)
        let found = try modelContext.fetch(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID == deviceID }))
        let record = keepNewest(found) ?? { let r = DeviceRecord(deviceID: deviceID); modelContext.insert(r); return r }()
        record.payload = data
        record.payloadVersion = PayloadVersion.current
        record.lastSeenAt = lastSeenAt
        record.updatedAt = now
        try modelContext.save()
    }

    /// Just the heartbeat, when nothing else changed.
    public func touchDevice(_ deviceID: String, lastSeenAt: Date) throws {
        let found = try modelContext.fetch(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID == deviceID }))
        guard let record = keepNewest(found) else { return }
        record.lastSeenAt = lastSeenAt
        try modelContext.save()
    }

    public func upsertLive(deviceID: String, provider: Provider, accountKey: String, payload: AccountLivePayload, now: Date = Date()) throws {
        let data = try PayloadCodec.encode(payload)
        let p = provider.rawValue
        let found = try modelContext.fetch(FetchDescriptor<AccountLiveRecord>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.provider == p && $0.accountKey == accountKey }))
        let record = keepNewest(found) ?? {
            let r = AccountLiveRecord(deviceID: deviceID, provider: p, accountKey: accountKey); modelContext.insert(r); return r
        }()
        record.payload = data
        record.payloadVersion = PayloadVersion.current
        record.readingAt = payload.reading?.fetchedAt
        record.updatedAt = now
        try modelContext.save()
    }

    public func upsertArchive(deviceID: String, provider: Provider, accountKey: String, payload: AccountArchivePayload, now: Date = Date()) throws {
        let data = try PayloadCodec.encode(payload)
        let p = provider.rawValue
        let found = try modelContext.fetch(FetchDescriptor<AccountArchiveRecord>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.provider == p && $0.accountKey == accountKey }))
        let record = keepNewest(found) ?? {
            let r = AccountArchiveRecord(deviceID: deviceID, provider: p, accountKey: accountKey); modelContext.insert(r); return r
        }()
        record.payload = data
        record.payloadVersion = PayloadVersion.current
        record.updatedAt = now
        try modelContext.save()
    }

    public func upsertActivity(deviceID: String, provider: Provider, accountKey: String, payload: ActivityDayPayload, now: Date = Date()) throws {
        let data = try PayloadCodec.encode(payload)
        let p = provider.rawValue, day = payload.day
        let found = try modelContext.fetch(FetchDescriptor<ActivityDayRecord>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.provider == p && $0.accountKey == accountKey && $0.day == day }))
        let record = keepNewest(found) ?? {
            let r = ActivityDayRecord(deviceID: deviceID, provider: p, accountKey: accountKey, day: day); modelContext.insert(r); return r
        }()
        record.payload = data
        record.payloadVersion = PayloadVersion.current
        record.updatedAt = now
        try modelContext.save()
    }

    /// The newest of several copies of one natural key, deleting the rest. Copies only appear when a
    /// reinstalled Mac wrote before its first import finished; they're all this Mac's own.
    private func keepNewest<R: PersistentModel>(_ found: [R]) -> R? where R: Timestamped {
        guard let newest = found.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        for r in found where r.persistentModelID != newest.persistentModelID { modelContext.delete(r) }
        return newest
    }

    /// Removes duplicate copies of this Mac's records (run after each import).
    public func dedupe(deviceID: String) throws {
        func sweep<R: PersistentModel & Timestamped>(_ records: [R], key: (R) -> String) {
            var newest: [String: R] = [:]
            for r in records {
                let k = key(r)
                if let kept = newest[k] {
                    if r.updatedAt > kept.updatedAt { modelContext.delete(kept); newest[k] = r } else { modelContext.delete(r) }
                } else {
                    newest[k] = r
                }
            }
        }
        sweep(try modelContext.fetch(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID == deviceID }))) { $0.deviceID }
        sweep(try modelContext.fetch(FetchDescriptor<AccountLiveRecord>(predicate: #Predicate { $0.deviceID == deviceID }))) { $0.provider + "|" + $0.accountKey }
        sweep(try modelContext.fetch(FetchDescriptor<AccountArchiveRecord>(predicate: #Predicate { $0.deviceID == deviceID }))) { $0.provider + "|" + $0.accountKey }
        sweep(try modelContext.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.deviceID == deviceID }))) {
            $0.provider + "|" + $0.accountKey + "|" + String($0.day)
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Drops this Mac's activity before `day`, and live and archive records for accounts it hasn't
    /// reported since `staleBefore`.
    public func collectGarbage(deviceID: String, activityBefore day: Int, staleBefore: Date) throws {
        for r in try modelContext.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.deviceID == deviceID && $0.day < day })) {
            modelContext.delete(r)
        }
        for r in try modelContext.fetch(FetchDescriptor<AccountLiveRecord>(predicate: #Predicate { $0.deviceID == deviceID && $0.updatedAt < staleBefore })) {
            let p = r.provider, k = r.accountKey
            for a in try modelContext.fetch(FetchDescriptor<AccountArchiveRecord>(
                predicate: #Predicate { $0.deviceID == deviceID && $0.provider == p && $0.accountKey == k })) {
                modelContext.delete(a)
            }
            modelContext.delete(r)
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Deletes every record a Mac wrote ("Remove Headroom data from iCloud", or stale-Mac cleanup).
    public func removeAll(deviceID: String) throws {
        try modelContext.delete(model: DeviceRecord.self, where: #Predicate { $0.deviceID == deviceID })
        try modelContext.delete(model: AccountLiveRecord.self, where: #Predicate { $0.deviceID == deviceID })
        try modelContext.delete(model: AccountArchiveRecord.self, where: #Predicate { $0.deviceID == deviceID })
        try modelContext.delete(model: ActivityDayRecord.self, where: #Predicate { $0.deviceID == deviceID })
        try modelContext.save()
    }

    /// Record counts, for the Mac's Settings status line and tests.
    public func counts(deviceID: String? = nil) throws -> (devices: Int, live: Int, archives: Int, activity: Int) {
        if let deviceID {
            return (try modelContext.fetchCount(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID == deviceID })),
                    try modelContext.fetchCount(FetchDescriptor<AccountLiveRecord>(predicate: #Predicate { $0.deviceID == deviceID })),
                    try modelContext.fetchCount(FetchDescriptor<AccountArchiveRecord>(predicate: #Predicate { $0.deviceID == deviceID })),
                    try modelContext.fetchCount(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.deviceID == deviceID })))
        }
        return (try modelContext.fetchCount(FetchDescriptor<DeviceRecord>()), try modelContext.fetchCount(FetchDescriptor<AccountLiveRecord>()),
                try modelContext.fetchCount(FetchDescriptor<AccountArchiveRecord>()), try modelContext.fetchCount(FetchDescriptor<ActivityDayRecord>()))
    }

    /// Inserts decoded records as they are (fixtures and tests).
    public func insert(_ records: SyncRecords) throws {
        for d in records.devices {
            let r = DeviceRecord(deviceID: d.deviceID)
            r.payload = try PayloadCodec.encode(d.payload); r.updatedAt = d.updatedAt; r.lastSeenAt = d.lastSeenAt
            modelContext.insert(r)
        }
        for e in records.live {
            let r = AccountLiveRecord(deviceID: e.deviceID, provider: e.provider?.rawValue ?? "", accountKey: e.accountKey)
            r.payload = try PayloadCodec.encode(e.payload); r.updatedAt = e.updatedAt; r.readingAt = e.payload.reading?.fetchedAt
            modelContext.insert(r)
        }
        for e in records.archives {
            let r = AccountArchiveRecord(deviceID: e.deviceID, provider: e.provider?.rawValue ?? "", accountKey: e.accountKey)
            r.payload = try PayloadCodec.encode(e.payload); r.updatedAt = e.updatedAt
            modelContext.insert(r)
        }
        for e in records.activity {
            let r = ActivityDayRecord(deviceID: e.deviceID, provider: e.provider?.rawValue ?? "", accountKey: e.accountKey, day: e.payload.day)
            r.payload = try PayloadCodec.encode(e.payload); r.updatedAt = e.updatedAt
            modelContext.insert(r)
        }
        try modelContext.save()
    }
}

/// The other Macs' device records and the activity that prices their finished runs, in a fixed
/// order, so two reads of an unchanged store compare equal.
public struct OtherMacs: Sendable, Equatable {
    public var devices: [DeviceEnvelope]
    public var activity: [Envelope<ActivityDayPayload>]

    public init(devices: [DeviceEnvelope] = [], activity: [Envelope<ActivityDayPayload>] = []) {
        self.devices = devices; self.activity = activity
    }

    public var isEmpty: Bool { devices.isEmpty }

    /// Every write stamps `updatedAt`, so activity is compared by key and stamp, not slot by slot.
    public static func == (a: OtherMacs, b: OtherMacs) -> Bool {
        a.devices.elementsEqual(b.devices) {
            $0.deviceID == $1.deviceID && $0.updatedAt == $1.updatedAt && $0.lastSeenAt == $1.lastSeenAt && $0.payload == $1.payload
        } && a.activity.elementsEqual(b.activity) { $0.key == $1.key && $0.updatedAt == $1.updatedAt }
    }
}

/// Records that carry a write time, for keeping the newest copy.
protocol Timestamped: AnyObject {
    var updatedAt: Date { get }
}

extension DeviceRecord: Timestamped {}
extension AccountLiveRecord: Timestamped {}
extension AccountArchiveRecord: Timestamped {}
extension ActivityDayRecord: Timestamped {}
