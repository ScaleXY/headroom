import Foundation
import Testing
import HeadroomKit
import HeadroomPresent
@testable import HeadroomSync

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func device(_ runs: [RunSummaryPayload]?, activeAt: Date? = nil) -> DevicePayload {
    DevicePayload(name: "MacBook Pro", model: nil, appVersion: "0.5.0", enabledProviders: [.claude], currentAccounts: [:], sessionWarnAt: 0.75,
                  planPriceOverrides: [:], outages: [:], state: .awake, syncSince: nil, runs: runs, activeAt: activeAt)
}

private func jsonText(_ value: some Encodable) throws -> String {
    let data = try PayloadCodec.encode(value)
    let json = try (Data(data.dropFirst()) as NSData).decompressed(using: .lzfse) as Data
    return String(decoding: json, as: UTF8.self)
}

/// Every fixture with the second pass's fields filled in, and private words where they must not go.
@MainActor private func detailedRuns() -> [TaskRun] {
    [Demo.inputRun(now: now), Demo.declaredRun(now: now), Demo.observedRun(now: now), Demo.limitRun(now: now), Demo.finishedRun(now: now),
     Demo.failedRun(now: now)].map { r in
        var r = DemoRecords.detailed(r, now: now)
        r.host = "com.mitchellh.ghostty-private"
        r.cwd = "/Users/someone/private-project"
        return r
    }
}

/// A run summary as the first runs-syncing release wrote and read it, decoded strictly.
private struct FirstPassRun: Decodable {
    var id: String
    var state: String
    var progress: TaskProgress
    var counts: RunCounts
    var etaSeconds: Double?
    var updatedAt: Date
    var startedAt: Date
    var hasDeclaredTasks: Bool
}

private struct FirstPassDevice: Decodable {
    var name: String
    var runs: [FirstPassRun]?
}

@MainActor @Suite struct RunSecondPassPayloadTests {
    @Test func aSecondPassPayloadRoundTrips() throws {
        let runs = RunSummaryBuilder.summaries(detailedRuns(), includeNames: true, includeQuestion: true, now: now)
        let p = device(runs, activeAt: now.addingTimeInterval(-30))
        let back = try PayloadCodec.decode(DevicePayload.self, from: PayloadCodec.encode(p))
        #expect(back == p)
        let declared = try #require(back.runs?.first { $0.title == "Move checkout to the new payments API" })
        #expect(declared.segments?.count == 10)
        #expect(declared.finishLow == now.addingTimeInterval(20 * 60) && declared.finishHigh == now.addingTimeInterval(35 * 60))
        #expect(declared.limit?.share == 0.62)
        #expect(declared.working == Double(64 * 60))
        let finished = try #require(back.runs?.first { $0.title == "Speed up image uploads" })
        #expect(finished.receipt?.models == ["gpt-6-sol": 296_000])
        #expect(finished.receipt?.optionalFailed == 1)
        #expect(finished.segments != nil && finished.limit == nil && finished.finishAt == nil)
    }

    @Test func anOlderReaderReadsTheNewShape() throws {
        let runs = RunSummaryBuilder.summaries(detailedRuns(), includeNames: true, includeQuestion: true, now: now)
        let json = try JSONEncoder().encode(device(runs, activeAt: now))
        let old = try JSONDecoder().decode(FirstPassDevice.self, from: json)
        #expect(old.runs?.count == 6)
        #expect(old.runs?.first { $0.hasDeclaredTasks && $0.state == "running" }?.etaSeconds == Double(26 * 60))
    }

    @Test func anOlderPayloadReadsWithNothingNew() throws {
        // What the first release wrote for a run: none of the new keys.
        let obj: [String: Any] = ["name": "Old Mac", "runs": [["id": "abc", "state": "running", "updatedAt": 0, "startedAt": 0, "hasDeclaredTasks": true,
                                                               "progress": ["done": 0.4, "in_flight": 0.2, "estimate": 0.5], "etaSeconds": 600,
                                                               "counts": ["running": 1, "done": 2]]]]
        let d = try JSONDecoder().decode(DevicePayload.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(d.activeAt == nil)
        let r = try #require(d.runs?.first)
        #expect(r.segments == nil && r.finishAt == nil && r.receipt == nil && r.question == nil && r.limit == nil && r.working == nil)
        let digest = r.digest(deviceID: "old", mac: "Old Mac", lastSeen: nil)
        #expect(digest.segments.isEmpty && !digest.mirrored && !digest.abandoned)
        // The card still says time left, from the seconds it sent.
        #expect(RunsPresenter(now: Date(timeIntervalSince1970: 0)).card(digest).figures.contains("about 10m left"))
    }

    @Test func aRunWithNothingNewWritesTheSameKeysAsBefore() throws {
        var r = Demo.observedRun(now: now)
        r.time = .zero
        let text = try jsonText(device(RunSummaryBuilder.summaries([r], includeNames: false, now: now)))
        for key in ["segments", "finishLow", "finishHigh", "working", "mirrored", "abandoned", "limit", "receipt", "question", "activeAt"] {
            #expect(!text.contains("\"\(key)\""), "\(key) written")
        }
    }

    @Test func malformedNewFieldsAreSkippedNotTheRun() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(device(
            RunSummaryBuilder.summaries([DemoRecords.detailed(Demo.declaredRun(now: now), now: now)], includeNames: false, now: now)))) as? [String: Any])
        var runs = try #require(obj["runs"] as? [[String: Any]])
        runs[0]["segments"] = [["w": "wide"], ["w": 0.5, "f": 0.5, "s": "running"]]
        runs[0]["limit"] = ["provider": 7]
        runs[0]["finishAt"] = "soon"
        obj["runs"] = runs
        let d = try JSONDecoder().decode(DevicePayload.self, from: JSONSerialization.data(withJSONObject: obj))
        let r = try #require(d.runs?.first)
        #expect(r.segments?.count == 2)
        #expect(r.limit == nil && r.finishAt == nil)
    }

    // MARK: Building

    @Test func theTaskMapIsAtMost24BlocksThatSumToOne() throws {
        let nodes = (0..<60).map { i in TaskNode(id: "t\(i)", title: "Task \(i)", state: i < 20 ? .done : i < 25 ? .running : .planned,
                                                 importance: i == 1 ? .critical : .normal) }
        let r = TaskRun(id: "big", title: "Big plan", startedAt: now.addingTimeInterval(-3600), updatedAt: now, state: .running,
                        hasDeclaredTasks: true, nodes: nodes)
        let segments = try #require(RunSummaryBuilder.summaries([r], includeNames: false, now: now)?.first?.segments)
        #expect(segments.count <= RunSummaryBuilder.maxSegments)
        #expect(abs(segments.reduce(0) { $0 + $1.w } - 1) < 0.01)
        #expect(segments.first?.f == 1 && segments.last?.f == 0)
        #expect(segments.first?.i == .critical)
        // Effort sets the width when the fold gave no shares.
        let small = (try #require(RunSummaryBuilder.summaries([DemoRecords.detailed(Demo.declaredRun(now: now), now: now)], includeNames: false,
                                                               now: now)?.first?.segments))
        #expect(small.map(\.w).max() == 0.24)
        // Observed runs have no map: their headline is the agents.
        #expect(RunSummaryBuilder.summaries([Demo.observedRun(now: now)], includeNames: false, now: now)?.first?.segments == nil)
    }

    @Test func theFinishIsAClockTimeFromNow() throws {
        var r = DemoRecords.detailed(Demo.declaredRun(now: now), now: now)
        r.updatedAt = now.addingTimeInterval(-9 * 60)
        let s = try #require(RunSummaryBuilder.summaries([r], includeNames: false, now: now)?.first)
        // Not updatedAt + eta, which would read 9 minutes early.
        #expect(s.finishAt == now.addingTimeInterval(26 * 60))
    }

    @Test func theQuestionGoesOnlyWithNamesAndQuestionsBothOn() throws {
        let run = DemoRecords.detailed(Demo.inputRun(now: now), now: now)
        let wording = "May I drop the unused audit table"
        for (names, question, sent) in [(false, false, false), (false, true, false), (true, false, false), (true, true, true)] {
            let text = try jsonText(device(RunSummaryBuilder.summaries([run], includeNames: names, includeQuestion: question, now: now)))
            #expect(text.contains(wording) == sent, "names \(names) question \(question)")
        }
        let s = try #require(RunSummaryBuilder.summaries([run], includeNames: true, includeQuestion: true, now: now)?.first)
        #expect(s.question?.asker == "Switch the queries over")
        #expect(s.question?.options == ["Drop it", "Keep it for now", "Rename it to audit_old"])
        // Once answered, it's gone.
        var answered = run
        answered.state = .running; answered.waitReason = nil
        #expect(RunSummaryBuilder.summaries([answered], includeNames: true, includeQuestion: true, now: now)?.first?.question == nil)
    }

    @Test func hiddenRunsAndPrivateFieldsNeverSync() throws {
        var runs = detailedRuns()
        runs[1].hidden = true
        let text = try jsonText(device(RunSummaryBuilder.summaries(runs, includeNames: true, includeQuestion: true, now: now)))
        #expect(!text.contains("Move checkout to the new payments API"))
        #expect(!text.contains("ghostty") && !text.contains("private-project"))
        for r in runs { if let p = r.project { #expect(!text.contains(p)) } }
        #expect(RunSummaryBuilder.summaries([runs[1]], includeNames: true, now: now) == nil)
    }

    @Test func mirroredAndAbandonedTravel() throws {
        var r = Demo.stoppedRun(now: now)
        r.mirrored = true; r.abandoned = true
        let s = try #require(RunSummaryBuilder.summaries([r], includeNames: false, now: now)?.first)
        let d = s.digest(deviceID: "mac", mac: "MacBook Pro", lastSeen: nil)
        #expect(d.mirrored && d.abandoned)
    }
}

@MainActor @Suite struct RunSecondPassGateTests {
    func run(_ id: String, done: Double, updated: Double = 0) -> RunSummaryPayload {
        RunSummaryPayload(id: id, harness: "claude-code", state: .running, waitReason: nil, stale: false,
                          progress: TaskProgress(done: done, inFlight: 0, estimate: done), mustHaves: TaskMustHaves(done: 0, total: 0), etaSeconds: nil,
                          tokens: 0, limitWarning: nil, hasDeclaredTasks: true, startedAt: now, updatedAt: now.addingTimeInterval(updated),
                          counts: RunCounts(), finishedEarlier: nil)
    }

    @Test func twoLiveRunsSwappingPlacesIsProgressNotAStateChange() {
        var gate = RunPublishGate()
        _ = gate.pass([run("a", done: 0.2), run("b", done: 0.1)], now: now)
        // b moved ahead of a, and both progressed: the 5-minute pace, not once a minute.
        let swapped = [run("b", done: 0.3, updated: 60), run("a", done: 0.25, updated: 50)]
        let held = gate.pass(swapped, now: now.addingTimeInterval(61))
        #expect(held.retryAfter == 239)
        #expect(gate.pass(swapped, now: now.addingTimeInterval(300)).runs == swapped)
    }

    @Test func aNewRunOrAStateChangeStillGoesWithinAMinute() {
        var gate = RunPublishGate()
        _ = gate.pass([run("a", done: 0.2)], now: now)
        #expect(gate.pass([run("b", done: 0), run("a", done: 0.2)], now: now.addingTimeInterval(60)).retryAfter == nil)
        var waiting = run("a", done: 0.2)
        waiting.state = .waiting; waiting.waitReason = .input
        #expect(gate.pass([run("b", done: 0), waiting], now: now.addingTimeInterval(120)).retryAfter == nil)
        var abandoned = waiting
        abandoned.abandoned = true
        #expect(gate.pass([abandoned, run("b", done: 0)], now: now.addingTimeInterval(180)).retryAfter == nil)
    }
}

@MainActor @Suite struct RunSecondPassMergeTests {
    @Test func theMacsActivityAndPricesReachTheDigest() throws {
        let runs = RunSummaryBuilder.summaries([DemoRecords.detailed(Demo.finishedRun(now: now), now: now),
                                                DemoRecords.detailed(Demo.inputRun(now: now), now: now)], includeNames: true, includeQuestion: true, now: now)
        let active = now.addingTimeInterval(-40)
        let env = DeviceEnvelope(deviceID: "laptop", updatedAt: now, lastSeenAt: now, payload: device(runs, activeAt: active))
        // What this Mac's gpt-6-sol cost per token this week: 20 micro-dollars.
        let slot = ActivitySlot(slot: ActivitySlot.slot(for: now.addingTimeInterval(-3600)), model: "gpt-6-sol", tokens: TokenCounts(cacheRead: 1_000_000),
                                micros: 20_000_000, unpricedTokens: 0, classMicros: [0, 0, 20_000_000, 0])
        let day = Envelope(deviceID: "laptop", provider: .codex, accountKey: "k", day: slot.day, updatedAt: now, payload: ActivityDayPayload(day: slot.day, slots: [slot]))
        let merged = RunMerge.digests([env], now: now, activity: [day])
        let finished = try #require(merged.first { $0.state.isTerminal })
        #expect(abs((finished.cost ?? 0) - 5.92) < 0.001)
        #expect(finished.receipt?.seconds == Double(102 * 60))
        let input = try #require(merged.first { $0.needsInput })
        #expect(input.macActiveAt == active)
        #expect(input.question?.text.hasPrefix("May I drop") == true)
        // No activity for the model: list rates at a typical mix, still an estimate.
        let unpriced = RunMerge.digests([env], now: now).first { $0.state.isTerminal }
        #expect((unpriced?.cost ?? 0) > 0)
    }
}

@MainActor @Suite struct RunSecondPassLedgerTests {
    func digest(_ id: String, _ state: TaskRunState, wait: TaskWaitReason? = nil, updated: Date = now, active: Date? = nil) -> RunDigest {
        var d = RunDigest(id: id, mac: "MacBook Pro", state: state, waitReason: wait, hasDeclaredTasks: true, startedAt: now.addingTimeInterval(-3600),
                          updatedAt: updated)
        d.macActiveAt = active
        return d
    }

    @Test func aQuestionIsHeldWhileYouAreAtTheMac() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([digest("a", .running)], now: now, needsInput: true, finished: true)
        // Touched the Mac 30 seconds ago: held until two minutes after that.
        let first = ledger.observe([digest("a", .waiting, wait: .input, active: now.addingTimeInterval(-30))], now: now, needsInput: true, finished: true)
        #expect(first.due.map(\.kind) == [.needsInput])
        #expect(first.due.first?.deliverAt == now.addingTimeInterval(90))
        // Still there a minute later: pushed back.
        let later = ledger.observe([digest("a", .waiting, wait: .input, active: now.addingTimeInterval(55))], now: now.addingTimeInterval(60),
                                   needsInput: true, finished: true)
        #expect(later.due.first?.deliverAt == now.addingTimeInterval(175))
        // Answered at the Mac before it went out: withdrawn, and nothing new.
        let answered = ledger.observe([digest("a", .running)], now: now.addingTimeInterval(100), needsInput: true, finished: true)
        #expect(answered.withdraw == ["a"])
        #expect(answered.due.isEmpty)
    }

    @Test func aQuestionAlertsAtOnceWhenTheMacIsIdle() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([], now: now, needsInput: true, finished: true)
        let due = ledger.observe([digest("a", .waiting, wait: .input, active: now.addingTimeInterval(-600))], now: now, needsInput: true, finished: true).due
        #expect(due.count == 1 && due[0].deliverAt == nil)
        // A held alert that has gone out isn't withdrawn later.
        var held = RunAlertLedger()
        _ = held.observe([], now: now, needsInput: true, finished: true)
        _ = held.observe([digest("b", .waiting, wait: .input, active: now)], now: now, needsInput: true, finished: true)
        #expect(held.observe([digest("b", .running)], now: now.addingTimeInterval(300), needsInput: true, finished: true).withdraw.isEmpty)
    }

    @Test func aRunFinishesAtMostOnceEveryHalfHour() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([digest("a", .running)], now: now, needsInput: true, finished: true)
        #expect(ledger.observe([digest("a", .done)], now: now, needsInput: true, finished: true).due.count == 1)
        // A new batch of agents, done again ten minutes later: quiet.
        _ = ledger.observe([digest("a", .running)], now: now.addingTimeInterval(300), needsInput: true, finished: true)
        let t1 = now.addingTimeInterval(600)
        #expect(ledger.observe([digest("a", .done, updated: t1)], now: t1, needsInput: true, finished: true).due.isEmpty)
        // And again after the half hour: it alerts.
        _ = ledger.observe([digest("a", .running)], now: now.addingTimeInterval(1500), needsInput: true, finished: true)
        let t2 = now.addingTimeInterval(1900)
        #expect(ledger.observe([digest("a", .done, updated: t2)], now: t2, needsInput: true, finished: true).due.map(\.kind) == [.finished])
        // Repeated syncs of the same finish stay quiet.
        #expect(ledger.observe([digest("a", .done, updated: t2)], now: t2.addingTimeInterval(60), needsInput: true, finished: true).due.isEmpty)
    }

    @Test func stoppingWithWorkLeftAlertsOncePerEpisode() {
        var ledger = RunAlertLedger()
        _ = ledger.observe([digest("a", .running)], now: now, needsInput: true, finished: false, stopped: true)
        let due = ledger.observe([digest("a", .stopped)], now: now, needsInput: true, finished: false, stopped: true).due
        #expect(due.map(\.kind) == [.stopped])
        #expect(ledger.observe([digest("a", .stopped)], now: now.addingTimeInterval(60), needsInput: true, finished: false, stopped: true).due.isEmpty)
        // Picked up again, then stopped again: a new episode.
        _ = ledger.observe([digest("a", .running)], now: now.addingTimeInterval(120), needsInput: true, finished: false, stopped: true)
        #expect(ledger.observe([digest("a", .stopped)], now: now.addingTimeInterval(180), needsInput: true, finished: false, stopped: true).due.count == 1)
        // Given up on: no alert.
        var gaveUp = digest("b", .stopped)
        gaveUp.abandoned = true
        #expect(ledger.observe([gaveUp], now: now.addingTimeInterval(200), needsInput: true, finished: false, stopped: true).due.isEmpty)
    }

    @Test func aLedgerFromTheFirstReleaseStillDecodes() throws {
        let old = #"{"primed":true,"waiting":["a"],"finished":{}}"#
        let ledger = try JSONDecoder().decode(RunAlertLedger.self, from: Data(old.utf8))
        #expect(ledger.primed && ledger.waiting == ["a"] && ledger.held.isEmpty && ledger.stopped.isEmpty)
    }
}
