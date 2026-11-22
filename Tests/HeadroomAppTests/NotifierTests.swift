import Foundation
import Testing
@testable import HeadroomApp

@Suite struct NotifierTests {
    @Test func aResetTimeThatJittersAcrossTheHourIsOneEvent() {
        // The same 05:00 reset, reported a moment early and a moment late on successive readings.
        let hour = 1_790_000_000.0 - 1_790_000_000.0.truncatingRemainder(dividingBy: 3600)
        let early = Date(timeIntervalSince1970: hour - 0.06), late = Date(timeIntervalSince1970: hour + 0.12)
        #expect(Notifier.stamp(early, every: 600) == Notifier.stamp(late, every: 600))
        #expect(Notifier.stamp(early, every: 3600) == Notifier.stamp(late, every: 3600))
        // The next session is another event.
        #expect(Notifier.stamp(late.addingTimeInterval(5 * 3600), every: 600) != Notifier.stamp(late, every: 600))
    }
}
