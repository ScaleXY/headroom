import AppKit
import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

/// Another Mac's runs on this Mac's Runs tab: listed and opened like its own, with nothing drawn
/// that would act on a session this Mac doesn't have.
@MainActor @Suite struct RemoteRunsTests {
    let now = Demo.now

    /// The demo runs as another Mac would have synced them: with task names or only structure,
    /// and `lastSeen` set when that Mac has gone quiet.
    func digests(names: Bool = true, lastSeen: Date? = nil) -> [RunDigest] {
        let presenter = RunsPresenter(now: now)
        return [Demo.inputRun(now: now), Demo.declaredRun(now: now), Demo.observedRun(now: now), Demo.finishedRun(now: now), Demo.failedRun(now: now)].map { r in
            let picked = presenter.digestRows(r, cap: 30)
            return RunDigest(id: "studio:" + r.id, mac: "Mac Studio", harness: r.harness, state: r.state, waitReason: r.waitReason, stale: r.stale,
                             progress: r.progress, mustHaves: r.mustHaves, etaSeconds: r.etaSeconds, tokens: r.tokens, warning: r.warning,
                             hasDeclaredTasks: r.hasDeclaredTasks, startedAt: r.startedAt, updatedAt: r.updatedAt, counts: RunCounts.of(r),
                             title: names ? r.bestTitle : nil, rows: names ? picked.rows : nil, moreRows: names ? picked.more : 0,
                             finishedRows: names ? picked.finished : 0, finishedEarlier: r.finishedEarlier ?? 0,
                             lastSeen: r.state.isTerminal ? nil : lastSeen)
        }
    }

    func isRemote(_ action: HitRegion.Action) -> Bool {
        switch action {
        case .toggleRun(let id), .runMenu(let id), .runButton(let id, _), .toggleRow(let id, _): id.hasPrefix("studio:")
        default: false
        }
    }

    func regions(_ draw: @escaping (CGContext?, RenderOutput?) -> CGFloat) -> (measured: CGFloat, drawn: CGFloat, regions: [HitRegion]) {
        let out = RenderOutput()
        let measured = draw(nil, nil)
        var drawn: CGFloat = 0
        _ = renderImage(size: CGSize(width: 400, height: 2400), scale: 1) { ctx in drawn = draw(ctx, out) }
        return (measured, drawn, out.regions)
    }

    @Test func theListOpensEveryRunAndOffersNoActionOnAnotherMacs() {
        let local = [Demo.inputRun(now: now), Demo.finishedRun(now: now)]
        let page = RunsPresenter(now: now).page(local, remote: digests(), allRecent: true)
        let remote = Set((page.live + page.recent).map(\.id).filter { $0.hasPrefix("studio:") })
        #expect(remote.count == 5)
        for style in RunsListStyle.allCases {
            let l = regions { RunListRenderer.drawPage(page, style: style, showFinished: true, origin: .zero, width: 360, theme: .dark, ctx: $0, out: $1) }
            #expect(l.measured == l.drawn, "\(style)")
            let opens = Set(l.regions.compactMap { if case .openRun(let id) = $0.action { id } else { nil } })
            #expect(opens.isSuperset(of: remote), "\(style)")
            #expect(!l.regions.contains { isRemote($0.action) }, "\(style)")
            // This Mac's own run that needs you keeps its answer button where the style has one.
            if style == .fill { #expect(l.regions.contains { $0.action == .runButton(local[0].id, .openSession) }) }
        }
    }

    @Test func anotherMacsRunPageDrawsWithNothingToClick() {
        let synced = digests() + digests(names: false).map { var d = $0; d.id += ":bare"; return d }
            + digests(lastSeen: now.addingTimeInterval(-7200)).map { var d = $0; d.id += ":quiet"; return d }
        let page = RunsPresenter(now: now).page([], remote: synced, expanded: Set(synced.map(\.id)), allRecent: true)
        #expect(page.live.count + page.recent.count == synced.count)
        for card in page.live + page.recent {
            #expect(card.actions == .none)
            for style in RunPageStyle.allCases {
                for theme in [Theme.dark, .light] {
                    let p = regions { RunPageRenderer.draw(card, style: style, origin: .zero, width: 360, theme: theme, ctx: $0, out: $1) }
                    #expect(p.measured == p.drawn, "\(card.id) \(style)")
                    #expect(p.measured > 60, "\(card.id) \(style)")
                    #expect(!p.regions.contains { $0.action != .none }, "\(card.id) \(style)")
                }
            }
        }
    }

    @Test func showingOtherMacsRunsIsOnUntilTurnedOff() {
        let suite = "com.scalexy.headroom.tests.remote-runs"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.showOtherMacsRuns)
        settings.showOtherMacsRuns = false
        #expect(defaults.object(forKey: "sync.otherMacsRuns") as? Bool == false)
        #expect(!AppSettings(defaults: defaults).showOtherMacsRuns)
    }
}
