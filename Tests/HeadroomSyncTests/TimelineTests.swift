import Foundation
import Testing
import HeadroomKit
@testable import HeadroomSync

@Suite struct TimelineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func attributesActivityToTheAccountSignedInAtTheTime() {
        var t = AccountTimeline()
        let first = t.record(.claude, accountKey: "a", at: t0)
        let same = t.record(.claude, accountKey: "a", at: t0.addingTimeInterval(60))
        let switched = t.record(.claude, accountKey: "b", at: t0.addingTimeInterval(3600))
        #expect(first && !same && switched)
        #expect(t.account(.claude, at: t0.addingTimeInterval(-86400)) == "a") // before the first span
        #expect(t.account(.claude, at: t0.addingTimeInterval(1800)) == "a")
        #expect(t.account(.claude, at: t0.addingTimeInterval(7200)) == "b")
        #expect(t.account(.codex, at: t0) == nil)
    }

    @Test func pruningKeepsTheSpanInForce() {
        var t = AccountTimeline()
        t.record(.claude, accountKey: "a", at: t0)
        t.record(.claude, accountKey: "b", at: t0.addingTimeInterval(100))
        t.record(.claude, accountKey: "c", at: t0.addingTimeInterval(200))
        t.prune(before: t0.addingTimeInterval(150))
        #expect(t.spans["claude"]?.map(\.accountKey) == ["b", "c"])
    }

    @Test func activityGroupsIntoUTCDays() {
        let s1 = ActivitySlot(slot: 96 * 20_000 + 95, model: "m", tokens: TokenCounts(output: 1), micros: 0, unpricedTokens: 0, classMicros: [0, 0, 0, 0])
        let s2 = ActivitySlot(slot: 96 * 20_001, model: "m", tokens: TokenCounts(output: 1), micros: 0, unpricedTokens: 0, classMicros: [0, 0, 0, 0])
        let days = PayloadBuilder.activityDays([(.claude, "k", s1), (.claude, "k", s2)])
        #expect(Set(days.keys.map(\.day)) == [20_000, 20_001])
    }
}
