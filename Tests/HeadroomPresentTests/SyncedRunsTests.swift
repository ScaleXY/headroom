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

/// A run as the phone receives it: what `RunSummaryBuilder` keeps, names or not.
@MainActor private func digest(_ r: TaskRun, names: Bool, mac: String = "MacBook Pro", lastSeen: Date? = nil) -> RunDigest {
    let picked = presenter.digestRows(r, cap: 30)
    return RunDigest(id: "mac:" + r.id, mac: mac, harness: r.harness, state: r.state, waitReason: r.waitReason, stale: r.stale,
                     progress: r.progress, mustHaves: r.mustHaves, etaSeconds: r.etaSeconds, tokens: r.tokens, warning: r.warning,
                     hasDeclaredTasks: r.hasDeclaredTasks, startedAt: r.startedAt, updatedAt: r.updatedAt, counts: RunCounts.of(r),
                     title: names ? r.agentTitle : nil, rows: names ? picked.rows : nil, moreRows: names ? picked.more : 0,
                     finishedRows: names ? picked.finished : 0, finishedEarlier: r.finishedEarlier ?? 0, lastSeen: lastSeen)
}

@MainActor @Suite struct SyncedRunsTests {
    static func runs() -> [TaskRun] { [Demo.declaredRun(now: now), Demo.observedRun(now: now), Demo.inputRun(now: now), Demo.limitRun(now: now),
                       Demo.finishedRun(now: now), Demo.failedRun(now: now), Demo.largeRun(now: now)] }

    @Test(arguments: 0..<7)
    func theCardSaysWhatTheMacSays(_ i: Int) {
        let r = Self.runs()[i]
        let mac = presenter.card(r)
        for names in [true, false] {
            let phone = presenter.card(digest(r, names: names))
            #expect(phone.stateText == mac.stateText)
            #expect(phone.headline == mac.headline)
            #expect(phone.estimate == mac.estimate)
            #expect(phone.figures == mac.figures)
            #expect(phone.warning == mac.warning)
            #expect(phone.bar == mac.bar)
            #expect(phone.glyph == mac.glyph && phone.tone == mac.tone)
            #expect(phone.needsInput == mac.needsInput && phone.live == mac.live && phone.provider == mac.provider)
        }
    }

    @Test(arguments: 0..<7)
    func withNamesTheRowsAreTheMacsWithoutTheirNotes(_ i: Int) {
        let r = Self.runs()[i]
        let mac = presenter.card(r).rows
        let phone = presenter.card(digest(r, names: true)).rows
        #expect(phone.map(\.title) == mac.map(\.title))
        #expect(phone.map(\.glyph) == mac.map(\.glyph))
        #expect(phone.map(\.depth) == mac.map(\.depth))
        #expect(phone.map(\.steps) == mac.map(\.steps))
        #expect(phone.map(\.marker) == mac.map(\.marker))
        let notes = r.nodes.flatMap { [$0.note, $0.waitNote, $0.failure, $0.evidence].compactMap { $0 } }
        for detail in phone.compactMap(\.detail) { #expect(!notes.contains(detail)) }
    }

    @Test func withNamesTheTitleIsTheAgentsAndTheSubtitleNamesTheMac() {
        let c = presenter.card(digest(Demo.declaredRun(now: now), names: true))
        #expect(c.title == "Move checkout to the new payments API")
        #expect(c.subtitle == "MacBook Pro · Claude Code · updated 1m ago")
        // No title of its own: the Mac, never the project.
        let observed = presenter.card(digest(Demo.observedRun(now: now), names: true))
        #expect(observed.title == "Run on MacBook Pro")
        #expect(!observed.subtitle.contains("design-system"))
    }

    @Test func withoutNamesTheTitleIsTheMacAndTheRowsOneLineOfCounts() {
        let c = presenter.card(digest(Demo.declaredRun(now: now), names: false))
        #expect(c.title == "Run on MacBook Pro")
        #expect(c.subtitle == "Claude Code · updated 1m ago")
        #expect(c.rows.count == 1)
        #expect(c.rows[0].kind == .counts)
        #expect(c.rows[0].title == "3 running · 5 done · 2 planned")
        let input = presenter.card(digest(Demo.inputRun(now: now), names: false))
        #expect(input.rows.map(\.title) == ["1 needs input · 1 done · 1 planned"])
        #expect(input.rows[0].glyph == .needsInput)
    }

    @Test func countsReadInTheBriefsOrder() {
        #expect(RunCounts(running: 3, needsInput: 1, done: 12).line == "3 running · 1 needs input · 12 done")
        #expect(RunCounts(running: 1, needsInput: 1, waiting: 2, failed: 1, done: 4, planned: 3).line
            == "1 running · 1 needs input · 2 waiting · 1 failed · 4 done · 3 planned")
    }

    @Test func observedCountsIncludeCompactedAgents() {
        let r = Demo.largeRun(now: now)
        let counts = RunCounts.of(r)
        let mac = presenter.agentCounts(r)
        #expect(counts.finished == mac.finished && counts.total == mac.total)
    }

    @Test func runsWithTheSameTitleSayWhenTheyStarted() {
        let a = digest(Demo.declaredRun(now: now), names: false), b = digest(Demo.inputRun(now: now), names: false)
        let page = presenter.page([b, a])
        #expect(page.live.allSatisfy { $0.title.hasPrefix("Run on MacBook Pro · ") })
    }

    @Test func aRunOnAQuietMacReadsLastSeen() {
        let d = digest(Demo.inputRun(now: now), names: true, lastSeen: now.addingTimeInterval(-2 * 3600))
        let c = presenter.card(d)
        #expect(c.stateText == "Last seen 2h ago")
        #expect(!c.needsInput)
        #expect(c.glyph == .stopped && c.tone == .quiet)
        #expect(!d.isLive)
    }

    @Test func alertsUseTheSameTitle() {
        let named = digest(Demo.inputRun(now: now), names: true)
        #expect(presenter.needsInputAlert(named) == RunAlertCopy(title: "Database upgrade needs your input",
                                                                  body: "An agent on MacBook Pro is waiting for your answer."))
        let unnamed = digest(Demo.failedRun(now: now), names: false)
        #expect(presenter.finishedAlert(unnamed).title == "Run on MacBook Pro failed")
        #expect(presenter.finishedAlert(unnamed).body == "50% done · must-haves 0 of 1 · 101K tokens")
    }
}
