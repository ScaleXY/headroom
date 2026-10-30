import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomSync

/// `state.plist` decodes in one piece: a field older files lack must never stop it decoding,
/// or the app starts with empty history and later overwrites the file.
@Suite struct PersistedStateTests {
    /// `PersistedState` as it was before sync (no `accountTimeline`).
    struct Before: Codable {
        var version = 2
        var history = HistoryStore()
        var lastGood: [String: LimitReading] = [:]
        var claudeRefreshLastRun: Date?
        var codexAccountKey: String?
    }

    @Test func stateSavedBeforeSyncStillDecodesWithItsHistory() throws {
        var old = Before()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        old.history.record(LimitReading(provider: .claude, fetchedAt: t0, source: .api,
                                        windows: [LimitWindow(id: "weekly", kind: .weekly, used: 0.4, resetsAt: t0.addingTimeInterval(86400))],
                                        accountKey: "claude-a"), now: t0)
        old.codexAccountKey = "codex-b"
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(PersistedState.self, from: encoder.encode(old))
        #expect(decoded.history.account(.claude, "claude-a")?.windows["weekly"]?.samples.count == 1)
        #expect(decoded.codexAccountKey == "codex-b")
        #expect(decoded.accountTimeline == nil)
    }

    @Test func readingsSavedBeforeAccountEmailsStillDecode() throws {
        let json = #"{"provider":"codex","fetchedAt":0,"source":"appServer","windows":[],"resetCredits":[]}"#
        let r = try JSONDecoder().decode(LimitReading.self, from: Data(json.utf8))
        #expect(r.accountEmail == nil)
    }

    @Test func historyKeysSplitIntoProviderAndAccount() {
        #expect(CloudPublisher.split("claude:claude-0123")! == (.claude, "claude-0123"))
        #expect(CloudPublisher.split("codex:default")! == (.codex, nil))
        #expect(CloudPublisher.split("nonsense") == nil)
    }
}
