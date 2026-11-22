import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomKit

/// `headroom task close` (and its old name), and work that's the user's (`wait --for you`).
@Suite(.serialized) struct TaskLifecycleCLITests {
    @Test func closeWritesTheSameEventAsAbandonAndSaysClosed() {
        let h = Home()
        h.run(["task", "add", "a", "--title", "A"])
        h.run(["task", "add", "b", "--title", "B"])
        let (code, out) = h.run(["task", "close", "--reason", "not needed"])
        #expect(code == 0 && out.contains("closed"))
        // On disk it is still run.abandon: older apps fold it, and the stored flag is the same.
        #expect(h.events().contains { $0.op == .abandon(reason: "not needed") })
        let r = h.fold()!
        #expect(r.abandoned && r.isSettled)
        // The old name still works.
        let g = Home()
        g.run(["task", "add", "a", "--title", "A"])
        #expect(g.run(["task", "abandon"]).0 == 0 && g.fold()!.abandoned)
        // It closes a whole run, never a task, and needs one that exists.
        #expect(h.run(["task", "close", "a"]).0 == 64)
        #expect(Home().run(["task", "close"]).0 == 64)
        #expect(h.run(["task", "close", "--help"]).1.contains("usage: headroom task close"))
    }

    @Test func waitForYouMarksTheUsersWork() {
        let h = Home()
        h.run(["task", "add", "submit", "--title", "Submit in App Store Connect"])
        let (code, out) = h.run(["task", "wait", "submit", "--for", "you", "--note", "only you can submit"])
        #expect(code == 0 && out.contains("submit is the user's to do"))
        let r = h.fold()!
        #expect(r.node("submit").waitReason == .you && !r.needsInput && r.question == nil)
        // The help and the guide teach it in a line.
        #expect(h.run(["task", "wait", "--help"]).1.contains("--for you marks work only the user can do"))
        #expect(h.run(["task", "guide"]).1.contains("--for you"))
        #expect(h.run(["task", "--help"]).1.contains("input|dependency|limit|you"))
        // An unknown reason names all four.
        #expect(h.run(["task", "wait", "submit", "--for", "later"]).0 == 64)
    }

    @Test func statusSaysYourTurnAndYours() {
        let h = Home()
        h.run(["task", "add", "a", "--title", "A"])
        h.run(["task", "add", "submit", "--title", "Submit"])
        h.run(["task", "done", "a"])
        h.run(["task", "wait", "submit", "--for", "you"])
        _ = h.run(["task", "hook"], env: [:], stdin: #"{"session_id": "r1", "hook_event_name": "Stop"}"#)
        let out = h.run(["task", "status"]).1
        #expect(out.contains("your turn") && out.contains("yours"))
        #expect(!out.contains("stopped with work left"))
    }
}
