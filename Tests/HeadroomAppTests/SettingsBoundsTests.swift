import Foundation
import Testing
@testable import HeadroomApp

/// Values read back from defaults are held to what Settings offers: they can be written from
/// outside the app, and the fan temperatures go on to the root helper.
@MainActor @Suite struct SettingsBoundsTests {
    @Test func fanTemperaturesStayWithinTheChoices() {
        let suite = "com.scalexy.headroom.tests.settings-bounds"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.fanMinTemp == 45 && settings.fanMaxTemp == 70)
        defaults.set(1_000_000, forKey: "fanMaxTemp")
        defaults.set(-40, forKey: "fanMinTemp")
        #expect(settings.fanMaxTemp == AppSettings.fanMaxTempChoices.last)
        #expect(settings.fanMinTemp == AppSettings.fanMinTempChoices.first)
        settings.fanMaxTemp = 85
        #expect(settings.fanMaxTemp == 85)
    }
}
