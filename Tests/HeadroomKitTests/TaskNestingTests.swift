import Foundation
import Testing
@testable import HeadroomKit

/// The fold recurses once per level of the tree, and the app folds off the main thread, where a
/// stack is 512 KB. Nesting as deep as real plans and agent chains go has to fit with room to spare.
/// Far deeper still overflows that stack (somewhere past 25 levels in a debug build): nothing
/// bounds the depth of a path or of a chain of spawns yet.
@Suite struct TaskNestingTests {
    /// Folds on a thread with a dispatch worker's stack and returns how many nodes came out.
    func nodesOnASmallStack(_ events: [TaskEvent], now: TimeInterval) -> Int {
        final class Box: @unchecked Sendable { var nodes = -1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let t = Thread { box.nodes = TaskFold.fold(events, now: TL.t(now)).first?.nodes.count ?? -1; done.signal() }
        t.stackSize = 512 * 1024
        t.start()
        done.wait()
        return box.nodes
    }

    @Test func aTwelveLevelPlanFoldsOnASmallStack() {
        var tl = TL()
        let deep = Array(repeating: "a", count: 12).joined(separator: "/")
        tl.add(0, deep)
        tl.at(1, .start(task: deep))
        #expect(nodesOnASmallStack(tl.events, now: 5) == 12)
    }

    @Test func twelveAgentsSpawningEachOtherFoldOnASmallStack() {
        var tl = TL()
        tl.attempt(0, "k0")
        for i in 1..<12 { tl.attempt(Double(i), "k\(i)", parent: "k\(i - 1)") }
        #expect(nodesOnASmallStack(tl.events, now: 60) == 12)
    }
}
