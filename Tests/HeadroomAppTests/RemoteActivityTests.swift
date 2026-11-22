import Foundation
import HeadroomKit
import HeadroomPresent
import HeadroomSync
import Testing
@testable import HeadroomApp

@MainActor @Suite struct RemoteActivityTests {
    let now = Demo.now

    private func activity(_ provider: Provider, account: String, offset: Int = -1, micros: Int64 = 300) -> Envelope<ActivityDayPayload> {
        let model = provider == .claude ? "claude-sonnet-4" : "gpt-5"
        let slot = ActivitySlot(slot: ActivitySlot.slot(for: now) + offset, model: model, tokens: TokenCounts(newInput: 10),
                                micros: micros, unpricedTokens: 0, classMicros: [micros])
        return Envelope(deviceID: "studio", provider: provider, accountKey: account, day: slot.day, updatedAt: now,
                        payload: ActivityDayPayload(day: slot.day, slots: [slot]))
    }

    @Test func remoteSlotsAddToEachProviderAndUseTheMacName() throws {
        let studio = DevicePayload(name: "Mac Studio", model: nil, appVersion: "test", enabledProviders: [.claude, .codex],
                                   currentAccounts: [:], sessionWarnAt: 0.75, planPriceOverrides: [:], outages: [:], state: .awake, syncSince: nil)
        let remote = OtherMacs(devices: [DeviceEnvelope(deviceID: "studio", updatedAt: now, lastSeenAt: now, payload: studio)],
                               activity: [activity(.claude, account: "current"), activity(.claude, account: "previous"),
                                          activity(.codex, account: "current", micros: 500)])
        let local = HourAggregate(provider: .claude, hour: now, model: "claude-sonnet-4", project: "local project",
                                  tokens: TokenCounts(newInput: 7), micros: 100, priced: true)
        let aggregates = [local] + remote.aggregates
        let presenter = ActivityPresenter(now: now)
        let claude = presenter.card(.claude, aggregates: aggregates, range: .day, selection: nil)
        let codex = presenter.card(.codex, aggregates: aggregates, range: .day, selection: nil)
        #expect(claude.totals.newInput == 27 && claude.micros == 700)
        #expect(codex.totals.newInput == 10 && codex.micros == 500)
        #expect(claude.breakdown[.project]?.map(\.name) == ["Mac Studio", "local project"])
        #expect(codex.breakdown[.project]?.map(\.name) == ["Mac Studio"])
        let slot = try #require(remote.aggregates.first)
        #expect(slot.project == nil && slot.mac == "Mac Studio" && slot.classMicros.input == 300)
    }

    @Test func weekCostOnlyIncludesTheSameProviderAndSyncedAccountInsideTheWindow() throws {
        let suite = "com.scalexy.headroom.tests.remote-week-cost"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults))
        let account = model.publisher.syncKey(.claude, "current")
        let remote = OtherMacs(activity: [
            activity(.claude, account: account, offset: -4, micros: 200),
            activity(.claude, account: account, micros: 300),
            activity(.claude, account: "previous"),
            activity(.codex, account: account),
            activity(.claude, account: account, offset: -5),
            activity(.claude, account: account, offset: 0),
        ])
        let start = now.addingTimeInterval(-3600)
        #expect(remote.micros(.claude, accountKey: account, from: start, to: now) == 500)
        #expect(remote.micros(.claude, accountKey: model.publisher.syncKey(.claude, nil), from: start, to: now) == 0)
    }

    @Test func activityMatchesLocalBucketsWhileSyncIsOffOrHasYetToStart() throws {
        let suite = "com.scalexy.headroom.tests.activity-sync-off"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.syncEnabled = false
        let model = AppModel(settings: settings)
        let local = model.aggregates()
        #expect(local.count == model.buckets.allSlots.count)
        #expect(local.allSatisfy { $0.mac == nil })
        settings.syncEnabled = true
        #expect(model.aggregates() == local)
    }
}
