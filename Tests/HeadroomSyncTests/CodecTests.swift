import Foundation
import Testing
import HeadroomKit
@testable import HeadroomSync

@Suite struct CodecTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/v1"))
        return try Data(contentsOf: url)
    }

    @Test func roundTripsThroughTheEnvelope() throws {
        let payload = ActivityDayPayload(day: 20403, slots: [
            ActivitySlot(slot: 1_958_688, model: "claude-opus-4-6", tokens: TokenCounts(newInput: 1, output: 2), micros: 3, unpricedTokens: 0,
                         classMicros: [1, 0, 0, 2]),
        ])
        let data = try PayloadCodec.encode(payload)
        #expect(data.first == 1)
        #expect(try PayloadCodec.decode(ActivityDayPayload.self, from: data) == payload)
    }

    @Test func encodingIsDeterministicSoUnchangedPayloadsSkipTheWrite() throws {
        let p = DevicePayload(name: "Mac", model: nil, appVersion: "1", enabledProviders: [.claude, .codex],
                              currentAccounts: ["claude": "a", "codex": "b"], sessionWarnAt: 0.75,
                              planPriceOverrides: ["codex": 20, "claude": 100], outages: [:], state: .awake, syncSince: nil)
        #expect(try PayloadCodec.encode(p) == PayloadCodec.encode(p))
    }

    @Test func rejectsUnknownFormatsAndGarbage() {
        #expect(throws: PayloadCodec.Failure.empty) { try PayloadCodec.decode(DevicePayload.self, from: Data()) }
        #expect(throws: PayloadCodec.Failure.unknownFormat(9)) { try PayloadCodec.decode(DevicePayload.self, from: Data([9, 1, 2])) }
        #expect(throws: PayloadCodec.Failure.corrupt) { try PayloadCodec.decode(DevicePayload.self, from: Data([1, 0xFF, 0x00])) }
    }

    // MARK: Frozen v1 fixtures: these must decode forever (see memory: persisted-codable-types).

    @Test func decodesTheV1DeviceFixture() throws {
        let d = try JSONDecoder().decode(DevicePayload.self, from: fixture("device"))
        #expect(d.name == "Fixture MacBook Pro")
        #expect(d.enabledProviders == [.claude, .codex]) // an unknown provider is dropped
        #expect(d.currentAccounts["claude"] == "claude-0123456789abcdef")
        #expect(d.sessionWarnAt == 0.6)
        #expect(d.policy.sessionAmber == 0.6)
        #expect(d.planPriceOverrides["claude"] == 200)
        #expect(d.state == .sleeping)
    }

    @Test func decodesTheV1LiveFixture() throws {
        let l = try JSONDecoder().decode(AccountLivePayload.self, from: fixture("live"))
        #expect(l.reading?.provider == .claude)
        #expect(l.reading?.weekly?.used == 0.31)
        #expect(l.reading?.plan?.pill == "MAX 20×")
        #expect(l.fault == .offline)
        #expect(l.shownState == .onPace)
        #expect(l.sessionHitsThisWindow == 2)
        #expect(l.windows.map(\.id) == ["weekly"]) // the broken model-cap window is skipped
        #expect(l.windows[0].series.samples.map(\.used) == [0.29, 0.31])
        #expect(l.session?.series.t.count == 1) // mismatched arrays are trimmed to pairs
        #expect(l.earlyResetAt == nil && l.planThisWindow == nil) // missing keys take defaults
        #expect(l.email == "fixture@example.com")
    }

    @Test func decodesTheV1ArchiveFixture() throws {
        let a = try JSONDecoder().decode(AccountArchivePayload.self, from: fixture("archive"))
        #expect(a.weeks.count == 1)
        #expect(a.weeks[0].ranOut)
        #expect(a.sessions.count == 2)
        #expect(a.sessions[0].samples.isEmpty)
        #expect(a.sessions[1].hitLimit)
    }

    @Test func decodesTheV1ActivityFixture() throws {
        let a = try JSONDecoder().decode(ActivityDayPayload.self, from: fixture("activity"))
        #expect(a.day == 20403)
        #expect(a.slots.count == 2)
        #expect(a.slots[0].tokens.total == 370)
        #expect(a.slots[0].classMicros == [100, 200, 300, 400])
        #expect(a.slots[1].micros == 0 && a.slots[1].classMicros == [0, 0, 0, 0])
    }
}
