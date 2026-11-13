import Foundation
import Testing
@testable import HeadroomKit

/// Observed files lose activity lines that change nothing: the fold before equals the fold after.
@Suite struct TaskJournalCompactionTests {
    /// A long run the way the observer and an agent write it: the session and its agents report
    /// activity every 30 seconds, agents come and go, the agent declares and closes tasks, waits,
    /// stops and resumes, with idle stretches between.
    static func stream(seed: UInt64, hours: Double) -> (journal: [TaskEvent], observed: [TaskEvent]) {
        var rng = SplitMix(seed: seed)
        var journal: [TaskEvent] = [], observed: [TaskEvent] = []
        func j(_ s: Double, _ op: TaskEvent.Op, _ src: TaskSource = .agent) { journal.append(TaskEvent(at: TL.t(s), run: "r1", source: src, op: op)) }
        func o(_ s: Double, _ op: TaskEvent.Op) { observed.append(TaskEvent(at: TL.t(s), run: "r1", source: .harness, op: op)) }
        let ids = (0..<8).map { "t\($0)" } + ["g/a", "g/b"]
        o(0, .attempt(.init(key: "session:1", kind: .session, model: "claude-opus-5-5", provider: "claude")))
        for id in ids { j(0, .add(.init(id: id, effort: [1, 2, 4, 8].randomElement(using: &rng)!, importance: TaskImportance.allCases.randomElement(using: &rng)))) }
        var sessionTokens: Int64 = 0
        var agents: [String: Int64] = [:]
        var idleUntil = 0.0
        var n = 0
        var t = 0.0
        while t < hours * 3600 {
            t += 30
            if t >= idleUntil {
                if Int.random(in: 0..<200, using: &rng) == 0 { idleUntil = t + Double.random(in: 300...2400, using: &rng) }
                sessionTokens += Int64.random(in: 0...4000, using: &rng)
                o(t, .activity(attempt: "session:1", at: nil, tokens: sessionTokens))
            }
            for key in agents.keys.sorted() where Int.random(in: 0..<10, using: &rng) > 0 {
                agents[key]! += Int64.random(in: 100...9000, using: &rng)
                o(t + 1, .activity(attempt: key, at: nil, tokens: agents[key]!))
            }
            let id = ids.randomElement(using: &rng)!
            switch Int.random(in: 0..<120, using: &rng) {
            case 0, 1:
                n += 1
                let key = "agent:a\(n)"
                agents[key] = 0
                o(t + 2, .attempt(.init(key: key, agentType: "general-purpose", model: Bool.random(using: &rng) ? "claude-sonnet-5-5" : nil,
                                        tag: Bool.random(using: &rng) ? "[hr:r1:\(id)]" : nil, parentKey: "session:1", title: "Agent \(n)")))
            case 2:
                if let key = agents.keys.sorted().randomElement(using: &rng) {
                    agents[key] = nil
                    o(t + 3, .attemptEnd(attempt: key, outcome: [TaskAttemptOutcome.ok, .ok, .error].randomElement(using: &rng)!))
                }
            case 3: j(t + 4, .start(task: id))
            case 4: j(t + 4, .progress(task: id, step: Int.random(in: 0...4, using: &rng), total: [nil, 4].randomElement(using: &rng)!, fraction: nil, note: "on it"))
            case 5: j(t + 4, .done(task: id, evidence: "ok"))
            case 6: j(t + 4, .wait(task: [nil, id].randomElement(using: &rng)!, attempt: nil, reason: TaskWaitReason.allCases.randomElement(using: &rng)!, note: "?"))
            case 7: j(t + 5, .wait(task: nil, attempt: nil, reason: .input, note: "permission"), .hook)
            case 8: j(t + 5, .stop(blocked: false), .hook)
            case 9: j(t + 5, .resume, .hook)
            case 10: j(t + 4, .fail(task: id, reason: "broke"))
            default: break
            }
        }
        return (journal, observed)
    }

    func folds(_ events: [TaskEvent], at times: [Date]) -> [[TaskRun]] {
        times.flatMap { now in [TaskFold.fold(events, now: now), TaskFold.fold(events, now: now, tokensPerEffortUnit: 20_000)] }
    }

    @Test func droppingTheActivityChangesNoFold() {
        var dropped = 0
        for seed in 1...6 as ClosedRange<UInt64> {
            let (journal, observed) = Self.stream(seed: seed, hours: 12)
            let drop = TaskCompaction.droppableActivity(journal: journal, observed: observed)
            dropped += drop.count
            let kept = observed.indices.filter { !drop.contains($0) }.map { observed[$0] }
            let last = (journal + observed).map(\.at).max()!
            let times = [last, last.addingTimeInterval(600), last.addingTimeInterval(3 * 3600)]
            #expect(folds(journal + observed, at: times) == folds(journal + kept, at: times), "seed \(seed)")
            // Only activity goes, and none from the last hours.
            for i in drop {
                guard case .activity = observed[i].op else { Issue.record("dropped \(observed[i].op.name)"); continue }
                #expect(observed[i].at < last.addingTimeInterval(-TaskFold.recentLookback))
            }
        }
        #expect(dropped > 1000)
    }

    @Test func appendingCompactsTheObservedFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-compact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let (journal, observed) = Self.stream(seed: 42, hours: 16)
        try TaskJournal.append(journal, stream: .journal, home: home)
        // In batches, as the observer writes.
        var i = 0
        while i < observed.count {
            try TaskJournal.append(Array(observed[i..<min(i + 50, observed.count)]), stream: .observed, home: home)
            i += 50
        }
        let file = TaskJournal.url(run: "r1", stream: .observed, home: home)
        func lines() throws -> Int { try Data(contentsOf: file).split(separator: 0x0A).count }
        // It grew past the threshold several times on the way, and was compacted each time.
        let before = try lines()
        #expect(before < observed.count * 3 / 4)
        TaskJournal.compactObserved(run: "r1", home: home)
        let after = try lines()
        #expect(after < before && after < observed.count * 2 / 3, "\(after) of \(observed.count)")
        let read = TaskJournal.read(run: "r1", home: home)
        let last = (journal + observed).map(\.at).max()!
        let times = [last, last.addingTimeInterval(3 * 3600)]
        #expect(folds(read, at: times) == folds(journal + observed, at: times))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(TaskJournal.runs(home: home) == ["r1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: TaskJournal.directory(.observed, home: home).path) == ["r1.jsonl"])
        // Compacting again finds nothing more until more is written.
        #expect(TaskJournal.compactObserved(run: "r1", home: home) == 0)
    }

    @Test func shortOrBusyFilesAreLeftAlone() {
        // Activity with other events between, or within the last hours, all stays.
        var tl = TL()
        tl.session(0, 600, every: 30)
        tl.add(0, "a")
        for s in stride(from: 15.0, through: 600, by: 30) { tl.at(s, .progress(task: "a", step: nil, total: nil, fraction: s / 1000, note: nil)) }
        #expect(TaskCompaction.droppableActivity(journal: [], observed: tl.events).isEmpty)
        var quiet = TL()
        quiet.session(0, 3 * 3600, every: 30)
        #expect(TaskCompaction.droppableActivity(journal: [], observed: quiet.events).isEmpty)
        var long = TL()
        long.session(0, 6 * 3600, every: 30)
        let drop = TaskCompaction.droppableActivity(journal: [], observed: long.events)
        #expect(!drop.isEmpty && long.fold(6 * 3600) == TL(events: long.events.indices.filter { !drop.contains($0) }.map { long.events[$0] }).fold(6 * 3600))
    }
}
