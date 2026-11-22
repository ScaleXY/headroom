import Foundation
import Testing
@testable import HeadroomApp

/// Updates: a check every hour, and each update installs once downloaded unless Settings holds it
/// for Update & Restart.
@MainActor @Suite struct UpdatePolicyTests {
    @Test func holdingUpdatesIsOffUntilTurnedOn() {
        let suite = "com.scalexy.headroom.tests.update-policy"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.holdUpdates)
        settings.holdUpdates = true
        #expect(AppSettings(defaults: defaults).holdUpdates)
    }

    /// Sparkle installs a background download on quit whatever it's told, so a held update must
    /// never download on its own.
    @Test func onlyUpdatesThatAreNotHeldDownloadOnTheirOwn() {
        #expect(AppUpdater.downloadsInBackground(hold: false))
        #expect(!AppUpdater.downloadsInBackground(hold: true))
    }

    @Test func checksEveryHour() throws {
        #expect(AppUpdater.checkInterval == 3600)
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Packaging/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        #expect(info["SUScheduledCheckInterval"] as? Int == 3600)
    }
}
