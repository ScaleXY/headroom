import Foundation
import Testing
@testable import HeadroomKit

/// The fast paths must be indistinguishable from the formatters they stand in for.
@Suite struct ISO8601FastTests {
    private func bits(_ d: Date?) -> UInt64? { d?.timeIntervalSinceReferenceDate.bitPattern }

    @Test func parsesExactlyAsTheFormattersDo() {
        var g = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            let d = Date(timeIntervalSince1970: Double(Int.random(in: 0..<4_102_444_800_000, using: &g)) / 1000)
            let m = ISO8601DateFormatter.headroomMillis.string(from: d), w = ISO8601DateFormatter.headroom.string(from: d)
            #expect(ISO8601Fast.date(m) != nil && bits(ISO8601Fast.date(m)) == bits(ISO8601DateFormatter.headroomMillis.date(from: m)), "\(m)")
            #expect(ISO8601Fast.date(w) != nil && bits(ISO8601Fast.date(w)) == bits(ISO8601DateFormatter.headroom.date(from: w)), "\(w)")
        }
    }

    @Test func writesExactlyAsTheFormattersDo() {
        var g = SystemRandomNumberGenerator()
        for i in 0..<6000 {
            var t = Double.random(in: 0..<4_102_444_000, using: &g)
            switch i % 4 {
            case 1: t = (t * 1000).rounded() / 1000 + 0.0005
            case 2: t = (t * 1000).rounded() / 1000
            case 3: t = t.rounded() + [0.9995, 0.9999, 0.99949, 0.4995, 0.0005][i % 5]
            default: break
            }
            let d = Date(timeIntervalSince1970: t)
            #expect(ISO8601Fast.string(d, millis: true) == ISO8601DateFormatter.headroomMillis.string(from: d), "\(t)")
            #expect(ISO8601Fast.string(d, millis: false) == ISO8601DateFormatter.headroom.string(from: d), "\(t)")
        }
    }

    /// Whatever the fast path doesn't take goes to the formatter, so every reader answers as before.
    @Test func everythingElseFallsBackToTheFormatters() {
        let odd = ["2026-11-12T10:04:05.1Z", "2026-11-12T10:04:05.12Z", "2026-11-12T10:04:05.1239Z", "2026-11-12T10:04:05.123456Z",
                   "2026-11-12T10:04:05.120+00:00", "2026-11-12T10:04:05+05:30", "2026-11-12t10:04:05z", "2026-11-12T10:04:05.120z",
                   "2026-02-30T10:04:05Z", "2026-02-30T10:04:05.000Z", "2026-11-12T24:00:00Z", "2026-11-12T23:59:60Z", "2026-11-12T10:04:05.120Z ",
                   " 2026-11-12T10:04:05Z", "2026-11-12 10:04:05Z", "20261112T100405Z", "2026-11-12T10:04:05,120Z", "0001-01-01T00:00:00Z",
                   "1969-12-31T23:59:59.999Z", "1969-12-31T23:59:59Z", "2100-01-01T00:00:00Z", "2100-01-01T00:00:00.000Z", "2099-12-31T23:59:59.999Z",
                   "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-11-00T00:00:00Z", "2024-02-29T00:00:00Z", "2023-02-29T00:00:00Z",
                   "2026-11-12T10:60:05Z", "2026-11-12T10:04:05.Z", "+2026-11-12T10:04:05Z", "2026-11-12T10:04:05.120ZZ", "2026-11-12T10:04:05Zjunk",
                   "2026-11-12T10:04:05.12aZ", "２０２６-11-12T10:04:05Z", "", "Z", "not a date", "2026-11-12T10:04:05"]
        for s in odd {
            let event = ISO8601DateFormatter.headroomMillis.date(from: s) ?? ISO8601DateFormatter.headroom.date(from: s)
            #expect(bits(ISO8601DateFormatter.headroomEventDate(s)) == bits(event), "\(s)")
            #expect(bits(ISO8601DateFormatter.headroomDate(s)) == bits(ISO8601DateFormatter.headroom.date(from: s)), "\(s)")
        }
        for t in [-1.5, -0.0004, 4_102_444_799.9996, 4_102_444_800, 5_000_000_000, -62_135_769_600] {
            let d = Date(timeIntervalSince1970: t)
            #expect(ISO8601DateFormatter.headroomEventString(d) == ISO8601DateFormatter.headroomMillis.string(from: d), "\(t)")
            #expect(ISO8601DateFormatter.headroomString(d) == ISO8601DateFormatter.headroom.string(from: d), "\(t)")
        }
    }

    /// Whole-second files never took a fraction, and still don't.
    @Test func snapshotDatesStayWholeSeconds() {
        #expect(ISO8601Fast.date("2026-11-12T10:04:05.120Z", millis: false) == nil)
        #expect(ISO8601DateFormatter.headroomDate("2026-11-12T10:04:05.120Z") == nil)
        #expect(ISO8601DateFormatter.headroomDate("2026-11-12T10:04:05Z") == Date(timeIntervalSince1970: 1_794_477_845))
    }
}
