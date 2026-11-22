import Foundation
import Testing
import HeadroomKit
@testable import HeadroomSync

/// What a Mac reads of the user's other Macs for its own Runs tab. An extension of `StoreTests`
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

    private func activity(_ id: String, day: Int) -> Envelope<ActivityDayPayload> {
        Envelope(deviceID: id, provider: .claude, accountKey: "k", day: day, updatedAt: now, payload: ActivityDayPayload(day: day, slots: []))
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
        records.activity = [activity("ME", day: today), activity("STUDIO", day: today), activity("STUDIO", day: today - 30), activity("MINI", day: today)]
        try await s.insert(records)

        let others = try await s.otherMacs(than: "ME", activitySince: today - 8)
        // Not this Mac, not a Mac with no runs now, and one record per Mac: the newest.
        #expect(others.devices.map(\.deviceID) == ["MINI", "STUDIO"])
        #expect(others.devices.last?.updatedAt == now.addingTimeInterval(-60))
        let digests = RunMerge.digests(others.devices, now: now, activity: others.activity)
        #expect(Set(digests.map(\.id)).count == digests.count)
        #expect(digests.count == 2)
        #expect(digests.allSatisfy { !$0.id.hasPrefix("ME:") })
        // Activity only for the Mac with a finished run to price, and only the recent days.
        #expect(others.activity.map(\.deviceID) == ["STUDIO"])
        #expect(others.activity.first?.day == today)

        // Reading leaves every record where it was, the stale copy included.
        let c = try await s.counts()
        #expect(c.devices == 7 && c.activity == 4)
        // An unchanged store reads the same, so nothing redraws; a heartbeat from another Mac doesn't.
        #expect(try await s.otherMacs(than: "ME", activitySince: today - 8) == others)
        try await s.touchDevice("MINI", lastSeenAt: now)
        #expect(try await s.otherMacs(than: "ME", activitySince: today - 8) != others)
    }

    @Test func aMacAloneSeesNoOtherMacs() async throws {
        let s = try store()
        try await s.upsertDevice("ME", payload: device("ME", "This Mac", runs: summaries("mine"), updated: 0).payload, lastSeenAt: now)
        let others = try await s.otherMacs(than: "ME", activitySince: 0)
        #expect(others.isEmpty && others.activity.isEmpty)
        #expect(others == OtherMacs())
    }
}
