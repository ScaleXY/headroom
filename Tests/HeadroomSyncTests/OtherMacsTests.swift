import Foundation
import Testing
import HeadroomKit
@testable import HeadroomSync

/// What a Mac reads of the user's other Macs for Runs and Activity. An extension of `StoreTests`
/// so it shares that suite's one-container-at-a-time rule.
extension StoreTests {
    private func summaries(_ id: String, _ state: TaskRunState = .running, tokens: [String: Int64] = [:]) -> [RunSummaryPayload]? {
        let run = TaskRun(id: id, title: id, startedAt: now.addingTimeInterval(-1800), updatedAt: now.addingTimeInterval(-120), state: state,
                          hasDeclaredTasks: true, nodes: [TaskNode(id: "a", title: "Step", state: state.isTerminal ? .done : .running)],
                          tokensByModel: tokens)
        return RunSummaryBuilder.summaries([run], includeNames: false, now: now)
    }

    private func device(_ id: String, _ name: String, runs: [RunSummaryPayload]?, updated: TimeInterval) -> DeviceEnvelope {
        var p = devicePayload(name)
        p.runs = runs
        return DeviceEnvelope(deviceID: id, updatedAt: now.addingTimeInterval(updated), lastSeenAt: now.addingTimeInterval(updated), payload: p)
    }

    private func activity(_ id: String, day: Int, count: Int = 0, account: String = "k", updated: TimeInterval = 0) -> Envelope<ActivityDayPayload> {
        let slots = (0..<count).map {
            ActivitySlot(slot: day * 96 + $0, model: "claude-sonnet-4", tokens: TokenCounts(newInput: 100),
                         micros: 300, unpricedTokens: 0, classMicros: [300])
        }
        return Envelope(deviceID: id, provider: .claude, accountKey: account, day: day, updatedAt: now.addingTimeInterval(updated),
                        payload: ActivityDayPayload(day: day, slots: slots))
    }

    @Test func otherMacsAreReadNewestRecordEachAndNeverThisOne() async throws {
        let s = try store()
        let today = Int((now.timeIntervalSince1970 / 86400).rounded(.down))
        var records = SyncRecords()
        records.devices = [device("ME", "This Mac", runs: summaries("mine"), updated: 0),
                           // A reinstalled Mac that hasn't cleaned up its old copy yet.
                           device("STUDIO", "Mac Studio", runs: summaries("old"), updated: -600),
                           device("STUDIO", "Mac Studio", runs: summaries("new", .done, tokens: ["claude-sonnet-4": 1000]), updated: -60),
                           device("MINI", "Mac mini", runs: summaries("live"), updated: -30),
                           device("IDLE", "Idle Mac", runs: nil, updated: -30),
                           // Its runs ended since the copy it left behind.
                           device("AIR", "MacBook Air", runs: summaries("ended"), updated: -900),
                           device("AIR", "MacBook Air", runs: nil, updated: -90)]
        records.activity = [activity("ME", day: today), activity("STUDIO", day: today, count: 1, updated: -600),
                            activity("STUDIO", day: today, count: 2), activity("STUDIO", day: today - 36),
                            activity("MINI", day: today), activity("IDLE", day: today - 35), activity("ORPHAN", day: today)]
        try await s.insert(records)

        let others = try await s.otherMacs(than: "ME", activitySince: today - 35)
        #expect(others.devices.map(\.deviceID) == ["AIR", "IDLE", "MINI", "STUDIO"])
        #expect(others.devices.last?.updatedAt == now.addingTimeInterval(-60))
        let digests = RunMerge.digests(others.devices, now: now, activity: others.runActivity)
        #expect(Set(digests.map(\.id)).count == digests.count)
        #expect(digests.count == 2)
        #expect(digests.allSatisfy { !$0.id.hasPrefix("ME:") })
        #expect(others.activity.map(\.deviceID) == ["IDLE", "MINI", "ORPHAN", "STUDIO"])
        #expect(others.activity.first?.day == today - 35)
        #expect(others.activity.last?.updatedAt == now)
        #expect(others.activity.last?.payload.slots.count == 2)
        #expect(others.runActivity.map(\.deviceID) == ["STUDIO"])

        // Reading leaves every record where it was, the stale copy included.
        let c = try await s.counts()
        #expect(c.devices == 7 && c.activity == 7)
        #expect(try await s.otherMacs(than: "ME", activitySince: today - 35) == others)
        try await s.touchDevice("MINI", lastSeenAt: now)
        #expect(try await s.otherMacs(than: "ME", activitySince: today - 35) != others)
    }

    @Test func activityMirrorsKeepLocalDaysAndOneCopyOfMatchingRemoteDays() async throws {
        let s = try store()
        var records = SyncRecords()
        records.devices = [device("AIR", "MacBook Air", runs: summaries("done", .done, tokens: ["claude-sonnet-4": 100]), updated: 0)]
        records.activity = [
            activity("ME", day: 3, count: 8), activity("AIR", day: 3, count: 8),
            activity("ME", day: 2, count: 1), activity("AIR", day: 2, count: 1),
            activity("AIR", day: 1, count: 7), activity("MINI", day: 1, count: 7),
            activity("AIR", day: 4, count: 8), activity("MINI", day: 4, count: 8),
            activity("AIR", day: 3, count: 8, account: "other"),
            activity("DESK", day: 1, count: 7),
        ]
        try await s.insert(records)

        let others = try await s.otherMacs(than: "ME", activitySince: 1)
        #expect(others.activity.map(\.key) == [records.activity[4].key, records.activity[6].key, records.activity[8].key, records.activity[9].key])
        #expect(others.runActivity.contains { $0.key == records.activity[1].key })
        #expect(try await s.otherMacs(than: "ME", activitySince: 1) == others)

        // A changed local day breaks the mirror and makes the imported day visible.
        let changed = activity("ME", day: 3, count: 9)
        try await s.upsertActivity(deviceID: "ME", provider: .claude, accountKey: "k", payload: changed.payload, now: now.addingTimeInterval(1))
        let after = try await s.otherMacs(than: "ME", activitySince: 1)
        #expect(after != others)
        #expect(after.activity.contains { $0.key == records.activity[1].key })
    }

    @Test func aMacAloneSeesNoOtherMacs() async throws {
        let s = try store()
        try await s.upsertDevice("ME", payload: device("ME", "This Mac", runs: summaries("mine"), updated: 0).payload, lastSeenAt: now)
        let others = try await s.otherMacs(than: "ME", activitySince: 0)
        #expect(others.isEmpty && others.activity.isEmpty)
        #expect(others == OtherMacs())
    }
}
