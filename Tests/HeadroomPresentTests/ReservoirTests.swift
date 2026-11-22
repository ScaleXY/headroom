import Foundation
import Testing
@testable import HeadroomPresent
import HeadroomKit

/// The reservoir's number never crosses the fill's edge or runs under the renewal tag.
@MainActor @Suite struct ReservoirTests {
    // A popover-width track (332 pt) with a tag whose left edge is at 230, so text may reach 220.
    let right: Double = 220

    @Test func sitsInsideWhenTheBlockFits() {
        let p = Reservoir.place(fill: 180, number: 78, label: 80, right: right)
        #expect(p.inside)
        #expect(p.x == Reservoir.insideX)
        #expect(p.labelRoom >= 80)
    }

    @Test func ridesPastTheEdgeWhenLow() {
        let fill = 60.0
        let p = Reservoir.place(fill: fill, number: 78, label: 80, right: right)
        #expect(!p.inside)
        #expect(p.x == fill + Reservoir.outsideGap)
    }

    @Test func nearlyEmptyStartsAtTheTrack() {
        let p = Reservoir.place(fill: 0, number: 50, label: 80, right: right)
        #expect(!p.inside)
        #expect(p.x == Reservoir.outsideMinX)
    }

    @Test func theThresholdIsTheBlockPlusItsMargins() {
        let block = 80.0
        let edge = Reservoir.insideX + block + Reservoir.insideGap
        #expect(Reservoir.place(fill: edge, number: 78, label: block, right: right).inside)
        #expect(!Reservoir.place(fill: edge - 0.5, number: 78, label: block, right: right).inside)
    }

    /// Sweep every level, with a usual tag and wide ones ("tomorrow 11:30 PM"): text on the fill
    /// stays clear of its edge, text on the track starts past it, and nothing reaches the tag.
    @Test func noTextCrossesTheEdgeAtAnyLevel() {
        let width = 332.0
        for limit in [right, 207.0, 186.0] {
            for (number, label) in [(78.0, 80.0), (52.0, 80.0), (81.3, 80.3), (78.0, 130.0)] {
                for percent in 0...100 {
                    let fill = Reservoir.fillWidth(percentLeft: percent, width: width)
                    let p = Reservoir.place(fill: fill, number: number, label: label, right: limit)
                    let shownNumber = number * p.scale
                    let shownLabel = min(label, p.labelRoom)
                    let end = p.x + max(shownNumber, shownLabel)
                    let tag = "\(percent)% \(number)/\(label) before \(limit)"
                    if p.inside {
                        #expect(end <= fill - Reservoir.insideMinGap + 0.001, "\(tag)")
                    } else {
                        #expect(p.x >= fill + Reservoir.outsideGap - 0.001, "\(tag)")
                    }
                    #expect(end <= limit + 0.001, "\(tag) runs into the tag")
                    #expect(p.scale == 1 || limit < right, "\(tag): only a wide tag squeezes the number")
                }
            }
        }
    }

    @Test func aLongLabelStaysInsideWhenRidingOutWouldHitTheTag() {
        // Fill at 170: the number fits inside, a 160 pt label doesn't, and outside would reach 184 + 78 > 220.
        let p = Reservoir.place(fill: 170, number: 78, label: 160, right: right)
        #expect(p.inside)
        #expect(p.labelRoom == 170 - Reservoir.insideMinGap - Reservoir.insideX)
    }

    @Test func tagWidthHasAFloorAndPadding() {
        #expect(Reservoir.tagWidth(textWidth: 20) == Reservoir.tagMinText + Reservoir.tagPadding * 2)
        #expect(Reservoir.tagWidth(textWidth: 80.2) == 107)
    }

    @Test func fillClampsAndFullDropsTheEdge() {
        #expect(Reservoir.fillWidth(percentLeft: 54, width: 300) == 162)
        #expect(Reservoir.fillWidth(percentLeft: -3, width: 300) == 0)
        #expect(Reservoir.fillWidth(percentLeft: 140, width: 300) == 300)
        #expect(Reservoir.isFull(percentLeft: 100))
        #expect(!Reservoir.isFull(percentLeft: 99))
    }

    @Test func onTrackIsPearlNotWhite() {
        let p = Reservoir.palette(.onPace, dark: true)
        #expect(p.light.hex == 0xE6E8ED)
        #expect(p.deep.hex == 0xAEB2BC)
        #expect(p.plainOnTrack)
        #expect(Reservoir.palette(.onPace, dark: false).light.hex == 0x4C4F57)
    }

    // MARK: The hero's words

    let presenter = Presenter(now: Demo.now, locale: Locale(identifier: "en_US"))

    @Test func heroCarriesTheTagAndTooltip() throws {
        let hero = try #require(presenter.paceCard(Demo.state(.codex, used: 0.46, elapsedH: 92, now: Demo.now)).hero)
        #expect(hero.percentLeft == 54)
        #expect(hero.renewIn == "3 days")
        #expect(hero.renewAt == "Fri 2 PM")
        #expect(hero.tooltip == "54% of this week's allowance left · renews Fri 2:00 PM")
    }

    @Test func heroNearTheRenewal() throws {
        let hours = try #require(presenter.paceCard(Demo.state(.claude, used: 0.18, elapsedH: 148, now: Demo.now)).hero)
        #expect(hours.renewIn == "20 hours")
        #expect(hours.renewAt == "tomorrow 6 AM")
        let minutes = try #require(presenter.paceCard(Demo.state(.claude, used: 0.4, elapsedH: 167.25, now: Demo.now)).hero)
        #expect(minutes.renewIn == "45 min")
        #expect(minutes.renewAt == "today 10:45 AM")
    }

    @Test func reservoirFixturesCoverEveryStateAndTheExtremes() {
        let cards = Demo.reservoirScenarios(now: Demo.now).flatMap { $0.inputs.map { presenter.paceCard($0) } }
        let states = Set(cards.compactMap { $0.meter?.state })
        #expect(states == Set(PacingState.allCases))
        let levels = cards.compactMap { $0.hero?.percentLeft }
        #expect(levels.contains(100))
        #expect(levels.contains { $0 <= 3 })
    }
}
