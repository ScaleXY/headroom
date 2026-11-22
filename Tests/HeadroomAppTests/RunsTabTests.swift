import AppKit
import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

/// The Runs tab: one list (a lead card, then two-line rows) whose every line opens the run's own page.
@MainActor @Suite struct RunsTabTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func run(_ id: String, finished: Bool) -> TaskRun {
        var nodes = [TaskNode(id: "a", title: "Still going", state: .running, startedAt: now)]
        if finished { nodes.append(TaskNode(id: "b", title: "Done already", state: .done, startedAt: now, endedAt: now)) }
        return TaskRun(id: id, title: "Run \(id)", startedAt: now, updatedAt: now, state: .running, hasDeclaredTasks: true, nodes: nodes)
    }

    func scenario(_ name: String) -> Demo.RunScenario { Demo.runScenarios(now: Demo.now).first { $0.name == name }! }

    /// Draws the list offscreen: its measured and drawn heights and the regions it recorded.
    func list(_ page: RunsPageModel, showFinished: Bool = false) -> (measured: CGFloat, drawn: CGFloat, regions: [HitRegion]) {
        let out = RenderOutput()
        let measured = RunListRenderer.drawPage(page, showFinished: showFinished, origin: .zero, width: 360, theme: .dark, ctx: nil)
        var drawn: CGFloat = 0
        _ = renderImage(size: CGSize(width: 400, height: 2400), scale: 1) { ctx in
            drawn = RunListRenderer.drawPage(page, showFinished: showFinished, origin: .zero, width: 360, theme: .dark, ctx: ctx, out: out)
        }
        return (measured, drawn, out.regions)
    }

    /// Draws a run's page offscreen.
    func runPage(_ card: RunCardModel, _ style: RunPageStyle, theme: Theme = .dark) -> (measured: CGFloat, drawn: CGFloat, regions: [HitRegion]) {
        let out = RenderOutput()
        let measured = RunPageRenderer.draw(card, style: style, origin: .zero, width: 360, theme: theme, ctx: nil)
        var drawn: CGFloat = 0
        _ = renderImage(size: CGSize(width: 400, height: 1600), scale: 1) { ctx in
            drawn = RunPageRenderer.draw(card, style: style, origin: .zero, width: 360, theme: theme, ctx: ctx, out: out)
        }
        return (measured, drawn, out.regions)
    }

    func opens(_ regions: [HitRegion]) -> Set<String> {
        Set(regions.compactMap { if case .openRun(let id) = $0.action { id } else { nil } })
    }

    @Test func everyLineAndTheLeadCardOpenTheirRun() {
        let page = RunsPresenter(now: Demo.now).page(scenario("mixed").runs)
        let all = Set((page.live + page.recent + page.days.flatMap(\.short)).map(\.id))
        let l = list(page, showFinished: true)
        #expect(opens(l.regions) == all)
        // Lines say they're clickable on hover.
        #expect(l.regions.filter { if case .openRun = $0.action { true } else { false } }.allSatisfy { $0.hover != nil })
    }

    @Test func shortSessionsFoldIntoOneLineThatOpens() {
        let page = RunsPresenter(now: Demo.now).page(scenario("settled").runs)
        let folded = list(page)
        #expect(folded.regions.contains { $0.action == .toggleFinished })
        let shortIDs = Set(page.days.flatMap(\.short).map(\.id))
        #expect(shortIDs.count == 3 && opens(folded.regions).isDisjoint(with: shortIDs))
        let open = list(page, showFinished: true)
        #expect(open.measured > folded.measured && opens(open.regions).isSuperset(of: shortIDs))
    }

    @Test func theLeadCardsButtonsWinOverTheCard() {
        for r in [Demo.inputRun(now: Demo.now), Demo.yourTurnRun(now: Demo.now)] {
            let l = list(RunsPresenter(now: Demo.now).page([r]))
            let button = l.regions.first { $0.action == .runButton(r.id, .openSession) }
            #expect(button != nil)
            if let b = button {
                #expect(l.regions.last { $0.rect.contains(CGPoint(x: b.rect.midX, y: b.rect.midY)) && $0.action != .none }?.action == .runButton(r.id, .openSession))
            }
        }
        // Your turn offers Close from the card.
        let turn = Demo.yourTurnRun(now: Demo.now)
        #expect(list(RunsPresenter(now: Demo.now).page([turn])).regions.contains { $0.action == .runButton(turn.id, .close) })
    }

    @Test func emptyTabConnectsAgentsAndMoreOpens() {
        #expect(list(RunsPageModel()).regions.contains { $0.action == .connectAgents })
        let many = (0..<6).map { i in
            TaskRun(id: "d\(i)", title: "Done \(i)", startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-Double(i + 1) * 60), state: .done,
                    hasDeclaredTasks: true, time: TaskTimeSplit(working: 1800))
        }
        #expect(list(RunsPresenter(now: now).page(many)).regions.contains { $0.action == .moreRecent })
    }

    @Test func aRunPageOffersItsMenuSessionAndQuestionButtons() {
        let r = Demo.inputRun(now: Demo.now)
        let card = RunsPresenter(now: Demo.now).page([r]).live[0]
        for style in RunPageStyle.allCases {
            let actions = runPage(card, style).regions
            #expect(actions.contains { $0.action == .runMenu(r.id) }, "\(style)")
            #expect(actions.contains { $0.action == .runButton(r.id, .openSession) } && actions.contains { $0.action == .runButton(r.id, .copyResume) }, "\(style)")
            // The offered answers are words, never buttons.
            #expect(actions.allSatisfy { $0.tooltip?.contains("Drop it") != true })
            let menu = actions.first { $0.action == .runMenu(r.id) }!
            #expect(actions.last { $0.rect.contains(CGPoint(x: menu.rect.midX, y: menu.rect.midY)) && $0.action != .none }?.action == .runMenu(r.id))
        }
    }

    @Test func doneTasksFoldBehindOneToggle() {
        let presenter = RunsPresenter(now: now)
        let card = presenter.page([run("x", finished: true)]).live[0]
        let toggles = runPage(card, .briefing).regions.filter { $0.action == .toggleRun("x") }
        #expect(toggles.count == 1 && toggles[0].hover != nil)
        let shown = presenter.page([run("x", finished: true)], expanded: ["x"]).live[0]
        #expect(runPage(shown, .briefing).measured > runPage(card, .briefing).measured)
        // Nothing finished, nothing to toggle.
        let none = presenter.page([run("y", finished: false)]).live[0]
        #expect(!runPage(none, .briefing).regions.contains { if case .toggleRun = $0.action { true } else { false } })
    }

    @Test func rowsWithMoreToSayOpenOnClick() {
        let r = Demo.declaredRun(now: Demo.now)
        let presenter = RunsPresenter(now: Demo.now)
        let closed = runPage(presenter.page([r], expanded: [r.id]).live[0], .briefing).regions
        #expect(closed.contains { $0.action == .toggleRow(r.id, "schema") })
        let opened = runPage(presenter.page([r], expanded: [r.id], opened: [RunsPresenter.rowKey(run: r.id, row: "schema")]).live[0], .briefing).regions
        let before = closed.first { $0.action == .toggleRow(r.id, "schema") }!.rect.height
        let after = opened.first { $0.action == .toggleRow(r.id, "schema") }!.rect.height
        #expect(after > before)
    }

    @Test func everyDemoScenarioMeasuresAsItDraws() {
        for s in Demo.runScenarios(now: Demo.now) {
            let page = RunsPresenter(now: Demo.now).page(s.runs, expanded: s.expanded, opened: s.opened, allRecent: s.allRecent)
            for show in [false, true] {
                let l = list(page, showFinished: show)
                #expect(l.measured == l.drawn && l.measured > 0, "\(s.name)")
            }
            for card in page.live + page.recent {
                for style in RunPageStyle.allCases {
                    for theme in [Theme.dark, .light] {
                        let p = runPage(card, style, theme: theme)
                        #expect(p.measured == p.drawn && p.measured > 0, "\(s.name) \(card.title) \(style)")
                    }
                }
            }
        }
    }
}

/// The compact word that stands in for the time when a run isn't simply running.
@MainActor @Suite struct RunsCompactTests {
    let now = Demo.now

    @Test func theFlagSaysWhatHoldsARunUp() {
        let page = RunsPresenter(now: now).page(Demo.runScenarios(now: now).first { $0.name == "mixed-all" }!.runs)
        let flags = page.live.map(\.compactFlag)
        #expect(flags.contains("asks") && flags.contains("your turn"))
        #expect(page.live.filter { $0.glyph == .running }.allSatisfy { $0.compactFlag == nil })
        #expect(page.recent.allSatisfy { $0.compactFlag == nil })
    }
}

/// The run page style is a setting; the old list style is gone and its stored value does nothing.
@MainActor @Suite struct RunsStyleSettingTests {
    @Test func thePageStylePersistsAndAnOldListStyleIsHarmless() {
        let defaults = UserDefaults(suiteName: "headroom-tests-\(UUID().uuidString)")!
        // What 0.8.2 may have stored: Fill rows.
        defaults.set(2, forKey: "runsListStyle")
        let s = AppSettings(defaults: defaults)
        #expect(s.runPageStyle == .briefing)
        var changes = 0
        s.onChange = { changes += 1 }
        s.runPageStyle = .lanes
        #expect(changes == 1 && s.runPageStyle == .lanes)
        #expect(defaults.integer(forKey: "runsListStyle") == 2)
    }
}
