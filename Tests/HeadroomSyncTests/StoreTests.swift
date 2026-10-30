import Foundation
import SwiftData
import Testing
import HeadroomKit
@testable import HeadroomSync

@Suite struct StoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func store() throws -> SyncStore { SyncStore(container: try SyncContainer.make(.memory, cloudKit: false)) }

    func devicePayload(_ name: String = "Mac") -> DevicePayload {
        DevicePayload(name: name, model: nil, appVersion: "0.4.0", enabledProviders: [.claude], currentAccounts: [:], sessionWarnAt: 0.75,
                      planPriceOverrides: [:], outages: [:], state: .awake, syncSince: nil)
    }

    func livePayload(_ used: Double) -> AccountLivePayload {
        PayloadBuilder.live(reading: LimitReading(provider: .claude, fetchedAt: now, source: .api,
                                                  windows: [LimitWindow(id: "weekly", kind: .weekly, used: used, resetsAt: now.addingTimeInterval(86400))]),
                            history: nil, fault: nil, faultAt: nil, isCurrent: true, email: nil)
    }

    @Test func upsertsByNaturalKey() async throws {
        let s = try store()
        try await s.upsertDevice("A", payload: devicePayload("One"), lastSeenAt: now)
        try await s.upsertDevice("A", payload: devicePayload("Two"), lastSeenAt: now)
        try await s.upsertLive(deviceID: "A", provider: .claude, accountKey: "k", payload: livePayload(0.1))
        try await s.upsertLive(deviceID: "A", provider: .claude, accountKey: "k", payload: livePayload(0.2))
        try await s.upsertActivity(deviceID: "A", provider: .claude, accountKey: "k", payload: ActivityDayPayload(day: 1, slots: []))
        try await s.upsertActivity(deviceID: "A", provider: .claude, accountKey: "k", payload: ActivityDayPayload(day: 2, slots: []))
        let c = try await s.counts()
        #expect(c.devices == 1 && c.live == 1 && c.activity == 2)
        let r = try await s.records()
        #expect(r.devices.first?.payload.name == "Two")
        #expect(r.live.first?.payload.reading?.weekly?.used == 0.2)
    }

    @Test func dedupeKeepsTheNewestCopyOfMyRecordsOnly() async throws {
        let s = try store()
        var dupes = SyncRecords()
        dupes.live = [
            Envelope(deviceID: "A", provider: .claude, accountKey: "k", updatedAt: now, payload: livePayload(0.1)),
            Envelope(deviceID: "A", provider: .claude, accountKey: "k", updatedAt: now.addingTimeInterval(60), payload: livePayload(0.2)),
            Envelope(deviceID: "B", provider: .claude, accountKey: "k", updatedAt: now, payload: livePayload(0.3)),
            Envelope(deviceID: "B", provider: .claude, accountKey: "k", updatedAt: now, payload: livePayload(0.3)),
        ]
        try await s.insert(dupes)
        try await s.dedupe(deviceID: "A")
        let live = try await s.records().live
        #expect(live.filter { $0.deviceID == "A" }.map(\.payload.reading?.weekly?.used) == [0.2])
        #expect(live.filter { $0.deviceID == "B" }.count == 2) // another Mac's records are never touched
    }

    @Test func collectsOldActivityAndRemovesEverything() async throws {
        let s = try store()
        for day in 10...14 {
            try await s.upsertActivity(deviceID: "A", provider: .claude, accountKey: "k", payload: ActivityDayPayload(day: day, slots: []))
        }
        try await s.upsertLive(deviceID: "A", provider: .claude, accountKey: "k", payload: livePayload(0.1), now: now)
        try await s.upsertLive(deviceID: "A", provider: .claude, accountKey: "old", payload: livePayload(0.1), now: now.addingTimeInterval(-100 * 86400))
        try await s.upsertArchive(deviceID: "A", provider: .claude, accountKey: "old", payload: AccountArchivePayload(weeks: [], sessions: []))
        try await s.collectGarbage(deviceID: "A", activityBefore: 12, staleBefore: now.addingTimeInterval(-90 * 86400))
        var c = try await s.counts(deviceID: "A")
        #expect(c.activity == 3 && c.live == 1 && c.archives == 0)

        try await s.upsertDevice("B", payload: devicePayload(), lastSeenAt: now)
        try await s.removeAll(deviceID: "A")
        c = try await s.counts(deviceID: "A")
        #expect(c.devices == 0 && c.live == 0 && c.activity == 0)
        #expect(try await s.counts().devices == 1)
    }

    @Test func skipsPayloadsFromANewerApp() async throws {
        let s = try store()
        try await s.upsertDevice("A", payload: devicePayload(), lastSeenAt: now)
        try await s.markFuture(deviceID: "A")
        let r = try await s.records()
        #expect(r.devices.isEmpty && r.tooNew == 1)
    }
}

extension SyncStore {
    /// Pretends a newer app wrote this Mac's device record.
    func markFuture(deviceID: String) throws {
        for r in try modelContext.fetch(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID == deviceID })) {
            r.payloadVersion = PayloadVersion.current + 1
        }
        try modelContext.save()
    }
}
