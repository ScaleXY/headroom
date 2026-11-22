import Foundation
import Testing
@testable import HeadroomKit

@Suite("TimeFormat")
struct TimeFormatTests {
    let cal = PT.calendar
    let loc = PT.locale
    let now = PT.date(2026, 10, 20, 10, 2) // Tuesday

    @Test func compact() {
        #expect(TimeFormat.compact(20) == "<1m")
        #expect(TimeFormat.compact(48 * 60) == "48m")
        #expect(TimeFormat.compact(19 * 3600 + 58 * 60) == "20h")
        #expect(TimeFormat.compact(47 * 3600) == "47h")
        #expect(TimeFormat.compact(47 * 3600 + 45 * 60) == "2d") // where hours would round to 48, not a day short
        #expect(TimeFormat.compact(48 * 3600) == "2d")
        #expect(TimeFormat.compact(4 * 86400 + 3 * 3600) == "4d")
        #expect(TimeFormat.compact(59 * 60 + 50) == "1h")
        #expect(TimeFormat.compact(-5) == "<1m")
    }

    @Test func countdown() {
        #expect(TimeFormat.countdown(48 * 60) == "48m")
        #expect(TimeFormat.countdown(72 * 60) == "1:12")
        #expect(TimeFormat.countdown(30) == "<1m")
        #expect(TimeFormat.countdown(60 * 60) == "1:00")
    }

    @Test func freshness() {
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-10), now: now) == "now")
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-125), now: now) == "2m")
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-3 * 3600 - 5), now: now) == "3h")
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-2 * 86400), now: now) == "2d")
    }

    @Test func spokenSpan() {
        #expect(TimeFormat.spokenSpan(21 * 3600) == "21 hours")
        #expect(TimeFormat.spokenSpan(3600) == "1 hour")
        #expect(TimeFormat.spokenSpan(45 * 60) == "45 minutes")
        #expect(TimeFormat.spokenSpan(4 * 86400) == "4 days")
    }

    @Test func renewIn() {
        #expect(TimeFormat.renewIn(76 * 3600) == "3 days")
        #expect(TimeFormat.renewIn(166 * 3600) == "7 days")
        #expect(TimeFormat.renewIn(36 * 3600) == "2 days")
        #expect(TimeFormat.renewIn(30 * 3600) == "1 day")
        #expect(TimeFormat.renewIn(24 * 3600) == "1 day")
        #expect(TimeFormat.renewIn(20 * 3600 + 10 * 60) == "20 hours")
        #expect(TimeFormat.renewIn(3600) == "1 hour")
        #expect(TimeFormat.renewIn(45 * 60) == "45 min")
        #expect(TimeFormat.renewIn(10) == "1 min")
        #expect(TimeFormat.renewIn(-5) == "1 min")
    }

    @Test func renewalDate() {
        // The tag's second line: the day and a short clock.
        #expect(TimeFormat.renewAt(PT.date(2026, 10, 23, 14, 0), now: now, calendar: cal, locale: loc) == "Fri 2 PM")
        #expect(TimeFormat.renewAt(PT.date(2026, 10, 21, 6, 0), now: now, calendar: cal, locale: loc) == "tomorrow 6 AM")
        #expect(TimeFormat.renewAt(PT.date(2026, 10, 20, 16, 0), now: now, calendar: cal, locale: loc) == "today 4 PM")
        #expect(TimeFormat.renewAt(PT.date(2026, 10, 23, 14, 30), now: now, calendar: cal, locale: loc) == "Fri 2:30 PM")
        #expect(TimeFormat.renewAt(PT.date(2026, 10, 27, 8, 0), now: now, calendar: cal, locale: loc) == "Oct 27 8 AM")
        // A 24-hour clock keeps its minutes: "Fri 14" would read as a date.
        var gb = cal
        gb.locale = Locale(identifier: "en_GB")
        #expect(TimeFormat.renewAt(PT.date(2026, 10, 23, 14, 0), now: now, calendar: gb, locale: Locale(identifier: "en_GB")) == "Fri 14:00")
    }

    @Test func clocks() {
        let six = PT.date(2026, 10, 21, 6, 0)
        let halfPast = PT.date(2026, 10, 20, 12, 30)
        #expect(TimeFormat.clock(six, calendar: cal, locale: loc) == "6:00 AM")
        #expect(TimeFormat.shortClock(six, calendar: cal, locale: loc) == "6 AM")
        #expect(TimeFormat.shortClock(halfPast, calendar: cal, locale: loc) == "12:30 PM")
        // A 24-hour clock keeps its minutes on the hour; a bare "15" reads as a date.
        var gb = cal
        gb.locale = Locale(identifier: "en_GB")
        #expect(TimeFormat.shortClock(PT.date(2026, 10, 21, 15, 0), calendar: gb, locale: Locale(identifier: "en_GB")) == "15:00")
        #expect(TimeFormat.weekdayShort(six, calendar: cal, locale: loc) == "Wed")
        #expect(TimeFormat.weekdayLong(six, calendar: cal, locale: loc) == "Wednesday")
        #expect(TimeFormat.monthDay(six, calendar: cal, locale: loc) == "Oct 21")
    }

    // On a 24-hour clock the hour alone is a bare number ("renews tomorrow at 06"): the minutes stay.
    @Test func shortClockKeepsMinutesOnA24HourClock() {
        let six = PT.date(2026, 10, 21, 6, 0)
        for (id, expected) in [("en_GB", "6:00"), ("en_US@hours=h23", "06:00"), ("sv_SE", "6:00")] {
            let loc = Locale(identifier: id)
            #expect(TimeFormat.shortClock(six, calendar: cal, locale: loc) == expected, "\(id)")
            #expect(TimeFormat.relative(six, now: now, calendar: cal, locale: loc) == "tomorrow at " + expected, "\(id)")
        }
    }

    @Test func aDurationThatIsNotANumberStillReads() {
        // A forecast that divided by nearly nothing: no trap in the `Int` conversion.
        #expect(TimeFormat.compact(.infinity) == "36500d")
        #expect(TimeFormat.compact(.nan) == "<1m")
        #expect(TimeFormat.compact(-.infinity) == "<1m")
        #expect(TimeFormat.countdown(.infinity).hasSuffix(":00"))
        #expect(TimeFormat.spokenSpan(.infinity) == "36500 days")
    }

    @Test func renewalCaption() {
        #expect(TimeFormat.renewalCaption(PT.date(2026, 10, 21, 6, 0), now: now, calendar: cal, locale: loc) == "renews Wed 6:00 AM")
        #expect(TimeFormat.renewalCaption(PT.date(2026, 10, 24, 13, 0), now: now, calendar: cal, locale: loc) == "renews Sat 1:00 PM")
        #expect(TimeFormat.renewalCaption(PT.date(2026, 11, 3, 13, 0), now: now, calendar: cal, locale: loc) == "renews Nov 3")
    }

    @Test func relative() {
        #expect(TimeFormat.relative(PT.date(2026, 10, 20, 12, 30), now: now, calendar: cal, locale: loc) == "today at 12:30 PM")
        #expect(TimeFormat.relative(PT.date(2026, 10, 21, 6, 0), now: now, calendar: cal, locale: loc) == "tomorrow at 6 AM")
        #expect(TimeFormat.relative(PT.date(2026, 10, 23, 16, 0), now: now, calendar: cal, locale: loc) == "Friday 4 PM")
        #expect(TimeFormat.relative(PT.date(2026, 10, 30, 16, 0), now: now, calendar: cal, locale: loc) == "Oct 30 at 4 PM")
    }

    @Test func resets() {
        #expect(TimeFormat.resets(PT.date(2026, 10, 20, 12, 30), now: now, calendar: cal, locale: loc) == "resets 12:30 PM")
        #expect(TimeFormat.resets(PT.date(2026, 10, 22, 12, 30), now: now, calendar: cal, locale: loc) == "resets Thu 12:30 PM")
    }

    @Test func dayOffsetAcrossMidnight() {
        let lateNight = PT.date(2026, 10, 20, 23, 50)
        #expect(TimeFormat.dayOffset(PT.date(2026, 10, 21, 0, 10), now: lateNight, calendar: cal) == 1)
        #expect(TimeFormat.dayOffset(lateNight, now: lateNight, calendar: cal) == 0)
    }
}
