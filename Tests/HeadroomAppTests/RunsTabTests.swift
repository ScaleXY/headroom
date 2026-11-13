import AppKit
import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

@MainActor @Suite struct RunsTabTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func run(_ id: String, finished: Bool) -> TaskRun {
        var nodes = [TaskNode(id: "a", title: "Still going", state: .running, startedAt: now)]
        if finished { nodes.append(TaskNode(id: "b", title: "Done already", state: .done, startedAt: now, endedAt: now)) }
        return TaskRun(id: id, title: "Run \(id)", startedAt: now, updatedAt: now, state: .running, hasDeclaredTasks: true, nodes: nodes)
    }

    /// Draws the page offscreen and returns the regions it recorded.
    func regions(_ page: RunsPageModel) -> [HitRegion] {
        let out = RenderOutput()
        _ = renderImage(size: CGSize(width: 400, height: 600), scale: 1) { ctx in
            RunCardRenderer.drawPage(page, origin: CGPoint(x: 12, y: 0), width: 360, theme: .dark, ctx: ctx, out: out)
        }
        return out.regions
    }

    @Test func headerAndSummaryRowToggleTheRun() {
        let presenter = RunsPresenter(now: now)
        var expanded: Set<String> = []
        var page = presenter.page([run("x", finished: true)], expanded: expanded)
        let toggles = regions(page).filter { $0.action == .toggleRun("x") }
        // The header and the "1 finished" row.
        #expect(toggles.count == 2 && toggles[0].rect.minY < toggles[1].rect.minY)
        #expect(page.live[0].rows.map(\.title) == ["Still going", "1 finished"])

        // A click on the summary row, as `CardsView` handles it.
        let click = CGPoint(x: toggles[1].rect.midX, y: toggles[1].rect.midY)
        if case .toggleRun(let id) = regions(page).last(where: { $0.rect.contains(click) && $0.action != .none })?.action {
            if expanded.remove(id) == nil { expanded.insert(id) }
        }
        page = presenter.page([run("x", finished: true)], expanded: expanded)
        #expect(page.live[0].expanded && page.live[0].rows.map(\.title) == ["Still going", "Done already", "Hide 1 finished"])
        #expect(regions(page).filter { $0.action == .toggleRun("x") }.count == 2)
    }

    @Test func nothingToToggleWithoutFinishedRows() {
        let page = RunsPresenter(now: now).page([run("y", finished: false)])
        #expect(!regions(page).contains { if case .toggleRun = $0.action { true } else { false } })
    }

    @Test func cardsOfferTheirMenuAndQuestionButtons() {
        let page = RunsPresenter(now: Demo.now).page([Demo.inputRun(now: Demo.now)])
        let actions = regions(page).map(\.action)
        let id = Demo.inputRun(now: Demo.now).id
        #expect(actions.contains(.runMenu(id)))
        #expect(actions.contains(.runButton(id, .openSession)) && actions.contains(.runButton(id, .copyResume)))
        // The menu wins over the header's toggle where they overlap.
        let menu = regions(page).first { $0.action == .runMenu(id) }!
        let hit = regions(page).last { $0.rect.contains(CGPoint(x: menu.rect.midX, y: menu.rect.midY)) && $0.action != .none }
        #expect(hit?.action == .runMenu(id))
    }

    @Test func rowsWithMoreToSayOpenOnClick() {
        let r = Demo.declaredRun(now: Demo.now)
        let presenter = RunsPresenter(now: Demo.now)
        let closed = regions(presenter.page([r], expanded: [r.id]))
        #expect(closed.contains { $0.action == .toggleRow(r.id, "schema") })
        // Opened, the row is taller and still closes on click.
        let opened = regions(presenter.page([r], expanded: [r.id], opened: [RunsPresenter.rowKey(run: r.id, row: "schema")]))
        let before = closed.first { $0.action == .toggleRow(r.id, "schema") }!.rect.height
        let after = opened.first { $0.action == .toggleRow(r.id, "schema") }!.rect.height
        #expect(after > before)
    }

    @Test func emptyTabConnectsAgentsAndFinishedListOpens() {
        #expect(regions(RunsPageModel()).contains { $0.action == .connectAgents })
        let many = (0..<6).map { i in
            TaskRun(id: "d\(i)", title: "Done \(i)", startedAt: now, updatedAt: now.addingTimeInterval(-Double(i + 1) * 60), state: .done, hasDeclaredTasks: true)
        }
        #expect(regions(RunsPresenter(now: now).page(many)).contains { $0.action == .moreRecent })
        #expect(regions(RunsPresenter(now: now).page(many, allRecent: true)).contains { $0.action == .moreRecent })
    }

    @Test func everyDemoScenarioMeasuresAsItDraws() {
        for s in Demo.runScenarios(now: Demo.now) {
            let page = RunsPresenter(now: Demo.now).page(s.runs, expanded: s.expanded, opened: s.opened, allRecent: s.allRecent)
            for theme in [Theme.dark, .light] {
                let measured = RunCardRenderer.drawPage(page, origin: .zero, width: 360, theme: theme, ctx: nil)
                var drawn: CGFloat = 0
                _ = renderImage(size: CGSize(width: 400, height: 200), scale: 1) { ctx in
                    drawn = RunCardRenderer.drawPage(page, origin: .zero, width: 360, theme: theme, ctx: ctx)
                }
                #expect(measured == drawn, "\(s.name)")
            }
        }
    }

    @Test func measuringMatchesDrawing() {
        let page = RunsPresenter(now: now).page([run("x", finished: true), run("y", finished: false)])
        let measured = RunCardRenderer.drawPage(page, origin: .zero, width: 360, theme: .light, ctx: nil)
        var drawn: CGFloat = 0
        _ = renderImage(size: CGSize(width: 400, height: 600), scale: 1) { ctx in
            drawn = RunCardRenderer.drawPage(page, origin: .zero, width: 360, theme: .light, ctx: ctx)
        }
        #expect(measured == drawn && measured > 0)
    }
}

/// The compact view: a line per run, each opening its card in place; heights measured as drawn.
@MainActor @Suite struct RunsCompactTests {
    let now = Demo.now

    func regions(_ page: RunsPageModel, open: Set<String> = []) -> (height: CGFloat, drawn: CGFloat, regions: [HitRegion]) {
        let out = RenderOutput()
        let measured = RunCompactRenderer.drawPage(page, open: open, origin: .zero, width: 360, theme: .dark, ctx: nil)
        var drawn: CGFloat = 0
        _ = renderImage(size: CGSize(width: 400, height: 1600), scale: 1) { ctx in
            drawn = RunCompactRenderer.drawPage(page, open: open, origin: .zero, width: 360, theme: .dark, ctx: ctx, out: out)
        }
        return (measured, drawn, out.regions)
    }

    @Test func everyRunIsOneLineThatOpensItsCard() throws {
        let page = RunsPresenter(now: now).page(Demo.runScenarios(now: now).first { $0.name == "mixed" }!.runs)
        let lines = regions(page)
        #expect(lines.height == lines.drawn)
        let opens = lines.regions.filter { if case .openCompact = $0.action { true } else { false } }
        #expect(opens.count == page.live.count + page.recent.count)
        #expect(opens.allSatisfy { $0.rect.height == RunCompactRenderer.rowHeight })
        // Far shorter than the cards.
        #expect(lines.height < RunCardRenderer.drawPage(page, origin: .zero, width: 360, theme: .dark, ctx: nil) / 2)

        // Opening one puts its card in the line's place, and its header closes it again.
        let id = try #require(page.live.dropFirst().first?.id)
        let opened = regions(page, open: [id])
        #expect(opened.height == opened.drawn && opened.height > lines.height)
        #expect(opened.regions.contains { $0.action == .openCompact(id) && $0.rect.height == 44 })
    }

    @Test func theTimeColumnSaysWhatHoldsARunUp() {
        let page = RunsPresenter(now: now).page(Demo.runScenarios(now: now).first { $0.name == "mixed-all" }!.runs)
        let flags = page.live.map(\.compactFlag)
        #expect(flags.contains("asks"))
        #expect(page.live.filter { $0.glyph == .running }.allSatisfy { $0.compactFlag == nil })
        #expect(page.recent.allSatisfy { $0.compactFlag == nil })
    }
}
