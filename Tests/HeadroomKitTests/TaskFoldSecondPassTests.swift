import Foundation
import Testing
@testable import HeadroomKit

/// The second pass on the fold: one test per defect the review found, then the new fields.
@Suite struct TaskRunStateFixTests {
    @Test func aRunWaitForInputClearsOnTheOrchestratorsNextMove() {
        var tl = TL()
        tl.add(0, "a"); tl.at(0, .start(task: "a")); tl.add(0, "b")
        tl.session(0, 60)
        tl.at(61, .wait(task: nil, attempt: nil, reason: .input, note: "Claude needs your permission to use Bash"), .hook)
        var r = tl.fold(70)
        #expect(r.state == .waiting && r.needsInput)
        #expect(r.question == TaskQuestion(text: "Claude needs your permission to use Bash", task: nil, askedAt: TL.t(61)))
        // A background agent working doesn't answer it.
        tl.attempt(62, "agent:bg", tag: "b")
        tl.at(90, .activity(attempt: "agent:bg", at: nil, tokens: 10), .harness)
        #expect(tl.fold(100).needsInput)
        // The person approved: the orchestrator moves again.
        tl.session(120, 120)
        r = tl.fold(130)
        #expect(r.state == .running && r.question == nil && !r.needsInput)
    }

    @Test func anAgentsOwnQuestionOutlastsItsOwnToolCall() {
        var q = TL()
        q.add(0, "a"); q.at(0, .start(task: "a")); q.session(0, 30)
        q.at(31, .wait(task: nil, attempt: nil, reason: .input, note: "Which database?\nPick one.", options: ["Postgres", "SQLite", ""]))
        q.session(33, 40) // the call's result and the reply asking it
        q.at(41, .stop(blocked: false), .hook)
        var r = q.fold(50)
        #expect(r.needsInput && r.question?.text == "Which database? Pick one." && r.question?.options == ["Postgres", "SQLite"])
        q.session(300, 300) // answered: a new turn
        r = q.fold(310)
        #expect(r.state == .running && r.question == nil)
    }

    @Test func aRunWaitForALimitClearsOnLaterActivity() {
        var l = TL()
        l.add(0, "a"); l.at(0, .start(task: "a")); l.session(0, 0)
        l.at(10, .wait(task: nil, attempt: "session:1", reason: .limit, note: nil), .hook)
        #expect(l.fold(20).state == .waiting && l.fold(20).waitReason == .limit)
        l.session(30, 30)
        #expect(l.fold(40).state == .running)
    }

    @Test func deadRunsStop() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.session(0, 600)
        tl.attempt(10, "k", tag: "a")
        tl.at(600, .activity(attempt: "k", at: nil, tokens: 10), .harness)
        // Killed without hooks: nothing after 600. An hour on it's quiet, two hours on it's stopped.
        var r = tl.fold(600 + 3600)
        #expect(r.state == .running && r.stale)
        r = tl.fold(600 + 7300)
        #expect(r.state == .stopped && !r.stale)
        #expect(r.node("a").state == .parked && r.node("a").attempts.active == 0 && r.node("a").attempts.last?.outcome == .interrupted)
        #expect(tl.fold(600 + 700, abandon: 600).state == .stopped)
        // An agent silent that long is cut short even while the session goes on.
        var s = tl
        s.session(660, 600 + 7300)
        r = s.fold(600 + 7300)
        #expect(r.state == .running && r.node("a").state == .parked)
    }

    @Test func observedRunsCanStop() {
        // The session is the orchestrator, not an agent keeping the run alive.
        var o = TL()
        o.session(0, 100)
        o.add(0, "a"); o.at(1, .start(task: "a"))
        o.at(101, .stop(blocked: false), .hook)
        #expect(o.fold(110).state == .stopped)
        // A background agent's report after the stop doesn't undo it.
        var bg = TL()
        bg.session(0, 10)
        bg.add(0, "a"); bg.add(0, "b"); bg.at(1, .start(task: "a"))
        bg.attempt(5, "agent:bg", tag: "b")
        bg.at(11, .stop(blocked: false), .hook)
        #expect(bg.fold(12).state == .running)
        bg.at(20, .done(task: "b", evidence: nil))
        bg.at(21, .attemptEnd(attempt: "agent:bg", outcome: .ok), .harness)
        #expect(bg.fold(30).state == .stopped)
    }

    @Test func aRunWaitingOnAPersonOutlastsTheSilence() {
        var w = TL()
        w.add(0, "a"); w.at(0, .start(task: "a"))
        w.at(10, .wait(task: nil, attempt: nil, reason: .input, note: "?"), .hook)
        #expect(w.fold(10 + 3 * 3600).state == .waiting)
        var d = TL()
        d.add(0, "a"); d.at(0, .wait(task: "a", attempt: nil, reason: .dependency, note: nil))
        #expect(d.fold(3 * 3600).state == .stopped)
    }

    @Test func aTerminalRunsPercentMatchesItsState() {
        var tl = TL()
        tl.add(0, "core"); tl.add(0, "extras", importance: .optional); tl.add(0, "extras/x"); tl.add(0, "extras/y")
        tl.at(1, .done(task: "core", evidence: nil)); tl.at(1, .done(task: "extras/x", evidence: nil)); tl.at(1, .fail(task: "extras/y", reason: nil))
        let r = tl.fold(2)
        #expect(r.node("extras").state == .partial && !r.node("extras").counted)
        #expect(r.state == .done && r.progress == .complete)
        var s = TL()
        s.add(0, "a"); s.add(0, "b"); s.at(1, .skip(task: "a", reason: nil)); s.at(1, .skip(task: "b", reason: nil))
        #expect(s.fold(2).state == .done && s.fold(2).progress == .complete)
        // Unfinished runs never read 100%.
        var u = TL()
        u.session(0, 0)
        u.attempt(1, "agent:1", parent: "session:1"); u.at(2, .attemptEnd(attempt: "agent:1", outcome: .ok), .harness)
        #expect(u.fold(3).state == .running && u.fold(3).progress.estimate < 1)
    }
}

@Suite struct TaskBindingFixTests {
    @Test func aMistypedTagMakesAHelper() {
        var tl = TL()
        tl.add(0, "api/tests"); tl.add(0, "api/schema")
        tl.attempt(1, "agent:x", tag: "Write them [hr:r1:api/test]")
        var r = tl.fold(2)
        #expect(!r.nodes.contains { $0.id == "api/test" })
        #expect(r.node("~agent-x").parent == "api" && !r.node("~agent-x").counted && r.node("~agent-x").state == .running)
        #expect(r.node("api/tests").state == .planned && r.progress.estimate == 0)
        #expect(r.nodes.filter { $0.leaf && $0.counted }.map(\.id) == ["api/tests", "api/schema"])
        // Nothing of the path in the plan: at the top.
        tl.attempt(3, "agent:y", tag: "zzz/q")
        r = tl.fold(4)
        #expect(r.node("~agent-y").parent == nil && !r.node("~agent-y").counted)
        // A late mistyped tag places the helper the same way.
        tl.attempt(5, "agent:z"); tl.attempt(6, "agent:z", tag: "api/schemas")
        #expect(tl.fold(7).node("~agent-z").parent == "api")
        // A right tag still binds.
        tl.attempt(8, "agent:w", tag: "[hr:r1:api/schema]")
        #expect(tl.fold(9).node("api/schema").attempts.count == 1)
    }

    @Test func agentsSideBySideArentRetries() {
        var tl = TL()
        tl.add(0, "a")
        tl.attempt(1, "k1", tag: "a"); tl.attempt(2, "k2", tag: "a"); tl.attempt(3, "k3", tag: "a")
        #expect(tl.fold(4).node("a").attempts.retries == 0 && tl.fold(4).node("a").attempts.count == 3)
        for k in ["k1", "k2", "k3"] { tl.at(5, .attemptEnd(attempt: k, outcome: .error), .harness) }
        tl.attempt(6, "k4", tag: "a")
        #expect(tl.fold(7).node("a").attempts.retries == 1)
    }

    @Test func waitsClearOnLaterWork() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b"); tl.add(0, "c")
        tl.attempt(0, "kc", tag: "c")
        tl.at(1, .wait(task: "a", attempt: nil, reason: .dependency, note: "after b"))
        tl.at(1, .wait(task: "b", attempt: nil, reason: .limit, note: nil))
        tl.at(1, .wait(task: "c", attempt: nil, reason: .dependency, note: nil))
        var r = tl.fold(2)
        #expect(r.node("a").state == .waiting && r.node("b").state == .waiting && r.node("c").state == .waiting)
        tl.at(3, .progress(task: "a", step: nil, total: nil, fraction: 0.2, note: nil))
        tl.at(3, .start(task: "b"))
        tl.at(10, .activity(attempt: "kc", at: nil, tokens: 5), .harness) // its own call to wait, showing up
        r = tl.fold(11)
        #expect(r.node("a").state == .running && r.node("b").state == .running && r.node("c").state == .waiting)
        tl.at(120, .activity(attempt: "kc", at: nil, tokens: 9), .harness)
        #expect(tl.fold(121).node("c").state == .running)
    }

    @Test func agentTextIsClamped() {
        var tl = TL()
        tl.at(0, .meta(title: "Run\ttitle\u{202E}", project: nil, harness: nil))
        tl.add(0, "a", title: String(repeating: "x", count: 300))
        tl.at(1, .progress(task: "a", step: nil, total: nil, fraction: nil, note: "line one\nline two\u{1B}[31m red\u{7}"))
        tl.at(2, .fail(task: "a", reason: String(repeating: "y", count: 1000)))
        tl.attempt(3, "agent:q", title: "Look\r\naround")
        let r = tl.fold(4)
        #expect(r.node("a").title.count == 120 && r.node("a").title.hasSuffix("…"))
        #expect(r.node("a").note == "line one line two[31m red")
        #expect(r.node("a").failure?.count == 400)
        #expect(r.title == "Run title")
        #expect(r.node("~agent-q").title == "Look  around")
        #expect(TaskText.note("  \n\t ") == nil && TaskText.title("ok") == "ok" && TaskText.title(nil) == nil)
    }
}

@Suite struct TaskProgressFixTests {
    @Test func aStepWithNoTotalIsntCompletion() {
        var tl = TL()
        tl.add(0, "a")
        tl.at(1, .progress(task: "a", step: 3, total: nil, fraction: nil, note: nil))
        var r = tl.fold(2)
        #expect(r.node("a").state == .running && r.node("a").steps == nil && r.node("a").progress.done == 0 && r.progress.estimate < 1)
        tl.at(3, .progress(task: "a", step: nil, total: 6, fraction: nil, note: nil))
        r = tl.fold(4)
        #expect(r.node("a").steps == TaskSteps(done: 3, total: 6) && r.node("a").progress.done == 0.5)
        // The latest report wins, steps or fraction.
        tl.at(5, .progress(task: "a", step: nil, total: nil, fraction: 0.8, note: nil))
        #expect(tl.fold(6).node("a").progress.done == 0.8)
        tl.at(7, .progress(task: "a", step: 4, total: nil, fraction: nil, note: nil))
        #expect(near(tl.fold(8).node("a").progress.done, 4.0 / 6))
    }

    @Test func groupsWeighTheirChildren() {
        var tl = TL()
        tl.add(0, "docs")
        for i in 0..<10 { tl.add(0, "api/t\(i)") }
        tl.at(1, .done(task: "docs", evidence: nil))
        let r = tl.fold(2)
        #expect(r.node("api").effort == 40 && near(r.progress.done, 1.0 / 11))
        #expect(near(r.node("docs").share, 1.0 / 11) && near(r.node("api").share, 10.0 / 11) && near(r.node("api/t3").share, 1.0 / 11))
        #expect(near(r.nodes.filter { $0.leaf && $0.counted }.reduce(0) { $0 + $1.share }, 1))
        // A declared effort on the group still wins.
        var e = tl
        e.add(0, "api", effort: 4)
        #expect(e.fold(2).node("api").effort == 4 && near(e.fold(2).progress.done, 0.5))
    }

    @Test func runningTasksEarnCreditFromTimeAgainstFinishedOnes() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b")
        tl.attempt(0, "ka", tag: "a"); tl.attempt(0, "kb", tag: "b")
        for s in stride(from: 60.0, through: 1200, by: 60) { tl.at(s, .activity(attempt: "ka", at: nil, tokens: nil), .harness) }
        tl.at(1200, .done(task: "a", evidence: "ok")) // 1200 s of work for effort 4: 300 s a unit
        for s in stride(from: 60.0, through: 600, by: 60) { tl.at(s, .activity(attempt: "kb", at: nil, tokens: nil), .harness) }
        var r = tl.fold(1200)
        #expect(near(r.node("a").workingSeconds, 1200) && near(r.node("b").workingSeconds, 600))
        #expect(r.node("b").progress == TaskProgress(done: 0, inFlight: 1, estimate: 0.5))
        #expect(near(r.progress.done, 0.5) && near(r.progress.estimate, 0.75))
        // A report beats the guess…
        var rep = tl
        rep.at(1200, .progress(task: "b", step: nil, total: nil, fraction: 0.2, note: nil))
        #expect(near(rep.fold(1200).node("b").progress.estimate, 0.2))
        // …and the guess stops short of done.
        for s in stride(from: 660.0, through: 2400, by: 60) { tl.at(s, .activity(attempt: "kb", at: nil, tokens: nil), .harness) }
        r = tl.fold(2400)
        #expect(r.node("b").progress.estimate == TaskFold.maxGuess)
    }

    @Test func theOrchestratorsOwnTasksGetItsTimeAndTokens() {
        var tl = TL()
        tl.add(0, "a", effort: 1); tl.add(0, "b", effort: 3); tl.add(0, "c")
        tl.session(0, 0, tokens: { _ in 1000 }) // context before any task started: nobody's
        tl.at(10, .start(task: "a")); tl.at(10, .start(task: "b"))
        tl.attempt(10, "agent:c", tag: "c")
        tl.session(60, 1800, tokens: { s in 1000 + Int64(s) * 10 })
        var r = tl.fold(1900, stale: 300)
        // 18,000 tokens while a and b ran, split 1 : 3. c has an agent of its own.
        #expect(r.node("a").tokens == 4500 && r.node("b").tokens == 13500 && r.node("c").tokens == 0)
        #expect(r.tokens == 19000)
        // Alive while the orchestrator is: not quiet, though nothing was reported since the start.
        #expect(!r.node("a").stale && r.node("c").stale)
        #expect(near(r.node("a").workingSeconds, 1790))
        // A finished one feeds the calibration.
        tl.at(1800, .done(task: "a", evidence: nil))
        r = tl.fold(1900)
        #expect(TaskFold.tokensPerEffortUnit([r]) == 4500)
    }

    @Test func inferredOutcomesAreTheEstimateNotDone() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b"); tl.add(0, "c"); tl.at(0, .start(task: "c"))
        tl.attempt(1, "k", tag: "a"); tl.at(2, .attemptEnd(attempt: "k", outcome: .ok), .harness)
        tl.at(2, .done(task: "b", evidence: nil))
        let r = tl.fold(3)
        #expect(r.node("a").state == .done && !r.node("a").confirmed && r.node("a").progress == TaskProgress(done: 0, inFlight: 1, estimate: 1))
        #expect(near(r.progress.done, 1.0 / 3) && near(r.progress.estimate, 2.0 / 3) && r.state == .running)
        // Once everything has an outcome the run is done, and reads 100%.
        var c = tl
        c.at(3, .done(task: "c", evidence: "checked"))
        #expect(c.fold(4).state == .done && c.fold(4).progress == .complete)
    }
}

@Suite struct TaskRunFieldTests {
    @Test func timeTokensAndWhereTheRunLives() {
        var tl = TL()
        tl.at(0, .meta(title: "T", project: nil, harness: "claude-code", host: "com.googlecode.iterm2", cwd: "/Users/me/shop"))
        tl.at(0, .meta(title: nil, project: nil, harness: nil, host: nil, cwd: nil)) // nil leaves them
        tl.add(0, "a"); tl.at(0, .start(task: "a"))
        tl.at(0, .attempt(.init(key: "session:1", kind: .session, model: "claude-opus-5-5")), .harness)
        tl.session(0, 600, tokens: { s in Int64(s) * 100 })
        tl.attempt(100, "agent:x")
        tl.at(100, .activity(attempt: "agent:x", at: nil, tokens: 500), .harness)
        tl.at(110, .attemptEnd(attempt: "agent:x", outcome: .ok), .harness)
        tl.at(600, .wait(task: nil, attempt: nil, reason: .input, note: "Allow rm?"), .hook)
        #expect(tl.fold(700).question == TaskQuestion(text: "Allow rm?", askedAt: TL.t(600)))
        #expect(tl.fold(700).time.waitingInput == 100)
        tl.session(900, 1500, tokens: { s in Int64(s) * 100 }) // answered after five minutes
        let r = tl.fold(1500)
        #expect(r.host == "com.googlecode.iterm2" && r.cwd == "/Users/me/shop")
        #expect(r.time == TaskTimeSplit(working: 1200, waitingInput: 300, waitingLimit: 0, idle: 0))
        #expect(r.tokensByModel == ["claude-opus-5-5": 150_000, "unknown": 500])
        #expect(near(r.recentTokensPerHour ?? -1, 150_500 / (1200.0 / 3600), 1e-6))
        #expect(r.tokensToFinish == nil) // no calibration, and no estimate to go on
        let cal = tl.fold(1500, tpu: 50_000)
        #expect(near(cal.node("a").progress.estimate, 0.75) && cal.tokensToFinish == 50_000)
        // Live only: a stopped run has no recent rate.
        var s = tl
        s.at(1501, .stop(blocked: false), .hook)
        #expect(s.fold(1600).recentTokensPerHour == nil && near(s.fold(1600).time.total, 1501))
    }

    @Test func aTasksQuestionCarriesItsOptions() {
        var tl = TL()
        tl.add(0, "a")
        tl.attempt(1, "k", tag: "a")
        tl.at(2, .wait(task: "a", attempt: nil, reason: .input, note: "Drop the audit table?", options: ["Drop it", "Keep it"]))
        let r = tl.fold(3)
        #expect(r.question == TaskQuestion(text: "Drop the audit table?", options: ["Drop it", "Keep it"], task: "a", askedAt: TL.t(2)))
        tl.at(3, .progress(task: "a", step: nil, total: nil, fraction: 0.5, note: nil))
        #expect(tl.fold(4).question == nil)
    }

    @Test func hideAndAbandon() {
        var tl = TL()
        tl.add(0, "a"); tl.add(0, "b"); tl.add(0, "c")
        tl.at(1, .done(task: "a", evidence: nil))
        tl.attempt(2, "k", tag: "b")
        tl.at(3, .hide(true), .user)
        var r = tl.fold(4)
        #expect(r.hidden && r.updatedAt == TL.t(2))
        tl.at(5, .hide(false), .user)
        #expect(!tl.fold(6).hidden)
        tl.at(7, .abandon(reason: nil), .user)
        r = tl.fold(8)
        #expect(r.abandoned && r.state == .partial && r.etaSeconds == nil && r.state.isTerminal)
        #expect(r.node("a").state == .done && r.node("b").state == .cancelled && r.node("c").state == .cancelled && r.node("c").note == "Abandoned")
        #expect(r.node("b").attempts.active == 0 && r.node("b").attempts.last?.outcome == .interrupted)
        var why = TL()
        why.add(0, "a"); why.at(1, .abandon(reason: "Wrong approach"), .user)
        #expect(why.fold(2).node("a").note == "Wrong approach")
    }

    @Test func aMirroredPlanIsThePlanUntilOneIsDeclared() {
        func items(_ s: [(String, TaskPlanItem.Status)]) -> [TaskPlanItem] { s.map { TaskPlanItem(id: $0.0, title: "Step \($0.0)", status: $0.1) } }
        var tl = TL()
        tl.session(0, 0)
        tl.at(1, .planMirror(items: items([("1", .inProgress), ("2", .pending), ("3", .pending)]), tool: "todo"), .harness)
        var r = tl.fold(2)
        #expect(r.mirrored && r.hasDeclaredTasks)
        #expect(r.nodes.map(\.id) == ["~plan/1", "~plan/2", "~plan/3"])
        #expect(r.node("~plan/1").state == .running && r.node("~plan/1").parent == nil && r.node("~plan/1").title == "Step 1" && !r.node("~plan/1").declared)
        // An agent spawned while one step is in progress helps with it.
        tl.attempt(2, "agent:h", parent: "session:1")
        tl.at(3, .planMirror(items: items([("1", .completed), ("2", .inProgress), ("4", .pending)]), tool: "todo"), .harness)
        r = tl.fold(4)
        #expect(r.nodes.map(\.id) == ["~plan/1", "~agent-h", "~plan/2", "~plan/4"])
        #expect(r.node("~agent-h").parent == "~plan/1" && !r.node("~agent-h").counted)
        #expect(r.node("~plan/1").state == .done && r.node("~plan/1").confirmed && near(r.progress.done, 1.0 / 3))
        // An agent declares: the mirror goes, and the agent seen before counts as earlier work.
        tl.add(5, "api")
        r = tl.fold(6)
        #expect(!r.mirrored && r.hasDeclaredTasks && r.nodes.map(\.id) == [TaskFold.earlierID, "~agent-h", "api"])
        tl.at(7, .planMirror(items: items([("9", .pending)]), tool: "todo"), .harness)
        #expect(!tl.fold(8).nodes.contains { $0.id.hasPrefix(TaskFold.planPrefix) })
        // Every step done: the run is.
        var m = TL()
        m.session(0, 0)
        m.at(1, .planMirror(items: items([("1", .completed), ("2", .cancelled)]), tool: nil), .harness)
        // A step dropped from the plan isn't a failure.
        #expect(m.fold(2).node("~plan/2").state == .cancelled && m.fold(2).state == .done)
        m.at(2, .planMirror(items: items([("1", .completed)]), tool: nil), .harness)
        #expect(m.fold(3).state == .done && m.fold(3).nodes.count == 1)
        // Odd ids are made safe and kept apart.
        var o = TL()
        o.at(0, .planMirror(items: [TaskPlanItem(id: "a b", title: "One", status: .pending), TaskPlanItem(id: "a:b", title: "Two", status: .pending),
                                    TaskPlanItem(id: "", title: "Three", status: .pending)], tool: nil), .harness)
        #expect(o.fold(1).nodes.map(\.id) == ["~plan/a-b", "~plan/a-b-2", "~plan/item-3"])
    }
}

@Suite struct TaskFoldPropertyTests {
    /// Random runs with every op: the run's numbers stay in range and agree with its state.
    @Test func randomRunsKeepTheirInvariants() {
        var rng = SplitMix(seed: 7)
        let ids = ["a", "a/x", "a/y", "b", "c", "c/z"]
        for _ in 0..<150 {
            var tl = TL()
            var keys: [String] = []
            var s = 0.0
            tl.at(0, .attempt(.init(key: "session:1", kind: .session, model: "m")), .harness)
            for _ in 0..<Int.random(in: 5...70, using: &rng) {
                s += [5, 30, 120, 400, 3000].randomElement(using: &rng)!
                let id = ids.randomElement(using: &rng)!
                switch Int.random(in: 0..<20, using: &rng) {
                case 0: tl.add(s, id, effort: [nil, 1, 8].randomElement(using: &rng)!, importance: TaskImportance.allCases.randomElement(using: &rng), steps: [nil, 4].randomElement(using: &rng)!)
                case 1: tl.at(s, .start(task: id))
                case 2: tl.at(s, .progress(task: id, step: [nil, 1, 3].randomElement(using: &rng)!, total: [nil, 4].randomElement(using: &rng)!, fraction: [nil, 0.3].randomElement(using: &rng)!, note: "n"))
                case 3: tl.at(s, .wait(task: [nil, id].randomElement(using: &rng)!, attempt: nil, reason: TaskWaitReason.allCases.randomElement(using: &rng)!, note: "q"),
                              [TaskSource.agent, .hook].randomElement(using: &rng)!)
                case 4: tl.at(s, .done(task: id, evidence: nil))
                case 5: tl.at(s, .fail(task: id, reason: nil))
                case 6: tl.at(s, .skip(task: id, reason: nil))
                case 7:
                    let k = "k\(keys.count)"
                    keys.append(k)
                    tl.attempt(s, k, tag: Bool.random(using: &rng) ? id : nil, parent: ["session:1", keys.randomElement(using: &rng)!].randomElement(using: &rng)!)
                case 8, 9: if let k = keys.randomElement(using: &rng) { tl.at(s, .activity(attempt: k, at: nil, tokens: Int64(s)), .harness) }
                case 10: if let k = keys.randomElement(using: &rng) { tl.at(s, .attemptEnd(attempt: k, outcome: TaskAttemptOutcome.allCases.randomElement(using: &rng)), .harness) }
                case 11: tl.at(s, .stop(blocked: false), .hook)
                case 12: tl.at(s, .resume, .hook)
                case 13: if Int.random(in: 0..<4, using: &rng) == 0 { tl.at(s, .end, .hook) }
                case 14: tl.at(s, .planMirror(items: [TaskPlanItem(id: "1", title: "One", status: TaskPlanItem.Status.allCases.randomElement(using: &rng)!),
                                                      TaskPlanItem(id: "2", title: "Two", status: .pending)], tool: "todo"), .harness)
                case 15: if Int.random(in: 0..<6, using: &rng) == 0 { tl.at(s, .abandon(reason: nil), .user) }
                case 16: tl.at(s, .hide(Bool.random(using: &rng)), .user)
                default: tl.at(s, .activity(attempt: "session:1", at: nil, tokens: Int64(s) * 2), .harness)
                }
            }
            for now in [s + 60, s + 4000, s + 9000] {
                for tpu in [nil, 5_000.0] {
                    let r = tl.fold(now, tpu: tpu)
                    for p in r.nodes.map(\.progress) + [r.progress] {
                        #expect(p.done >= 0 && p.done <= 1 && p.inFlight >= 0 && p.estimate >= 0 && p.estimate <= 1)
                        #expect(p.done <= p.estimate + 1e-12 && p.done + p.inFlight <= 1 + 1e-12)
                    }
                    if r.state == .done { #expect(r.progress == .complete) }
                    if !r.state.isTerminal { #expect(r.progress.estimate < 1) }
                    if let eta = r.etaSeconds {
                        #expect(r.state == .running && eta >= 0 && eta.isFinite)
                        #expect(r.etaLowSeconds! <= eta + 1e-9 && eta <= r.etaHighSeconds! + 1e-9)
                    }
                    #expect(r.question == nil || r.needsInput)
                    #expect(r.time.working >= 0 && r.time.idle >= 0 && r.time.waitingInput >= 0 && r.time.waitingLimit >= 0)
                    let span = (r.state.isTerminal || r.state == .stopped ? r.updatedAt : max(TL.t(now), r.updatedAt)).timeIntervalSince(r.startedAt)
                    #expect(abs(r.time.total - span) < 1e-6)
                    let shares = r.nodes.filter { $0.leaf && $0.counted }.reduce(0) { $0 + $1.share }
                    #expect(r.nodes.allSatisfy { $0.share >= 0 && ($0.counted || $0.share == 0) } && shares <= 1 + 1e-9)
                    #expect(r.mustHaves.done <= r.mustHaves.total)
                    #expect(r.nodes.filter { $0.leaf && $0.counted }.reduce(Int64(0)) { $0 + $1.tokens } <= r.tokens)
                }
            }
        }
    }
}
