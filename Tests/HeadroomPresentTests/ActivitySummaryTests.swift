import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

/// Activity's summary card, composition, control-row title and the Past weeks sessions chip (redesign §5).
@MainActor @Suite struct ActivitySummaryTests {
    let now = Demo.activityNow
    var pricing: PricingEngine { PricingEngine(table: try! PriceTable.bundled()) }
    var presenter: ActivityPresenter { ActivityPresenter(now: now, locale: Locale(identifier: "en_US"), pricing: pricing) }

    func cards(_ providers: [Provider] = [.claude, .codex], range: ActivityRange = .day, selection: Range<Int>? = nil) -> [ActivityCardModel] {
        let aggregates = Demo.activityAggregates(now: now, pricing: pricing)
        return providers.map { presenter.card($0, aggregates: aggregates, range: range, selection: selection) }
    }

    @Test func totalsAddUpAcrossProviders() {
        let c = cards()
        let s = presenter.summary(c, range: .day, mode: .all)
        #expect(s.micros == c[0].rangeMicros + c[1].rangeMicros)
        #expect(s.micros > 0)
        #expect(s.tokens == c[0].rangeTokens.total + c[1].rangeTokens.total)
        #expect(s.eyebrow == "API value · last 24 hours")
        #expect(s.slices.map(\.provider) == [.claude, .codex])
        #expect(abs(s.slices.map(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(abs(s.slices[0].share - Double(c[0].rangeMicros) / Double(s.micros)) < 1e-9)
        #expect(s.showsSplit)
    }

    @Test func cachedReadsSwitchChangesTokensNotDollars() {
        let c = cards()
        let on = presenter.summary(c, range: .day, mode: .all)
        let off = presenter.summary(c, range: .day, mode: .newOnly)
        #expect(on.micros == off.micros)
        #expect(off.tokens == c[0].rangeTokens.fresh + c[1].rangeTokens.fresh)
        #expect(off.tokens < on.tokens)
        #expect(on.includesCachedReads && !off.includesCachedReads)
        #expect(on.tokensCaption == "tokens · \(Int((on.cachedShare * 100).rounded()))% cached")
        #expect(on.cachedShare > 0.9)
        #expect(off.tokensCaption == "new tokens")
        #expect(c[0].shownTokens(.all) == c[0].totals.total && c[0].shownTokens(.newOnly) == c[0].totals.fresh)
    }

    @Test func aSelectionDoesNotChangeTheSummary() {
        let whole = presenter.summary(cards(), range: .day, mode: .all)
        let picked = cards(selection: 4..<8)
        #expect(presenter.summary(picked, range: .day, mode: .all) == whole)
        #expect(picked.allSatisfy { $0.isSubRange })
        #expect(!cards().contains { $0.isSubRange })
        #expect(picked[0].micros < picked[0].rangeMicros)
    }

    @Test func oneProviderHasNoSplit() {
        let s = presenter.summary(cards([.claude]), range: .week, mode: .all)
        #expect(!s.showsSplit)
        #expect(s.slices.count == 1 && s.slices[0].share == 1)
        #expect(s.eyebrow == "API value · last 7 days")
    }

    @Test func splitCellsNeverAllOrNone() {
        func model(_ a: Double) -> ActivitySummaryModel {
            ActivitySummaryModel(eyebrow: "", micros: 1, tokens: 1, includesCachedReads: true, cachedShare: 0, tokensCaption: "",
                                 slices: [.init(provider: .claude, micros: 1, share: a), .init(provider: .codex, micros: 1, share: 1 - a)])
        }
        #expect(model(0.36).leadingCells() == 7)
        #expect(model(0.5).leadingCells() == 10)
        #expect(model(0.001).leadingCells() == 1)
        #expect(model(0.999).leadingCells() == 19)
        #expect(model(0).leadingCells() == 0)
        #expect(model(1).leadingCells() == 20)
    }

    @Test func compositionFollowsTheSwitch() {
        let t = TokenCounts(newInput: 30, cacheWrite5m: 10, cacheWrite1h: 10, cacheRead: 900, output: 50)
        let on = TokenPart.parts(t, mode: .all)
        #expect(on.map(\.kind) == [.cachedReads, .newInput, .output])
        #expect(on.map(\.tokens) == [900, 50, 50])
        #expect(on.map(\.label) == ["Cached reads", "New input", "Output"])
        #expect(abs(on[0].share - 0.9) < 1e-9)
        let off = TokenPart.parts(t, mode: .newOnly)
        #expect(off.map(\.kind) == [.newInput, .cacheWrite, .output])
        #expect(off.map(\.tokens) == [30, 20, 50])
        #expect(abs(off.map(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(TokenPart.parts(.zero, mode: .all).allSatisfy { $0.share == 0 })
        // The tone ramp: cached reads 26%, new input 62%, output 100%.
        #expect(on.map(\.kind.toneStrength) == [0.26, 0.62, 1.0])
    }

    @Test func controlRowTitle() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = ISO8601DateFormatter().date(from: "2026-11-22T10:20:00Z")! // a Sunday
        let p = ActivityPresenter(now: at, calendar: cal, locale: Locale(identifier: "en_US"))
        #expect(p.rangeTitle(.day) == ("Last 24 hours", "since Sat 11 AM"))
        #expect(p.rangeTitle(.week).title == "Last 7 days")
        #expect(p.rangeTitle(.week).since == "since Sun 12 PM")
        #expect(p.rangeTitle(.month) == ("Last 30 days", "since Oct 24"))
    }

    @Test func sessionsHitChipOnPastWeeks() {
        let sessions = Demo.sessionHistory(.claude, now: Demo.now)
        let hit = HistoryPresenter.sessionsHit(sessions, now: Demo.now)
        #expect(hit == PastWeeksModel.SessionsHit(hit: 3, total: 13))
        #expect(hit?.text == "3 of 13 sessions hit")
        #expect(hit?.chip.color == .amber)
        let none = HistoryPresenter.sessionsHit(Demo.sessionHistory(.codex, now: Demo.now), now: Demo.now)
        #expect(none?.text == "0 of 10 sessions hit")
        #expect(none?.chip.color == .muted)
        #expect(HistoryPresenter.sessionsHit([], now: Demo.now) == nil)
    }
}
