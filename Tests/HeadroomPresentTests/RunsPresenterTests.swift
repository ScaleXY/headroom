import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private let presenter: RunsPresenter = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return RunsPresenter(now: t0, calendar: cal, locale: Locale(identifier: "en_US"))
}()

private func node(_ id: String, _ state: TaskState, parent: String? = nil, depth: Int = 0, title: String? = nil, wait: TaskWaitReason? = nil,
                  stale: Bool = false, importance: TaskImportance = .normal, declared: Bool = true, confirmed: Bool = true, leaf: Bool = true,
                  note: String? = nil, failure: String? = nil, waitNote: String? = nil) -> TaskNode {
    TaskNode(id: id, title: title ?? id, parent: parent, depth: depth, state: state, waitReason: wait, stale: stale, importance: importance,
             declared: declared, confirmed: confirmed, leaf: leaf, note: note, waitNote: waitNote, failure: failure,
             startedAt: at(-30), endedAt: state.isTerminal ? at(-5) : nil, lastActivityAt: at(-20))
}

private func run(_ id: String = "r", title: String? = nil, project: String? = nil, harness: String? = nil, state: TaskRunState = .running,
                 wait: TaskWaitReason? = nil, stale: Bool = false, declared: Bool = true, nodes: [TaskNode] = [], updated: Double = -1,
                 warning: String? = nil, earlier: Int? = nil, session: String? = nil, repo: String? = nil, branch: String? = nil) -> TaskRun {
    TaskRun(id: id, title: title ?? id, project: project, harness: harness, startedAt: at(-60), updatedAt: at(updated), state: state, waitReason: wait,
            stale: stale, progress: TaskProgress(done: 0.46, inFlight: 0.3, estimate: 0.57), mustHaves: TaskMustHaves(done: 1, total: 2),
            etaSeconds: 25 * 60, tokens: 2_310_000, warning: warning, hasDeclaredTasks: declared, nodes: nodes, finishedEarlier: earlier,
            sessionTitle: session, repo: repo, branch: branch)
}

@Suite struct RunTitleTests {
    @Test func aRunIsTitledByWhatItIsAndPlacedInTheSubtitle() {
        let uuid = "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60"
        #expect(presenter.displayTitle(run(title: "Ship it")) == "Ship it")
        // The session's own title (Claude Code's or Codex's), below the agent's declared one.
        #expect(presenter.displayTitle(run(uuid, project: "storefront", harness: "claude-code", session: "Fix the refund webhook")) == "Fix the refund webhook")
        #expect(presenter.displayTitle(run(title: "Ship it", session: "Fix the refund webhook")) == "Ship it")
        // Never the folder, the id or the device: with no name it says what ran it.
        #expect(presenter.displayTitle(run(uuid, project: "storefront", harness: "claude-code")) == "Claude Code run")
        #expect(presenter.displayTitle(run(uuid, harness: "codex")) == "Codex run")
        #expect(presenter.displayTitle(run(uuid)) == "Agent run")
        // Where it runs is additional: the repo (else the folder), and a branch that isn't the default.
        #expect(presenter.card(run(uuid, project: "storefront", harness: "claude-code", session: "Fix the refund webhook", repo: "ScaleXY/storefront",
                                   branch: "refund-webhook")).subtitle == "ScaleXY/storefront · refund-webhook · Claude Code · updated 1m ago")
        #expect(presenter.card(run(uuid, project: "storefront", harness: "claude-code", branch: "main")).subtitle == "storefront · updated 1m ago")
        #expect(presenter.card(run(title: "Ship it", project: "storefront")).subtitle == "storefront · updated 1m ago")
    }

    @Test func aTitleThatStartsWithTheHarnessKeepsItInTheSubtitle() {
        let r = run("r", harness: "claude-code", session: "Claude Code hook for billing")
        #expect(presenter.card(r).subtitle == "Claude Code · updated 1m ago")
    }

    /// Where nothing sits under the name (a dialog, an alert, Recent runs), an untitled run says where.
    @Test func aRunsLabelSaysWhereWhenItHasNoTitle() {
        let uuid = "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60"
        #expect(presenter.label(run(uuid, project: "storefront", harness: "claude-code", repo: "acme/storefront")) == "Claude Code run · acme/storefront")
        #expect(presenter.label(run(uuid, project: "storefront", harness: "codex")) == "Codex run · storefront")
        #expect(presenter.label(run(uuid)) == "Agent run")
        #expect(presenter.label(run(uuid, project: "storefront", session: "Fix the refund webhook")) == "Fix the refund webhook")
    }

    @Test func clashingTitlesSayWhenTheyStarted() {
        let page = presenter.page([run("a", project: "web", harness: "codex"), run("b", project: "web", harness: "codex"),
                                   run("c", project: "api", harness: "codex", session: "Rename the billing tables")])
        #expect(page.live.map(\.title) == ["Codex run · today 7 AM", "Codex run · today 7 AM", "Rename the billing tables"])
    }
}

@Suite struct RunHeadlineTests {
    @Test func declaredRunsShowThePercent() {
        // The best guess (the estimate), rounded down; no separate "by tokens" figure.
        let c = presenter.card(run(title: "Plan"))
        #expect(c.declared && c.headline == "57%" && c.estimate == nil && c.bar != nil)
        #expect(c.figures == ["must-haves 1 of 2", "about 25m left", "2.31M tokens"])
    }

    @Test func observedRunsCountAgents() {
        let nodes = (0..<7).map { node("~a\($0)", .done, declared: false) } + [node("~r1", .running, declared: false), node("~f", .failed, declared: false)]
        let c = presenter.card(run(declared: false, nodes: nodes))
        #expect(!c.declared && c.bar == nil && c.estimate == nil)
        #expect(c.headline == "8 of 9 agents finished") // a failed agent has finished too
        // No ETA: nobody knows how many more agents will come.
        #expect(c.figures == ["1 running", "1 failed", "2.31M tokens"])
        let compacted = presenter.card(run(declared: false, nodes: [node("~r1", .running, declared: false)], earlier: 900))
        #expect(compacted.headline == "900 of 901 agents finished")
        #expect(presenter.card(run(declared: false)).headline == "No agents yet")
        #expect(presenter.card(run(declared: false, nodes: [node("~x", .running, declared: false)])).headline == "0 of 1 agent finished")
    }
}

@Suite struct RunStateWordingTests {
    @Test func everyState() {
        func words(_ r: TaskRun) -> String { presenter.stateText(r) }
        #expect(words(run()) == "Running")
        #expect(words(run(stale: true, updated: -20)) == "Quiet for 20m")
        #expect(words(run(state: .waiting, wait: .input)) == "Needs your input")
        #expect(words(run(state: .waiting, wait: .limit, warning: "Claude 5-hour limit reached, back today 10:48 AM.")) == "Waiting on the 5-hour limit")
        #expect(words(run(state: .waiting, wait: .limit, warning: "Codex weekly limit reached.")) == "Waiting on the weekly limit")
        #expect(words(run(state: .waiting, wait: .dependency)) == "Waiting on another task")
        #expect(words(run(state: .stopped)) == "Your turn")
        var left = run(state: .stopped)
        left.left = true
        #expect(words(left) == "Left at 57%")
        left.mustHaves = TaskMustHaves(done: 2, total: 2)
        #expect(words(left) == "Left at 57% · must-haves done")
        #expect(words(run(state: .done)) == "Done")
        #expect(words(run(state: .partial)) == "Finished with failures")
        #expect(words(run(state: .failed)) == "Failed")
        #expect(presenter.card(run(state: .waiting, wait: .input)).tone == .alert)
        #expect(presenter.card(run(state: .done)).live == false)
    }
}

@Suite struct RunRowTests {
    @Test func pressingRowsFirstFinishedFolded() {
        let r = run(nodes: [
            node("done1", .done), node("plan", .planned), node("run", .running, note: "halfway"),
            node("stale", .running, stale: true), node("fail", .failed, failure: "tests broke"),
            node("ask", .waiting, wait: .input, waitNote: "Which branch?"), node("done2", .done),
        ])
        let rows = presenter.rows(r, expanded: false).rows
        #expect(rows.map(\.id) == ["ask", "fail", "stale", "run", "plan", "~finished"])
        #expect(rows[0].detail == "Which branch?" && rows[0].detailTone == .alert && rows[0].glyph == .needsInput)
        #expect(rows[1].detail == "tests broke" && rows[1].glyph == .failed)
        #expect(rows[2].detail == "Quiet for 20m" && rows[2].glyph == .stale)
        #expect(rows[3].detail == "halfway")
        #expect(rows.last?.title == "2 finished" && rows.last?.kind == .finished(count: 2, expanded: false))
        // Expanded: the finished rows come back, last, and the summary hides them again.
        let open = presenter.rows(r, expanded: true).rows
        #expect(open.map(\.id) == ["ask", "fail", "stale", "run", "plan", "done1", "done2", "~finished"])
        #expect(open.last?.title == "Hide 2 finished")
    }

    @Test func threeLevelsThenRolledUp() {
        let r = run(nodes: [
            node("a", .running, leaf: false),
            node("a/b", .running, parent: "a", depth: 1, leaf: false),
            node("a/b/c", .running, parent: "a/b", depth: 2, leaf: false),
            node("a/b/c/d", .done, parent: "a/b/c", depth: 3),
            node("a/b/c/e", .waiting, parent: "a/b/c", depth: 3, title: "Pick a name", wait: .input, waitNote: "Two options"),
            node("a/b/c/e/f", .planned, parent: "a/b/c/e", depth: 4),
        ])
        let rows = presenter.rows(r, expanded: false).rows
        #expect(rows.map(\.id) == ["a", "a/b", "a/b/c"])
        #expect(rows.map(\.depth) == [0, 1, 2])
        // Its three tasks beneath, one finished; the one that needs you speaks for the row.
        #expect(rows[2].steps == "1/3")
        #expect(rows[2].detail == "Pick a name: Two options" && rows[2].detailTone == .alert)
    }

    @Test func aParentWithAFailureBeneathStaysOpen() {
        let r = run(state: .done, nodes: [
            node("p", .done, leaf: false), node("p/ok", .done, parent: "p", depth: 1),
            node("p/bench", .failed, parent: "p", depth: 1, importance: .optional, failure: "host down"),
        ])
        let rows = presenter.rows(r, expanded: false).rows
        #expect(rows.map(\.id) == ["p", "p/bench", "~finished"])
        // A failed optional task is quiet: amber is only for time and limits.
        #expect(rows[1].marker == "optional" && rows[1].detailTone == .quiet)
    }

    @Test func unconfirmedOnlyWhereAPlanExpectsAReport() {
        let declared = presenter.rows(run(nodes: [node("a", .running), node("b", .done, confirmed: false)]), expanded: true).rows
        #expect(declared.first { $0.id == "b" }?.detail == "unconfirmed")
        let observed = presenter.rows(run(declared: false, nodes: [node("~a", .running, declared: false), node("~b", .done, declared: false, confirmed: false)]),
                                      expanded: true).rows
        #expect(observed.first { $0.id == "~b" }?.detail == nil)
    }

    @Test func aThousandNodesStayCheapAndCapped() {
        var nodes = [node("~c", .running, declared: false, leaf: false)]
        for i in 0..<1003 {
            let state: TaskState = i < 929 ? .done : i < 953 ? .failed : .running
            nodes.append(node("~c/~a\(i)", state, parent: "~c", depth: 1, declared: false, failure: state == .failed ? "exit 1" : nil))
        }
        let r = run(declared: false, nodes: nodes)
        let clock = ContinuousClock()
        var card: RunCardModel?
        // The quickest of a few passes, with room to spare: on a busy CI machine one pass can wait
        // on a free core for several times what the card costs (about 10 ms in a debug build).
        let took = (0..<5).map { _ in clock.measure { card = presenter.card(r) } }.min()!
        #expect(took < .milliseconds(250))
        let rows = card!.rows
        #expect(rows.count == RunsPresenter.rowCap + 2)
        #expect(rows[0].id == "~c" && rows[1].glyph == .failed)
        // 1 coordinator + 24 failed + 50 running shown or counted; the 929 done fold into one row.
        #expect(rows[RunsPresenter.rowCap].kind == .more(75 - RunsPresenter.rowCap))
        #expect(rows.last?.kind == .finished(count: 929, expanded: false))
        #expect(card!.headline == "953 of 1004 agents finished")
    }

    @Test func compactedAgentsGetARow() {
        let rows = presenter.rows(run(declared: false, nodes: [node("~a", .running, declared: false)], earlier: 912), expanded: false).rows
        #expect(rows.last?.title == "+ 912 finished earlier" && rows.last?.kind == .earlier(912))
    }
}

@Suite struct RunPageTests {
    @Test func liveThenTheLastDaysFinished() {
        let runs = [run("live"), run("stopped", state: .stopped), run("fresh", state: .done, updated: -30),
                    run("old", state: .done, updated: -25 * 60), run("stuck", updated: -25 * 60)]
        let page = presenter.page(runs.sortedForDisplay())
        // Who moves next first: your turn before the agents' work.
        #expect(page.live.map(\.id) == ["stopped", "live"] && page.leadID == "stopped")
        #expect(page.recent.map(\.id) == ["fresh"])
        #expect(!page.isEmpty && presenter.page([]).isEmpty)
        let many = (0..<6).map { run("d\($0)", state: .done, updated: -Double($0 + 1)) }
        let capped = presenter.page(many)
        #expect(capped.recent.map(\.id) == ["d0", "d1", "d2", "d3"] && capped.moreRecent == 2)
    }

    @Test func expandingIsPerRun() {
        let r = run("x", nodes: [node("a", .running), node("b", .done)])
        let closed = presenter.page([r]).live[0]
        let open = presenter.page([r], expanded: ["x"]).live[0]
        #expect(closed.expandable && !closed.expanded && open.expanded)
        #expect(closed.rows.map(\.id) == ["a", "~finished"] && open.rows.map(\.id) == ["a", "b", "~finished"])
        #expect(open.rows.last?.toggles == true)
        // Nothing finished: nothing to expand.
        #expect(!presenter.page([run("y", nodes: [node("a", .running)])], expanded: ["y"]).live[0].expandable)
    }

    @Test func menuBarFollowsTheMostPressingLiveRun() {
        let observed = run("o", declared: false, nodes: (0..<7).map { node("~d\($0)", .done, declared: false) } + [node("~r", .running, declared: false), node("~s", .running, declared: false)])
        let m = presenter.menuBar([observed])
        #expect(m?.text == "7/9" && m?.needsInput == false)
        let ask = run("i", state: .waiting, wait: .input)
        let both = presenter.menuBar([ask, run("p")].sortedForDisplay())
        #expect(both?.text == "57%" && both?.needsInput == true && both?.liveCount == 2 && both?.needsInputCount == 1)
        #expect(presenter.menuBar([run("d", state: .done), run("s", state: .stopped)]) == nil)
        #expect(presenter.menuBar([]) == nil)
    }
}
