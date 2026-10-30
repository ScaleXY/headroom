import Foundation
import Testing
@testable import HeadroomKit

@Suite struct WidgetFeedTests {
    let now = PT.date(2026, 10, 20, 10)

    @Test func burnRatioIsAgainstThePaceThatLastsToTheReset() {
        // 40% left with 8 h to go lasts at 5%/h: burning 10%/h is twice that.
        let b = WidgetBurn(perHour: 0.10, averagePerHour: 0.04, lastingPerHour: 0.05)
        #expect(abs(b.ratio! - 2) < 1e-9)
        #expect(abs(b.averageRatio! - 0.8) < 1e-9)
        #expect(WidgetBurn(perHour: nil, averagePerHour: nil, lastingPerHour: 0.05).ratio == nil)
        // Nothing left: off the dial.
        #expect(WidgetBurn(perHour: 0, averagePerHour: nil, lastingPerHour: 0).ratio == .infinity)
    }

    @Test func dialZonesFollowThePacingColors() {
        #expect(BurnGauge.state(0) == .plenty)
        #expect(BurnGauge.state(0.79) == .plenty)
        #expect(BurnGauge.state(1) == .onPace)
        #expect(BurnGauge.state(1.2) == .tight)
        #expect(BurnGauge.state(2.5) == .veryTight)
        // The bands cover the dial end to end, in order.
        #expect(BurnGauge.zones.first?.from == 0 && BurnGauge.zones.last?.to == BurnGauge.maxRatio)
        for (a, b) in zip(BurnGauge.zones, BurnGauge.zones.dropFirst()) { #expect(a.to == b.from) }
    }

    @Test func thinningKeepsEveryReset() {
        var points = (0..<1000).map { WidgetPoint(t: Double($0) * 0.024, u: Double($0 % 200) / 200) }
        points[500] = WidgetPoint(t: points[500].t, u: 0, refill: true)
        let thin = BurnGauge.thin(points, limit: 100)
        #expect(thin.count <= 104)
        #expect(thin.first == points.first && thin.last == points.last)
        #expect(thin.contains(points[500]) && thin.contains(points[499]))
        #expect(BurnGauge.thin(Array(points.prefix(50)), limit: 100).count == 50)
    }

    @Test func focusIsTheProviderThatNeedsWatching() {
        func week(_ state: PacingState, burn: Double) -> WidgetWeek {
            WidgetWeek(caption: "left this week", left: 0.5, state: state, multiple: 1, cells: 3, caret: 0.5, resetsAt: now, hourglass: false,
                       verdictTitle: "", verdict: "", burn: WidgetBurn(perHour: burn, averagePerHour: nil, lastingPerHour: 1), chart: nil)
        }
        let calm = WidgetProvider(id: .claude, week: week(.plenty, burn: 0.4))
        let hot = WidgetProvider(id: .codex, week: week(.onPace, burn: 1.8))
        #expect(WidgetFeed(generatedAt: now, providers: [calm, hot]).focus?.id == .codex)
        var blocked = calm
        blocked.blockedUntil = now
        #expect(WidgetFeed(generatedAt: now, providers: [blocked, hot]).focus?.id == .claude)
        // A provider with nothing read yet never takes the widget from one that has.
        #expect(WidgetFeed(generatedAt: now, providers: [WidgetProvider(id: .claude), hot]).focus?.id == .codex)
    }

    @Test func roundTripsThroughTheFile() throws {
        let session = WidgetSession(used: 0.84, resetsAt: now.addingTimeInterval(3600), startedAt: now.addingTimeInterval(-4 * 3600),
                                    level: .amber, outlook: .runsOut, runsOutAt: now.addingTimeInterval(1800), leftAtReset: 0,
                                    burn: WidgetBurn(perHour: 0.3, averagePerHour: 0.21, lastingPerHour: 0.16),
                                    chart: WidgetChart(start: now.addingTimeInterval(-23 * 3600), hours: 24, nowT: 23,
                                                       points: [WidgetPoint(t: 0, u: 0), WidgetPoint(t: 5, u: 0, refill: true)],
                                                       endT: 23.5, endRemaining: 0, runsOut: true, evenFrom: 19))
        let feed = WidgetFeed(generatedAt: now, providers: [WidgetProvider(id: .claude, plan: "MAX 20×", session: session, hourlyTokens: [1, 2])])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetFeed.fileName)
        try SnapshotFile.encoder().encode(feed).write(to: url)
        #expect(WidgetFeed.read(from: url) == feed)
    }
}
