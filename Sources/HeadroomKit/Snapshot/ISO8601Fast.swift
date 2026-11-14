import Foundation

/// The two timestamp shapes Headroom writes, read and written without `ISO8601DateFormatter`:
/// `2026-11-12T10:04:05Z` (snapshots, `tasks.json`) and `2026-11-12T10:04:05.120Z` (task events).
///
/// The formatter takes about 70 µs to parse one date, which was nearly all the time spent reading
/// a run's event files. These return exactly what `ISO8601DateFormatter.headroom` and
/// `.headroomMillis` return (the same `Date` bit for bit, the same string byte for byte) for the
/// shapes and years below, and nil for anything else, so callers fall back to the formatter and
/// unusual input (offsets, other fraction lengths, days that roll over) reads as it always has.
public enum ISO8601Fast {
    /// Years the arithmetic is checked against the formatter for.
    static let years = 1970...2099
    /// `2100-01-01T00:00:00Z`, in seconds since 1970.
    static let end: TimeInterval = 4_102_444_800

    /// `YYYY-MM-DDTHH:MM:SSZ` when `whole`, `YYYY-MM-DDTHH:MM:SS.fffZ` when `millis`; nil otherwise.
    public static func date(_ s: String, whole: Bool = true, millis: Bool = true) -> Date? {
        s.utf8.withContiguousStorageIfAvailable { b -> Date? in
            guard (b.count == 20 && whole) || (b.count == 24 && millis), b[b.count - 1] == 0x5A else { return nil }
            @inline(__always) func d(_ i: Int) -> Int? {
                let c = b[i]
                return c >= 0x30 && c <= 0x39 ? Int(c &- 0x30) : nil
            }
            guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
                  let y0 = d(0), let y1 = d(1), let y2 = d(2), let y3 = d(3), let mo0 = d(5), let mo1 = d(6), let d0 = d(8), let d1 = d(9),
                  let h0 = d(11), let h1 = d(12), let mi0 = d(14), let mi1 = d(15), let s0 = d(17), let s1 = d(18) else { return nil }
            // Typed and split up: long integer sums stall the type checker on slower machines.
            let century: Int = y0 * 1000 + y1 * 100
            let year: Int = century + y2 * 10 + y3
            let month: Int = mo0 * 10 + mo1
            let day: Int = d0 * 10 + d1
            let hour: Int = h0 * 10 + h1
            let minute: Int = mi0 * 10 + mi1
            let second: Int = s0 * 10 + s1
            guard years.contains(year), month >= 1, month <= 12, day >= 1, day <= daysIn(month, of: year),
                  hour <= 23, minute <= 59, second <= 59 else { return nil }
            let dayStart: Int = days(year, month, day) * 86400
            let clock: Int = hour * 3600 + minute * 60
            let seconds: Int = dayStart + clock + second
            guard b.count == 24 else { return Date(timeIntervalSince1970: Double(seconds)) }
            guard b[19] == 0x2E, let f0 = d(20), let f1 = d(21), let f2 = d(22) else { return nil }
            let fraction: Int = f0 * 100 + f1 * 10 + f2
            let total: Int = seconds * 1000 + fraction
            // Divided as one number of milliseconds: adding the fraction to the seconds lands one
            // ulp away from the formatter's answer for about a third of all values.
            return Date(timeIntervalSince1970: Double(total) / 1000)
        } ?? nil
    }

    /// The date in UTC, to the nearest millisecond, with the milliseconds written when `millis`
    /// and dropped otherwise (as the formatters do). Nil outside `years`.
    public static func string(_ date: Date, millis: Bool) -> String? {
        let t = date.timeIntervalSince1970
        guard t >= 0, t < end else { return nil }
        let total = Int((t * 1000).rounded(.toNearestOrAwayFromZero))
        let seconds = total / 1000, ms = total % 1000
        let rem = seconds % 86400
        // Civil date from days since 1970 (Howard Hinnant's `civil_from_days`).
        let z = seconds / 86400 + 719_468
        let era = z / 146_097, doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1, month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        guard years.contains(year) else { return nil }
        return String(unsafeUninitializedCapacity: 24) { out in
            var i = 0
            func put(_ c: UInt8) { out[i] = c; i += 1 }
            func two(_ v: Int) { put(UInt8(0x30 + v / 10)); put(UInt8(0x30 + v % 10)) }
            two(year / 100); two(year % 100); put(0x2D); two(month); put(0x2D); two(day); put(0x54)
            two(rem / 3600); put(0x3A); two(rem % 3600 / 60); put(0x3A); two(rem % 60)
            if millis { put(0x2E); put(UInt8(0x30 + ms / 100)); two(ms % 100) }
            put(0x5A)
            return i
        }
    }

    /// Days from 1970-01-01 to a Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400, yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    private static func daysIn(_ month: Int, of year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

extension ISO8601DateFormatter {
    /// A snapshot or `tasks.json` date: whole seconds.
    public static func headroomDate(_ s: String) -> Date? {
        ISO8601Fast.date(s, millis: false) ?? headroom.date(from: s)
    }

    public static func headroomString(_ date: Date) -> String {
        ISO8601Fast.string(date, millis: false) ?? headroom.string(from: date)
    }

    /// A task event's date: milliseconds, or whole seconds.
    public static func headroomEventDate(_ s: String) -> Date? {
        ISO8601Fast.date(s) ?? headroomMillis.date(from: s) ?? headroom.date(from: s)
    }

    public static func headroomEventString(_ date: Date) -> String {
        ISO8601Fast.string(date, millis: true) ?? headroomMillis.string(from: date)
    }
}
