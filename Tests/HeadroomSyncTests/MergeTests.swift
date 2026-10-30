import Foundation
import Testing
import HeadroomKit
@testable import HeadroomSync

@Suite struct MergeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(_ used: Double, at: Date, resetsAt: Date? = nil, session: Double = 0.3, plan: String = "MAX 20×", key: String = "claude-a") -> LimitReading {
        LimitReading(provider: .claude, fetchedAt: at, source: .api, plan: PlanInfo(raw: "max", pill: plan, monthlyPriceUSD: 200),
                     windows: [LimitWindow(id: "session", kind: .session, used: session, resetsAt: now.addingTimeInterval(3600)),
                               LimitWindow(id: "weekly", kind: .weekly, used: used, resetsAt: resetsAt ?? now.addingTimeInterval(3 * 86400))],
                     accountKey: key)
    }

    func history(_ samples: [(Double, Double)], resetsAt: Date? = nil) -> AccountHistory {
        var h = AccountHistory()
        var w = WindowHistory(id: "weekly", resetsAt: resetsAt ?? now.addingTimeInterval(3 * 86400), duration: 7 * 86400)
        w.samples = samples.map { UsageSample(time: now.addingTimeInterval($0.0 * 3600), used: $0.1) }
        h.windows["weekly"] = w
        h.headlineID = "weekly"
        return h
    }

    func live(_ device: String, _ r: LimitReading?, _ h: AccountHistory = AccountHistory(), key: String = "claude-a", fault: Fault? = nil,
              updated: Date? = nil, email: String? = nil) -> Envelope<AccountLivePayload> {
        Envelope(deviceID: device, provider: .claude, accountKey: key, updatedAt: updated ?? r?.fetchedAt ?? now,
                 payload: PayloadBuilder.live(reading: r, history: h, fault: fault, faultAt: now, isCurrent: true, email: email))
    }

    func device(_ id: String, current: [String: String] = [:], seen: Date? = nil) -> DeviceEnvelope {
        DeviceEnvelope(deviceID: id, updatedAt: seen ?? now, lastSeenAt: seen ?? now,
                       payload: DevicePayload(name: id, model: nil, appVersion: "0.4.0", enabledProviders: [.claude], currentAccounts: current,
                                              sessionWarnAt: 0.75, planPriceOverrides: [:], outages: [:], state: .awake, syncSince: nil))
    }

    func slot(_ hour: Double, _ tokens: Int64, model: String = "m") -> ActivitySlot {
        ActivitySlot(slot: ActivitySlot.slot(for: now.addingTimeInterval(hour * 3600)), model: model, tokens: TokenCounts(output: tokens),
                     micros: tokens * 10, unpricedTokens: 0, classMicros: [0, 0, 0, tokens * 10])
    }

    func day(_ device: String, _ slots: [ActivitySlot], key: String = "claude-a") -> [Envelope<ActivityDayPayload>] {
        PayloadBuilder.activityDays(slots.map { (Provider.claude, key, $0) }).map {
            Envelope(deviceID: device, provider: .claude, accountKey: key, day: $0.key.day, updatedAt: now, payload: $0.value)
        }
    }

    @Test func oneAccountOnTwoMacsIsOneCardWithTheFreshestReading() {
        var r = SyncRecords()
        r.devices = [device("A", current: ["claude": "claude-a"]), device("B", current: ["claude": "claude-a"])]
        r.live = [live("A", reading(0.40, at: now.addingTimeInterval(-600))), live("B", reading(0.42, at: now.addingTimeInterval(-60)))]
        let s = AccountReader(now: now).read(r)
        #expect(s.accounts.count == 1)
        #expect(s.accounts[0].reading?.weekly?.used == 0.42)
        #expect(s.accounts[0].sourceDevice == "B")
        #expect(Set(s.accounts[0].deviceIDs) == ["A", "B"])
    }

    @Test func differentAccountsStaySeparateAndUnknownAccountsNeverMerge() {
        var r = SyncRecords()
        let unknownA = PayloadBuilder.deviceScopedKey(.claude, deviceID: "A"), unknownB = PayloadBuilder.deviceScopedKey(.claude, deviceID: "B")
        r.live = [live("A", reading(0.1, at: now), key: "claude-a"), live("B", reading(0.2, at: now, key: "claude-b"), key: "claude-b"),
                  live("A", reading(0.3, at: now, key: unknownA), key: unknownA), live("B", reading(0.4, at: now, key: unknownB), key: unknownB)]
        #expect(AccountReader(now: now).read(r).accounts.count == 4)
    }

    @Test func samplesFromBothMacsAreUnioned() {
        var r = SyncRecords()
        r.live = [live("A", reading(0.5, at: now), history([(-50, 0.1), (-30, 0.3), (-1, 0.5)])),
                  live("B", reading(0.4, at: now.addingTimeInterval(-3600)), history([(-40, 0.2), (-30, 0.3), (-10, 0.4)]))]
        let h = AccountReader(now: now).read(r).accounts[0].history
        #expect(h.windows["weekly"]?.samples.map(\.used) == [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    @Test func samplesFromAnotherWindowAreNotMixedIn() {
        var r = SyncRecords()
        r.live = [live("A", reading(0.5, at: now), history([(-1, 0.5)])),
                  live("B", reading(0.9, at: now.addingTimeInterval(-86400 * 6)), history([(-150, 0.9)], resetsAt: now.addingTimeInterval(-86400 * 4)))]
        #expect(AccountReader(now: now).read(r).accounts[0].history.windows["weekly"]?.samples.map(\.used) == [0.5])
    }

    @Test func mergeIsIdempotentAndOrderIndependent() {
        var r = SyncRecords()
        r.devices = [device("A"), device("B")]
        r.live = [live("A", reading(0.5, at: now), history([(-50, 0.1), (-1, 0.5)])),
                  live("B", reading(0.4, at: now.addingTimeInterval(-60)), history([(-40, 0.2), (-10, 0.4)]))]
        r.activity = day("A", [slot(-2, 100)]) + day("B", [slot(-2, 50), slot(-1, 7)])
        let base = AccountReader(now: now).read(r).accounts[0]

        var doubled = r
        doubled.live += r.live
        doubled.activity += r.activity
        var reversed = r
        reversed.live.reverse()
        reversed.activity.reverse()
        for other in [doubled, reversed] {
            let m = AccountReader(now: now).read(other).accounts[0]
            #expect(m.reading == base.reading)
            #expect(m.history == base.history)
            #expect(m.activity == base.activity)
        }
    }

    @Test func activityAddsUpAcrossMacs() {
        var r = SyncRecords()
        r.live = [live("A", reading(0.5, at: now)), live("B", reading(0.5, at: now))]
        r.activity = day("A", [slot(-2, 100), slot(-1, 10)]) + day("B", [slot(-2, 50)])
        let a = AccountReader(now: now).read(r).accounts[0]
        #expect(a.activity.reduce(0) { $0 + $1.tokens.total } == 160)
        #expect(a.activity.first { $0.slot == ActivitySlot.slot(for: now.addingTimeInterval(-7200)) }?.tokens.total == 150)
    }

    @Test func identicalDaysFromASyncedClaudeFolderCountOnce() {
        let slots = (0..<10).map { slot(-Double($0) - 1, 100) }
        var r = SyncRecords()
        r.live = [live("A", reading(0.5, at: now)), live("B", reading(0.5, at: now))]
        r.activity = day("A", slots) + day("B", slots)
        #expect(AccountReader(now: now).read(r).accounts[0].activity.reduce(0) { $0 + $1.tokens.total } == 1000)
    }

    @Test func aFaultShowsOnlyWhenEveryRecentMacHasOne() {
        var r = SyncRecords()
        r.live = [live("A", reading(0.5, at: now), fault: .signedOut), live("B", reading(0.4, at: now.addingTimeInterval(-60)))]
        var a = AccountReader(now: now).read(r).accounts[0]
        #expect(a.fault == nil)
        #expect(a.deviceFaults["A"] == .signedOut)
        r.live[1] = live("B", reading(0.4, at: now.addingTimeInterval(-60)), fault: .offline)
        a = AccountReader(now: now).read(r).accounts[0]
        #expect(a.fault != nil)
    }

    @Test func aWeekPastItsResetRollsOverByTheClock() {
        var r = SyncRecords()
        let reset = now.addingTimeInterval(-3600)
        r.live = [live("A", reading(0.9, at: now.addingTimeInterval(-86400), resetsAt: reset), history([(-30, 0.9)], resetsAt: reset))]
        let a = AccountReader(now: now).read(r).accounts[0]
        #expect(a.projected)
        #expect(a.reading?.weekly?.used == 0)
        #expect(a.reading?.weekly?.resetsAt == reset.addingTimeInterval(7 * 86400))
        #expect(a.history.windows["weekly"]?.samples.isEmpty == true)
    }

    @Test func labelsUseEmailsAndNumberLookalikes() {
        var r = SyncRecords()
        r.devices = [device("A", current: ["claude": "claude-a"]), device("B", current: ["claude": "claude-b"])]
        r.live = [live("A", reading(0.1, at: now.addingTimeInterval(-60)), key: "claude-a"),
                  live("B", reading(0.2, at: now, key: "claude-b"), key: "claude-b")]
        var accounts = AccountReader(now: now).read(r).accounts
        #expect(Set(accounts.map(\.label)) == ["Claude · MAX 20×", "Claude · MAX 20× · 2"])

        r.live[0] = live("A", reading(0.1, at: now.addingTimeInterval(-60)), key: "claude-a", email: "me@example.com")
        accounts = AccountReader(now: now).read(r).accounts
        let mine = accounts.first { $0.accountKey == "claude-a" }
        #expect(mine?.label == "me@example.com")
        #expect(mine?.shortLabel == "Claude · me")
    }

    @Test func staleUnsignedAccountsAreInactiveAndSortLast() {
        var r = SyncRecords()
        r.devices = [device("A", current: ["claude": "claude-a"])]
        r.live = [live("A", reading(0.1, at: now.addingTimeInterval(-10 * 86400), key: "claude-old"), key: "claude-old"),
                  live("A", reading(0.2, at: now))]
        let accounts = AccountReader(now: now).read(r).accounts
        #expect(accounts.map(\.accountKey) == ["claude-a", "claude-old"])
        #expect(accounts.map(\.isActive) == [true, false])
    }

    @Test func sessionsAndWeeksFromTwoMacsMatchUp() {
        let s1 = SessionRecord(start: now.addingTimeInterval(-20000), resetsAt: now.addingTimeInterval(-2000), peakUsed: 0.8, hitLimitAt: nil)
        let s2 = SessionRecord(start: now.addingTimeInterval(-20100), resetsAt: now.addingTimeInterval(-2100), peakUsed: 1, hitLimitAt: now.addingTimeInterval(-5000))
        let merged = AccountReader.mergeSessions([[s1], [s2]])
        #expect(merged.count == 1)
        #expect(merged[0].peakUsed == 1 && merged[0].hitLimit)

        let w1 = WeekRecord(start: now, end: now, scheduledEnd: now, finalUsed: 0.7, ranOutAt: nil, sessionHits: 1, earlyReset: false, plan: nil, samples: [])
        var w2 = w1
        w2.finalUsed = 0.9; w2.sessionHits = 3; w2.scheduledEnd = now.addingTimeInterval(120)
        let weeks = AccountReader.mergeWeeks([[w1], [w2]])
        #expect(weeks.count == 1 && weeks[0].finalUsed == 0.9 && weeks[0].sessionHits == 3)
    }
}
