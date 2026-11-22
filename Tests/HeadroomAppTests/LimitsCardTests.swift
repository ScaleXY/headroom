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

    @Test func measureMatchesDrawWithoutTheLevel() {
        for s in Demo.reservoirScenarios(now: Demo.now) {
            for input in s.inputs {
                var m = presenter.paceCard(input)
                m.showsMeter = false
                let r = drawn(m, theme: .light)
                #expect(r.measured == r.drawn, "\(s.name)")
            }
        }
    }

    @Test func theReservoirCarriesItsTooltip() throws {
        let m = presenter.paceCard(Demo.state(.codex, used: 0.46, elapsedH: 92, now: Demo.now))
        let tip = try #require(m.hero?.tooltip)
        #expect(drawn(m).out.regions.contains { $0.tooltip == tip })
    }

    /// With the real fonts at the popover's width: at every level the number and its line stay on
    /// one side of the fill's edge, and clear of the renewal tag.
    @Test func reservoirTextNeverCrossesTheEdge() throws {
        let inner = (PopoverChrome.width - PopoverChrome.pad * 2) - PaceCardRenderer.padX * 2
        let rect = CGRect(x: 0, y: 0, width: inner, height: CGFloat(Reservoir.height))
        var hero = try #require(presenter.paceCard(Demo.state(.claude, used: 0.18, elapsedH: 148, now: Demo.now)).hero)
        for (renewIn, renewAt) in [("3 days", "Fri 2 PM"), ("20 hours", "tomorrow 6 AM"), ("45 min", "today 10:45 AM"), ("23 hours", "tomorrow 11:30 PM")] {
            hero.renewIn = renewIn
            hero.renewAt = renewAt
            for percent in 0...100 {
                hero.percentLeft = percent
                let l = ReservoirRenderer.layout(hero, filled: true, rect: rect)
                let tag = try #require(l.tag)
                let label = Text(l.label, ReservoirRenderer.labelFont, .black).width + 1
                let x = CGFloat(l.placement.x)
                let end = x + max(l.numberWidth * CGFloat(l.placement.scale), label)
                if l.placement.inside {
                    #expect(end <= l.fill - CGFloat(Reservoir.insideMinGap) + 0.01, "\(percent)%")
                } else {
                    #expect(x >= l.fill + CGFloat(Reservoir.outsideGap) - 0.01, "\(percent)%")
                }
                #expect(end <= tag.minX - CGFloat(Reservoir.tagGap) + 0.01, "\(percent)% \(renewIn)")
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
