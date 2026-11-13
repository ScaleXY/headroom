import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

/// Pace's "What's spending it".
@MainActor @Suite struct PaceSpendTests {
    let presenter = Presenter(now: Demo.now)

    @Test func runsThenEverythingElse() throws {
        let split = try #require(presenter.spendSplit([RunSpend(title: "design-system", share: 0.21), RunSpend(title: "Move checkout", share: 0.62)]))
        #expect(split.title == "What's spending it")
        #expect(split.slices.map(\.label) == ["Move checkout", "design-system", "other sessions"])
        #expect(split.slices.map(\.percent) == ["62%", "21%", "17%"])
        #expect(split.slices.map(\.isOther) == [false, false, true])
        #expect(abs(split.slices.map(\.share).reduce(0, +) - 1) < 1e-9)
    }

    @Test func hiddenWithoutALiveRun() {
        #expect(presenter.spendSplit([]) == nil)
        #expect(presenter.spendSplit([RunSpend(title: "Idle", share: 0.001)]) == nil)
        var input = Demo.claudeMockup(now: Demo.now)
        #expect(presenter.paceCard(input).spending == nil)
        input.runSpend = [RunSpend(title: "Move checkout", share: 0.5)]
        #expect(presenter.paceCard(input).spending?.slices.count == 2)
    }

    @Test func neverMoreThanTheWhole() throws {
        // Rates measured over slightly different windows can add past 100%.
        let split = try #require(presenter.spendSplit([RunSpend(title: "a", share: 0.7), RunSpend(title: "b", share: 0.6)]))
        #expect(split.slices.map(\.label) == ["a", "b"])
        #expect(split.slices.map(\.percent) == ["54%", "46%"])
    }

    @Test func atMostThreeRunsByName() throws {
        let runs = (1...5).map { RunSpend(title: "run \($0)", share: 0.15) }
        let split = try #require(presenter.spendSplit(runs))
        #expect(split.slices.count == 4 && split.slices.last?.label == "other sessions")
        #expect(split.slices.compactMap { Int($0.percent.dropLast()) }.reduce(0, +) == 100)
    }
}
