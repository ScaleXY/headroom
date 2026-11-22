import Foundation
import Testing
import HeadroomKit
import HeadroomPresent
@testable import HeadroomSync

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// The JSON text inside a stored payload, as anyone holding the record would read it.
private func jsonText(_ value: some Encodable) throws -> String {
    let data = try PayloadCodec.encode(value)
    let json = try (Data(data.dropFirst()) as NSData).decompressed(using: .lzfse) as Data
    return String(decoding: json, as: UTF8.self)
}

private func device(_ runs: [RunSummaryPayload]?, name: String = "MacBook Pro", state: DevicePowerState = .awake) -> DevicePayload {
    DevicePayload(name: name, model: nil, appVersion: "0.5.0", enabledProviders: [.claude], currentAccounts: [:], sessionWarnAt: 0.75,
                  planPriceOverrides: [:], outages: [:], state: state, syncSince: nil, runs: runs)
}

private func envelope(_ id: String, _ payload: DevicePayload, seen: Date = now) -> DeviceEnvelope {
    DeviceEnvelope(deviceID: id, updatedAt: seen, lastSeenAt: seen, payload: payload)
}

/// Every fixture run, with something private in every field that must never sync: notes, wait
/// notes, failure reasons and evidence on the rows, and a project on the run.
@MainActor private func privateRuns() -> [TaskRun] {
    [Demo.inputRun(now: now), Demo.declaredRun(now: now), Demo.observedRun(now: now), Demo.limitRun(now: now), Demo.finishedRun(now: now),
     Demo.failedRun(now: now)].map { r in
        var r = r
        r.nodes = r.nodes.map { n in
            var n = n
            n.evidence = "evidence-\(n.id)"
            n.note = n.note ?? "note-\(n.id)"
            return n
        }
        return r
    }
}

/// Words that may appear nowhere in the payload, whatever the setting.
private func secrets(_ runs: [TaskRun]) -> [String] {
    runs.flatMap { r in
        [r.id, r.project].compactMap { $0 } + r.nodes.flatMap { [$0.note, $0.waitNote, $0.failure, $0.evidence].compactMap { $0 } }
    }
}

/// The payload format before runs synced, decoded strictly: what an older reader expects.
private struct DevicePayloadBeforeRuns: Decodable {
    var v: Int
    var name: String
    var model: String?
    var appVersion: String
    var enabledProviders: [String]
    var currentAccounts: [String: String]
    var sessionWarnAt: Double
    var planPriceOverrides: [String: Double]
    var outages: [String: String]
    var state: String
    var syncSince: Date?
}

@MainActor @Suite struct RunPayloadTests {
    @Test func anOldDevicePayloadDecodesWithoutRuns() throws {
        let url = try #require(Bundle.module.url(forResource: "device", withExtension: "json", subdirectory: "Fixtures/v1"))
        let d = try JSONDecoder().decode(DevicePayload.self, from: Data(contentsOf: url))
        #expect(d.name == "Fixture MacBook Pro")
        #expect(d.runs == nil)
    }

    @Test func aMacWithNoRunsWritesTheSameBytesAsBefore() throws {
        let text = try jsonText(device(nil))
        #expect(!text.contains("runs"))
    }

    @Test func aNewPayloadRoundTripsWithAndWithoutNames() throws {
        for names in [false, true] {
            let p = device(RunSummaryBuilder.summaries(privateRuns(), includeNames: names, now: now))
            let back = try PayloadCodec.decode(DevicePayload.self, from: PayloadCodec.encode(p))
            #expect(back == p)
            #expect(back.runs?.count == 6)
        }
    }

    @Test func anOlderReaderSkipsTheRunsKey() throws {
        let p = device(RunSummaryBuilder.summaries(privateRuns(), includeNames: true, now: now))
        let json = try JSONEncoder().encode(p)
        let old = try JSONDecoder().decode(DevicePayloadBeforeRuns.self, from: json)
        #expect(old.name == "MacBook Pro")
        #expect(old.state == "awake")
    }

    @Test func aRunThatNoLongerParsesIsSkippedNotTheDevice() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(device(
            RunSummaryBuilder.summaries([Demo.declaredRun(now: now)], includeNames: false, now: now)))) as? [String: Any])
        var runs = try #require(obj["runs"] as? [Any])
        runs.append(["state": "running"]) // no id: unreadable
        obj["runs"] = runs
        let d = try JSONDecoder().decode(DevicePayload.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(d.runs?.count == 1)
    }

    // MARK: Privacy

    @Test func withoutNamesNoTitleProjectOrNoteLeavesTheMac() throws {
        let runs = privateRuns()
        let text = try jsonText(device(RunSummaryBuilder.summaries(runs, includeNames: false, now: now)))
        let words = secrets(runs) + runs.map(\.title) + runs.flatMap { $0.nodes.map(\.title) }
        for w in words { #expect(!text.contains(w), "\(w) synced") }
        #expect(!text.contains("\"title\""))
        #expect(!text.contains("\"rows\""))
        // Structure and state still go.
        #expect(text.contains("needsInput"))
        #expect(text.contains("Claude 5-hour limit reached"))
    }

    @Test func withNamesTitlesGoButProjectsAndNotesStillDont() throws {
        let runs = privateRuns()
        let text = try jsonText(device(RunSummaryBuilder.summaries(runs, includeNames: true, now: now)))
        for w in secrets(runs) { #expect(!text.contains(w), "\(w) synced") }
        #expect(text.contains("Move checkout to the new payments API"))
        #expect(text.contains("Switch the queries over"))
        // A run the agent didn't name takes the session's own title, never its project or repo.
        let run = Demo.observedRun(now: now)
        let observed = try #require(RunSummaryBuilder.summaries([run], includeNames: true, now: now)?.first)
        #expect(observed.title == "Audit the design tokens for contrast")
        #expect(observed.rows?.isEmpty == false)
        let observedText = try jsonText(device([observed]))
        for w in [run.project, run.repo, run.cwd].compactMap({ $0 }) { #expect(!observedText.contains(w), "\(w) synced") }
        // Untitled altogether: no title, and still not the project.
        var untitled = run
        untitled.sessionTitle = nil
        #expect(RunSummaryBuilder.summaries([untitled], includeNames: true, now: now)?.first?.title == nil)
    }

    @Test func runIDsAreHashedAndStable() {
        let a = RunSummaryBuilder.hashedID("3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60")
        #expect(a == RunSummaryBuilder.hashedID("3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60"))
        #expect(a != RunSummaryBuilder.hashedID("demo-declared"))
        #expect(a.count == 16)
        #expect(!a.contains("3f9b8c1e"))
    }

    // MARK: Caps

    @Test func atMostEightRunsLiveOnesFirst() throws {
        let live = (0..<6).map { i in TaskRun(id: "live\(i)", title: "Live \(i)", startedAt: now.addingTimeInterval(-3600),
                                              updatedAt: now.addingTimeInterval(-Double(i) * 60), state: .running, hasDeclaredTasks: true) }
        let done = (0..<6).map { i in TaskRun(id: "done\(i)", title: "Done \(i)", startedAt: now.addingTimeInterval(-7200),
                                              updatedAt: now.addingTimeInterval(-Double(i + 1) * 600), state: .done, hasDeclaredTasks: true) }
        let s = try #require(RunSummaryBuilder.summaries(done + live, includeNames: true, now: now))
        #expect(s.count == RunSummaryBuilder.maxRuns)
        #expect(s.prefix(6).allSatisfy { !$0.state.isTerminal })
        #expect(s.suffix(2).map(\.title) == ["Done 0", "Done 1"])
    }

    @Test func rowsCarryTheirTimesForThePhonesLanes() throws {
        let r = Demo.declaredRun(now: now)
        let s = try #require(RunSummaryBuilder.summaries([r], includeNames: true, now: now)?.first)
        let back = try PayloadCodec.decode(DevicePayload.self, from: PayloadCodec.encode(device([s])))
        let rows = try #require(back.runs?.first?.rows)
        #expect(rows.contains { $0.a != nil })
        // Finished rows say when they ended; open ones how far along they are.
        #expect(rows.allSatisfy { $0.state.isTerminal || $0.p != nil })
        // Without names no rows, and so no times, leave the Mac.
        #expect(RunSummaryBuilder.summaries([r], includeNames: false, now: now)?.first?.rows == nil)
    }

    @Test func atMostThirtyRowsAndTheRestCounted() throws {
        let nodes = (0..<50).map { i in TaskNode(id: "t\(i)", title: "Task \(i)", state: i < 45 ? .running : .done) }
        let r = TaskRun(id: "big", title: "Big plan", startedAt: now.addingTimeInterval(-3600), updatedAt: now, state: .running,
                        hasDeclaredTasks: true, nodes: nodes)
        let s = try #require(RunSummaryBuilder.summaries([r], includeNames: true, now: now)?.first)
        #expect(s.rows?.count == RunSummaryBuilder.maxRows)
        #expect(s.moreRows == 15)
        #expect(s.finishedRows == 5)
        #expect(s.counts == RunCounts(running: 45, done: 5))
    }

    @Test func runsFinishedADayAgoAreNotSent() {
        let old = TaskRun(id: "old", title: "Old", startedAt: now.addingTimeInterval(-100_000), updatedAt: now.addingTimeInterval(-90_000),
                          state: .done, hasDeclaredTasks: true)
        #expect(RunSummaryBuilder.summaries([old], includeNames: false, now: now) == nil)
    }
}

@MainActor @Suite struct RunMergeTests {
    @Test func runsFromTwoMacsMergeMostPressingFirstWithTheirMacNames() throws {
        let laptop = envelope("laptop", device(RunSummaryBuilder.summaries([Demo.declaredRun(now: now), Demo.finishedRun(now: now)], includeNames: true, now: now)))
        let studio = envelope("studio", device(RunSummaryBuilder.summaries([Demo.inputRun(now: now)], includeNames: false, now: now), name: "Mac Studio"))
        let runs = RunMerge.digests([laptop, studio], now: now)
        #expect(runs.map(\.mac) == ["Mac Studio", "MacBook Pro", "MacBook Pro"])
        #expect(runs[0].needsInput)
        #expect(runs[2].state == .done)
        #expect(Set(runs.map(\.id)).count == 3)
        // Through the whole reader too.
        var records = SyncRecords()
        records.devices = [laptop, studio]
        #expect(AccountReader(now: now).read(records).runs.map(\.id) == runs.map(\.id))
    }

    @Test func aSleepingOrSilentMacsLiveRunsReadAsLastSeen() throws {
        let runs = RunSummaryBuilder.summaries([Demo.inputRun(now: now), Demo.finishedRun(now: now)], includeNames: false, now: now)
        let seen = now.addingTimeInterval(-2 * 3600)
        for e in [envelope("a", device(runs, state: .sleeping), seen: seen), envelope("a", device(runs, state: .quitting), seen: seen),
                  envelope("a", device(runs), seen: now.addingTimeInterval(-45 * 60))] {
            let merged = RunMerge.digests([e], now: now)
            let live = try #require(merged.first { !$0.state.isTerminal })
            #expect(live.lastSeen == e.lastSeenAt)
            #expect(!live.isLive && !live.needsInput)
            // Finished runs are finished whoever reports them.
            #expect(merged.first { $0.state.isTerminal }?.lastSeen == nil)
        }
        let quiet = RunMerge.digests([envelope("a", device(runs, state: .sleeping), seen: seen)], now: now)
        #expect(RunsPresenter(now: now).stateText(quiet[0]) == "Mac last seen 2h ago")
        // Awake and heard from lately: live.
        #expect(RunMerge.digests([envelope("a", device(runs), seen: now.addingTimeInterval(-5 * 60))], now: now)[0].isLive)
    }

    @Test func runsFinishedMoreThanADayAgoDropOut() {
        let summaries = RunSummaryBuilder.summaries([Demo.finishedRun(now: now)], includeNames: false, now: now)
        let later = now.addingTimeInterval(25 * 3600)
        #expect(RunMerge.digests([envelope("a", device(summaries), seen: later)], now: later).isEmpty)
        #expect(RunMerge.digests([envelope("a", device(summaries))], now: now).count == 1)
    }
}

@MainActor @Suite struct RunPublishGateTests {
    let base = RunSummaryBuilder.summaries([Demo.declaredRun(now: now)], includeNames: false, now: now)!

    func with(_ change: (inout RunSummaryPayload) -> Void) -> [RunSummaryPayload] {
        var s = base
        change(&s[0])
        return s
    }

    @Test func aStateChangeGoesOutAtMostOnceAMinute() {
        var gate = RunPublishGate()
        #expect(gate.pass(base, now: now).runs == base)
        let waiting = with { $0.state = .waiting; $0.waitReason = .input }
        let held = gate.pass(waiting, now: now.addingTimeInterval(30))
        #expect(held.runs == base)
        #expect(held.retryAfter == 30)
        #expect(gate.pass(waiting, now: now.addingTimeInterval(60)).runs == waiting)
        // A new run or a finish is a state change too.
        let finished = with { $0.state = .done }
        #expect(gate.pass(finished, now: now.addingTimeInterval(125)).runs == finished)
        #expect(gate.pass(nil, now: now.addingTimeInterval(190)).runs == nil)
    }

    @Test func progressAloneWaitsFiveMinutes() {
        var gate = RunPublishGate()
        _ = gate.pass(base, now: now)
        let ticked = with { $0.progress.done = 0.5; $0.tokens += 10_000; $0.updatedAt = now.addingTimeInterval(90) }
        let held = gate.pass(ticked, now: now.addingTimeInterval(90))
        #expect(held.runs == base)
        #expect(held.retryAfter == 210)
        #expect(gate.pass(ticked, now: now.addingTimeInterval(299)).runs == base)
        #expect(gate.pass(ticked, now: now.addingTimeInterval(300)).runs == ticked)
        #expect(gate.pass(ticked, now: now.addingTimeInterval(301)).retryAfter == nil)
    }

    @Test func turningNamesOffAndSleepGoOutAtOnce() {
        var gate = RunPublishGate()
        let named = RunSummaryBuilder.summaries([Demo.declaredRun(now: now)], includeNames: true, now: now)!
        _ = gate.pass(named, now: now)
        #expect(gate.pass(base, now: now.addingTimeInterval(5)).runs == base)
        let ticked = with { $0.progress.done = 0.6 }
        #expect(gate.pass(ticked, now: now.addingTimeInterval(10), force: true).runs == ticked)
    }

    @Test func aSeededGateDoesntRepublishWhatsInICloud() {
        var gate = RunPublishGate()
        gate.seed(base, at: now)
        #expect(gate.pass(base, now: now.addingTimeInterval(1)) == (base, nil))
    }
}

@MainActor @Suite struct RunAlertLedgerTests {
    func digest(_ id: String, _ state: TaskRunState, wait: TaskWaitReason? = nil, updated: Date = now, lastSeen: Date? = nil) -> RunDigest {
        RunDigest(id: id, mac: "MacBook Pro", state: state, waitReason: wait, hasDeclaredTasks: true, startedAt: now.addingTimeInterval(-3600),
                  updatedAt: updated, lastSeen: lastSeen)
    }

    @Test func theFirstLookOnlyPrimes() {
        var ledger = RunAlertLedger()
        #expect(ledger.observe([digest("a", .waiting, wait: .input), digest("b", .done)], now: now, needsInput: true, finished: true).due.isEmpty)
        #expect(ledger.observe([digest("a", .waiting, wait: .input), digest("b", .done)], now: now, needsInput: true, finished: true).due.isEmpty)
    }

    @Test func needsInputAlertsOncePerEpisode() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([digest("a", .running)], now: now, needsInput: true, finished: false)
        let waiting = [digest("a", .waiting, wait: .input)]
        #expect(ledger.observe(waiting, now: now, needsInput: true, finished: false).due.map(\.kind) == [.needsInput])
        #expect(ledger.observe(waiting, now: now.addingTimeInterval(60), needsInput: true, finished: false).due.isEmpty)
        // Answered, then asked again: a new episode.
        _ = ledger.observe([digest("a", .running)], now: now.addingTimeInterval(120), needsInput: true, finished: false)
        #expect(ledger.observe(waiting, now: now.addingTimeInterval(180), needsInput: true, finished: false).due.count == 1)
    }

    @Test func aQuietMacAlertsOnlyOnceItsBack() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([], now: now, needsInput: true, finished: true)
        #expect(ledger.observe([digest("a", .waiting, wait: .input, lastSeen: now)], now: now, needsInput: true, finished: true).due.isEmpty)
        #expect(ledger.observe([digest("a", .waiting, wait: .input)], now: now, needsInput: true, finished: true).due.count == 1)
    }

    @Test func finishedAlertsOnceAndOnlyWhenFresh() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([digest("a", .running)], now: now, needsInput: true, finished: true)
        let done = [digest("a", .done), digest("old", .failed, updated: now.addingTimeInterval(-2 * 3600))]
        let due = ledger.observe(done, now: now, needsInput: true, finished: true).due
        #expect(due.map(\.run.id) == ["a"])
        #expect(due.map(\.kind) == [.finished])
        #expect(ledger.observe(done, now: now.addingTimeInterval(60), needsInput: true, finished: true).due.isEmpty)
    }

    @Test func aSwitchThatsOffStillUsesUpTheEpisode() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([], now: now, needsInput: true, finished: true)
        let runs = [digest("a", .waiting, wait: .input), digest("b", .done)]
        #expect(ledger.observe(runs, now: now, needsInput: false, finished: false).due.isEmpty)
        #expect(ledger.observe(runs, now: now.addingTimeInterval(60), needsInput: true, finished: true).due.isEmpty)
    }

    @Test func theLedgerSurvivesARelaunch() throws {
        var ledger = RunAlertLedger()
        _ = ledger.observe([digest("a", .waiting, wait: .input), digest("b", .done)], now: now, needsInput: true, finished: true)
        let back = try JSONDecoder().decode(RunAlertLedger.self, from: JSONEncoder().encode(ledger))
        #expect(back == ledger)
    }
}

@MainActor @Suite struct RunDemoTests {
    @Test @MainActor func demoModeShowsRunsFromBothMacs() {
        let runs = AccountReader(now: now).read(DemoRecords.make(now: now)).runs
        #expect(Set(runs.map(\.mac)) == ["MacBook Pro", "Mac Studio"])
        #expect(runs.first?.needsInput == true)
        // Both sample Macs share task names, so every run reads by what it's doing.
        #expect(runs.allSatisfy { $0.includesNames && $0.title != nil })
    }
}
