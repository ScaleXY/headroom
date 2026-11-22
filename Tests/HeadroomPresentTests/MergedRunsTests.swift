import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let presenter: RunsPresenter = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return RunsPresenter(now: now, calendar: cal, locale: Locale(identifier: "en_US"))
}()

private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

/// A run on this Mac.
private func local(_ id: String, title: String? = nil, _ state: TaskRunState = .running, wait: TaskWaitReason? = nil, updated: Double = 1,
                   hidden: Bool = false) -> TaskRun {
    TaskRun(id: id, title: title ?? "Local \(id)", startedAt: ago(updated + 30), updatedAt: ago(updated), state: state, waitReason: wait,
            hasDeclaredTasks: true, nodes: [TaskNode(id: "a", title: "Step", state: state.isTerminal ? .done : .running, startedAt: ago(updated + 30))],
            hidden: hidden, host: "Terminal", cwd: "/tmp/x")
}

/// A run another Mac synced; `lastSeen` set when that Mac went quiet.
private func remote(_ id: String, title: String? = nil, _ state: TaskRunState = .running, wait: TaskWaitReason? = nil, updated: Double = 1,
                    lastSeen: Date? = nil, rows: [RunDigest.Row]? = nil) -> RunDigest {
    RunDigest(id: "studio:" + id, mac: "Mac Studio", state: state, waitReason: wait, hasDeclaredTasks: true, startedAt: ago(updated + 30),
              updatedAt: ago(updated), counts: RunCounts(running: state.isTerminal ? 0 : 1, done: 1), title: title, rows: rows, lastSeen: lastSeen)
}

@MainActor @Suite struct MergedRunsTests {
    @Test func onlyAnotherMacsCardsNameTheirMac() {
        let page = presenter.page([local("a"), local("b", .done)], remote: [remote("c", title: "Elsewhere"), remote("d", .done)])
        for card in page.live + page.recent {
            #expect(card.mac == (card.id.hasPrefix("studio:") ? "Mac Studio" : nil), "\(card.id)")
        }
    }

    @Test func withNothingSyncedThePageIsThisMacsOwn() {
        let runs = Demo.mixedRuns(now: now)
        let first = runs[0].id
        #expect(presenter.page(runs, remote: []) == presenter.page(runs))
        #expect(presenter.page(runs, remote: [], expanded: [first], opened: [RunsPresenter.rowKey(run: first, row: runs[0].nodes.first?.id ?? "")], allRecent: true)
            == presenter.page(runs, expanded: [first], opened: [RunsPresenter.rowKey(run: first, row: runs[0].nodes.first?.id ?? "")], allRecent: true))
        // Finished runs past the cap too.
        let many = (0..<7).map { local("f\($0)", .done, updated: Double($0) + 1) }
        #expect(presenter.page(many, remote: [], allRecent: true) == presenter.page(many, allRecent: true))
        #expect(presenter.page(many, remote: []) == presenter.page(many))
    }

    @Test func liveRunsAreMostPressingFirstAcrossBothMacs() {
        let runs = [local("stale", updated: 3), local("fresh", updated: 1)].sortedForDisplay()
        let synced = [remote("asks", .waiting, wait: .input, updated: 20), remote("mid", updated: 2), remote("limit", .waiting, wait: .limit, updated: 5)]
        let page = presenter.page(runs, remote: synced)
        // Needs input, then waiting on a limit, then running, newest update first.
        #expect(page.live.map(\.id) == ["studio:asks", "studio:limit", "fresh", "studio:mid", "stale"])
        #expect(page.recent.isEmpty)
        // The order doesn't depend on how the synced ones arrive.
        #expect(presenter.page(runs, remote: synced.reversed()).live.map(\.id) == page.live.map(\.id))
    }

    @Test func aQuietMacsRunsComeAfterEveryRunStillHeardFrom() {
        let seen = ago(90)
        let synced = [remote("gone-asks", .waiting, wait: .input, updated: 95, lastSeen: seen), remote("gone", updated: 91, lastSeen: seen),
                      remote("here", updated: 4)]
        let page = presenter.page([local("mine", updated: 10)], remote: synced)
        #expect(page.live.map(\.id) == ["studio:here", "mine", "studio:gone-asks", "studio:gone"])
        // It says when its Mac was last heard from, and isn't counted as needing you.
        let gone = page.live[2]
        #expect(gone.stateText.hasPrefix("Mac last seen"))
        #expect(!gone.needsInput)
    }

    @Test func finishedRunsAreNewestFirstAndShareTheCap() {
        let runs = [local("a", .done, updated: 10), local("c", .failed, updated: 30), local("e", .done, updated: 50)]
        let synced = [remote("b", .done, updated: 20), remote("d", .partial, updated: 40), remote("f", .done, updated: 60)]
        let page = presenter.page(runs, remote: synced)
        #expect(page.live.isEmpty)
        #expect(page.recent.map(\.id) == ["a", "studio:b", "c", "studio:d"])
        #expect(page.moreRecent == 2)
        #expect(!page.allRecent)
        let all = presenter.page(runs, remote: synced, allRecent: true)
        #expect(all.recent.map(\.id) == ["a", "studio:b", "c", "studio:d", "e", "studio:f"])
        #expect(all.moreRecent == 0)
        #expect(all.allRecent)
        // Opened with nothing past the cap, there is nothing to fold back.
        #expect(!presenter.page(Array(runs.prefix(1)), remote: Array(synced.prefix(1)), allRecent: true).allRecent)
    }

    @Test func eachSourceKeepsItsOwnWindow() {
        let day = 24 * 60.0
        let runs = [local("old-asks", .waiting, wait: .input, updated: day + 60), local("old", updated: day + 60), local("hidden", hidden: true)]
        let synced = [remote("old-asks", .waiting, wait: .input, updated: day + 60), remote("old-done", .done, updated: day + 5), remote("new", updated: 2)]
        let page = presenter.page(runs.sortedForDisplay(), remote: synced)
        // This Mac's run waiting on you stays however long; a synced one drops out after a day.
        #expect(page.live.map(\.id) == ["old-asks", "studio:new"])
        #expect(page.recent.isEmpty && page.moreRecent == 0)
    }

    @Test func sameNamedRunsSayWhenTheyStartedWhicheverMacTheyRanOn() {
        let page = presenter.page([local("1", title: "Ship the release"), local("2", title: "Fix the build")],
                                  remote: [remote("3", title: "Ship the release", .done, updated: 12), remote("4", title: "Port the tests")])
        let titles = Dictionary(uniqueKeysWithValues: (page.live + page.recent).map { ($0.id, $0.title) })
        #expect(titles["1"]?.hasPrefix("Ship the release · ") == true)
        #expect(titles["studio:3"]?.hasPrefix("Ship the release · ") == true)
        #expect(titles["2"] == "Fix the build")
        #expect(titles["studio:4"] == "Port the tests")
        // Two unnamed runs share "Agent run", so each says when it started.
        let unnamed = presenter.page([local("1")], remote: [remote("5"), remote("6", updated: 3)])
        #expect(unnamed.live.filter { $0.id.hasPrefix("studio:") }.allSatisfy { $0.title.hasPrefix("Agent run · ") })
    }

    @Test func syncedCardsHaveNoActionsAndThisMacsKeepTheirs() {
        let page = presenter.page([local("mine"), local("done", .done, updated: 9)],
                                  remote: [remote("asks", .waiting, wait: .input), remote("theirs", .done, updated: 8)])
        for card in page.live + page.recent {
            if card.id.hasPrefix("studio:") {
                #expect(card.actions == .none, "\(card.id)")
                // Its page is the synced one: finished tasks counted, never listed.
                #expect(card.page?.listsDone == false, "\(card.id)")
            } else {
                #expect(card.actions.hide && card.actions.openSession, "\(card.id)")
            }
        }
        #expect(page.live.first?.id == "studio:asks")
        #expect(page.live.first?.needsInput == true)
    }

    @Test func expandingASyncedCardListsEveryRowItSynced() {
        let rows = (0..<RunsPresenter.rowCap + 5).map { RunDigest.Row(title: "Task \($0)", state: .running) }
        let d = remote("big", title: "Big plan", rows: rows)
        let closed = presenter.page([local("mine")], remote: [d]).live.first { $0.id == d.id }
        let open = presenter.page([local("mine")], remote: [d], expanded: [d.id]).live.first { $0.id == d.id }
        #expect(closed?.expandable == true && closed?.expanded == false)
        #expect(open?.expanded == true)
        #expect(open?.rows.filter { $0.kind == .task }.count == rows.count)
        // The phone's card, with the Mac it came from noted for the list.
        var synced = presenter.card(d, expanded: true)
        synced.mac = d.mac
        #expect(open == synced)
    }
}
