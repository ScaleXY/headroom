import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit

@MainActor @Suite struct HistoryCardTests {
    func week(ranOutHoursEarly hours: Double?, used: Double = 1) -> WeekRecord {
        let start = Date(timeIntervalSince1970: 1_790_000_000), end = start.addingTimeInterval(7 * 86400)
        return WeekRecord(start: start, end: end, scheduledEnd: end, finalUsed: used, ranOutAt: hours.map { end.addingTimeInterval(-$0 * 3600) },
                          sessionHits: 0, earlyReset: false, plan: nil, samples: [])
    }

    @Test func theOutcomeRowReadsAsASentence() {
        #expect(HistoryCardRenderer.outcome(week(ranOutHoursEarly: 1.2)) == "Ran out 1 hour early")
        #expect(HistoryCardRenderer.outcome(week(ranOutHoursEarly: 30)) == "Ran out 30 hours early")
        // Under an hour early isn't counted.
        #expect(HistoryCardRenderer.outcome(week(ranOutHoursEarly: 0.2)) == "Ran out")
        #expect(HistoryCardRenderer.outcome(week(ranOutHoursEarly: nil, used: 0.66)) == "34% renewed unused")
    }
}
