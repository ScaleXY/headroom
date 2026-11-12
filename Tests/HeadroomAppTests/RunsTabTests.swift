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
