import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

@MainActor @Suite struct ShareModelTests {
    /// `count` bars of `seconds` each, a million tokens in every one.
    func card(_ count: Int, seconds: [TimeInterval]) -> ActivityCardModel {
        var start = Date(timeIntervalSince1970: 1_790_000_000)
        let bars = (0..<count).map { i -> ActivityBar in
            defer { start += seconds[i % seconds.count] }
            return ActivityBar(start: start, end: start + seconds[i % seconds.count], tokens: TokenCounts(output: 1_000_000), micros: 0)
        }
        return ActivityCardModel(provider: .claude, bars: bars, selection: 0..<count, axisLabels: [], spanLabel: "", spanLong: "",
                                 totals: TokenCounts(output: Int64(count) * 1_000_000), micros: 0, breakdown: [:])
    }

    func share(_ card: ActivityCardModel) -> ShareModel {
        ShareBuilder.make(activity: card, pace: nil, mode: .all, includeCost: false, burnInSpan: nil, durationText: "")
    }

    @Test func theUnitIsWhatABarHolds() {
        #expect(share(card(24, seconds: [3600])).barUnit == "hr")
        #expect(share(card(24, seconds: [4 * 3600])).barUnit == "4h")
        #expect(share(card(42, seconds: [4 * 3600])).barUnit == "8h")
        #expect(share(card(24, seconds: [86400])).barUnit == "day")
        // Thirty days merge in pairs: a bar is two days, and "peak 2M/day" would double the day's peak.
        let month = share(card(30, seconds: [86400]))
        #expect(month.bars == Array(repeating: 2_000_000, count: 15))
        #expect(month.barUnit == "2d")
    }

    @Test func aShortDayIsStillADay() {
        // The clocks go forward on the first day: 23 hours.
        let s = share(card(7, seconds: [23 * 3600, 86400, 86400, 86400, 86400, 86400, 86400]))
        #expect(s.barUnit == "day")
        // Dates under the bars, not the hour each day starts at.
        #expect(s.barLabels.allSatisfy { !$0.contains("AM") && !$0.contains("PM") && $0.contains(where: \.isLetter) })
    }
}
