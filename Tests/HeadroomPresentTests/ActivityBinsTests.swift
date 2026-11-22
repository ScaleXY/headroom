import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

@MainActor @Suite struct ActivityBinsTests {
    @Test func theWeekAxisNamesEveryDayWhenTheClocksChange() throws {
        // Clocks go back on Sunday 1 November 2026 in New York: the 4-hour bins before it start at 1 AM, not midnight.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 13)))
        let bins = ActivityPresenter(now: now, calendar: cal, locale: Locale(identifier: "en_US")).bins(for: .week)
        #expect(bins.labels.map(\.1) == ["THU", "FRI", "SAT", "SUN", "MON", "TUE", "WED"])
    }

    @Test func anOrdinaryWeekIsLabelledAtMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 13)))
        let bins = ActivityPresenter(now: now, calendar: cal, locale: Locale(identifier: "en_US")).bins(for: .week)
        #expect(bins.labels.map(\.1) == ["THU", "FRI", "SAT", "SUN", "MON", "TUE", "WED"])
        #expect(bins.labels.allSatisfy { cal.component(.hour, from: bins.starts[$0.0]) == 0 })
    }
}
