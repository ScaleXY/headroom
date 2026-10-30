import Foundation
import Testing
import HeadroomKit
import HeadroomPresent
@testable import HeadroomSync

/// The phone and the Mac must never disagree: one Mac's records, merged and rebuilt on the phone,
/// give the same widget feed the Mac builds from the same state.
@MainActor
@Suite struct ParityTests {
    /// What `AppModel.paceInput(_:)` builds from a reading and the account's history.
    func macInput(_ provider: Provider, reading: LimitReading, history h: AccountHistory, now: Date, micros: Int64?) -> PaceInput {
        var input = PaceInput(provider: provider, reading: reading)
        input.samples = h.windows.mapValues(\.samples)
        if let session = h.session { input.samples[LimitWindow.sessionID()] = session.samples }
        input.pastSessions = h.finishedSessions(since: now.addingTimeInterval(-(Presenter.sessionTrailHours + 5) * 3600), now: now)
        input.smoothedState = h.tracker?.shown
        if let early = h.earlyResetAt, let start = reading.headline?.windowStart, early >= start { input.earlyResetAt = early }
        input.weekCostMicros = micros
        return input
    }

    @Test(arguments: ["claude", "codex"])
    func oneMacsRecordsRebuildTheMacsWidgetFeed(_ which: String) throws {
        let now = Demo.now
        let demo = which == "claude" ? Demo.claudeMockup(now: now) : Demo.codexMockup(now: now)
        var reading = try #require(demo.reading)
        reading.accountKey = "\(which)-parity"
        let history = DemoRecords.history(for: demo)

        var records = SyncRecords()
        records.devices = [DemoRecords.device("mac", name: "Mac", model: "Mac15,7", now: now, current: [demo.provider.rawValue: reading.accountKey!])]
        records.live = [Envelope(deviceID: "mac", provider: demo.provider, accountKey: reading.accountKey!, updatedAt: now,
                                 payload: PayloadBuilder.live(reading: reading, history: history, fault: nil, faultAt: nil, isCurrent: true, email: nil))]
        records.archives = [Envelope(deviceID: "mac", provider: demo.provider, accountKey: reading.accountKey!, updatedAt: now,
                                     payload: PayloadBuilder.archive(history))]
        let slots = [ActivitySlot(slot: ActivitySlot.slot(for: now.addingTimeInterval(-3 * 3600)), model: "m", tokens: TokenCounts(output: 1_000),
                                  micros: 4_200_000, unpricedTokens: 0, classMicros: [0, 0, 0, 4_200_000])]
        records.activity = PayloadBuilder.activityDays(slots.map { (demo.provider, reading.accountKey!, $0) }).map {
            Envelope(deviceID: "mac", provider: demo.provider, accountKey: reading.accountKey!, day: $0.key.day, updatedAt: now, payload: $0.value)
        }

        let snapshot = AccountReader(now: now).read(records)
        let merged = try #require(snapshot.accounts.first)
        var phone = try #require(ReaderFeed.build(snapshot, now: now).providers.first)

        let builder = WidgetFeedBuilder(now: now)
        let micros = reading.headline?.windowStart.map { merged.micros(from: $0, to: now) }
        let mac = builder.build([macInput(demo.provider, reading: reading, history: history, now: now, micros: micros)],
                                presenter: Presenter(now: now, policy: .sessionWarning(at: 0.75)),
                                hourly: { _ in merged.bins(edges: builder.hourEdges) }).providers[0]

        // The phone adds its own fields; everything the Mac fills must match exactly.
        #expect(phone.account == "\(demo.provider.rawValue):\(which)-parity")
        phone.account = nil; phone.email = nil; phone.shortLabel = nil; phone.sourceDevice = nil; phone.isActive = nil
        phone.hourlyCostUSD = nil; phone.hourly7d = nil; phone.topModels = nil; phone.daily30 = nil
        phone.recentSessions = nil; phone.pastWeeks = nil; phone.planWeeklyUSD = nil
        #expect(phone == mac)
        #expect(mac.tokens24h == 1_000 && mac.cost24hUSD == 4.2)
    }

    @Test func demoRecordsReadAsTwoMacsAndTwoAccounts() {
        let s = AccountReader(now: Date()).read(DemoRecords.make(.twoMacs))
        #expect(s.devices.count == 2)
        #expect(s.accounts.map(\.provider) == [.claude, .codex])
        #expect(s.accounts[0].deviceIDs.count == 2)

        let two = AccountReader(now: Date()).read(DemoRecords.make(.twoClaudeAccounts))
        #expect(two.accounts.filter { $0.provider == .claude }.count == 2)
        #expect(Set(two.accounts.map(\.shortLabel)).isSuperset(of: ["Claude · you", "Codex"]))
    }
}
