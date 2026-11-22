import AppKit
import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

/// The Limits card's chart with its lane: measured and drawn heights agree, and lane bars hover.
@MainActor @Suite struct LimitsCardTests {
    let presenter = Presenter(now: Demo.now, locale: Locale(identifier: "en_US"))
    let width: CGFloat = 348

    func drawn(_ m: PaceCardModel, theme: Theme = .dark) -> (measured: CGFloat, drawn: CGFloat, out: RenderOutput) {
        let measured = PaceCardRenderer.draw(m, origin: .zero, width: width, theme: theme, ctx: nil)
        let out = RenderOutput()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(width), height: Int(measured) + 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let drawn = PaceCardRenderer.draw(m, origin: .zero, width: width, theme: theme, ctx: ctx, out: out)
        return (measured, drawn, out)
    }

    @Test func measureMatchesDrawForEveryLimitsFixture() {
        for s in Demo.limitsScenarios(now: Demo.now) {
            for input in s.inputs {
                let r = drawn(presenter.paceCard(input))
                #expect(r.measured == r.drawn, "\(s.name)")
            }
        }
    }

    @Test func theLaneAddsItsHeight() {
        var with = presenter.paceCard(Demo.limitsSession(0.42, now: Demo.now))
        let tall = drawn(with).measured
        with.lane = nil
        let short = drawn(with).measured
        let inner = width - PaceCardRenderer.padX * 2
        #expect(abs((tall - short) - (GlideChartRenderer.height(width: inner, lane: true) - GlideChartRenderer.height(width: inner))) < 0.001)
    }

    @Test func laneBarsCarryTooltips() throws {
        let m = presenter.paceCard(Demo.limitsSession(0.42, now: Demo.now))
        let lane = try #require(m.lane)
        let tips = drawn(m).out.regions.compactMap(\.tooltip)
        for s in lane.sessions { #expect(tips.contains(s.tooltip)) }
        #expect(tips.contains(try #require(lane.current?.tooltip)))

        let daily = presenter.paceCard(Demo.limitsDaily(now: Demo.now))
        let dayTips = drawn(daily).out.regions.compactMap(\.tooltip)
        for d in daily.lane?.days ?? [] { if let t = d.tooltip { #expect(dayTips.contains(t)) } }
    }
}
