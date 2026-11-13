import Foundation
import HeadroomKit

/// Agent-run fixtures for the Runs tab, the menu bar indicator, Activity's recent runs and
/// Settings (`--render runs`). Every title is an invented, generic example.
extension Demo {
    public struct RunScenario {
        public var name: String
        public var runs: [TaskRun]
        public var expanded: Set<String>
        /// Rows shown opened (`RunsPresenter.rowKey`).
        public var opened: Set<String>
        public var allRecent: Bool
        public var note: String

        public init(name: String, runs: [TaskRun], expanded: Set<String> = [], opened: Set<String> = [], allRecent: Bool = false, note: String) {
            self.name = name; self.runs = runs; self.expanded = expanded; self.opened = opened; self.allRecent = allRecent; self.note = note
        }
    }

    public static func runScenarios(now: Date) -> [RunScenario] {
        let declared = declaredRun(now: now), observed = observedRun(now: now), input = inputRun(now: now)
        let finished = finishedRun(now: now)
        return [
            RunScenario(name: "declared", runs: [declared], note: "A declared plan in progress: the percent, its counts and the task map"),
            RunScenario(name: "declared-expanded", runs: [declared], expanded: [declared.id],
                        opened: [RunsPresenter.rowKey(run: declared.id, row: "schema"), RunsPresenter.rowKey(run: declared.id, row: "tests")],
                        note: "The same run with its finished rows shown and two rows opened"),
            RunScenario(name: "observed", runs: [observed], note: "Nothing declared: the agents Headroom saw spawned"),
            RunScenario(name: "input", runs: [input], opened: [RunsPresenter.rowKey(run: input.id, row: "inventory")],
                        note: "An agent is asking a question, with answers offered"),
            RunScenario(name: "timeline", runs: [timelineRun(now: now)], note: "Forecast to hit the 5-hour window before it finishes"),
            RunScenario(name: "limit", runs: [limitRun(now: now)], note: "Waiting on the 5-hour limit, with the warning"),
            RunScenario(name: "mirrored", runs: [mirroredRun(now: now)], note: "A plan read from the session's own todo list"),
            RunScenario(name: "stopped", runs: [stoppedRun(now: now)], note: "The orchestrator stopped with work left"),
            RunScenario(name: "finished", runs: [finished], opened: [RunsPresenter.rowKey(run: finished.id, row: "bench")],
                        note: "Done, with a failed optional task: the receipt"),
            RunScenario(name: "failed", runs: [failedRun(now: now)], note: "A critical task failed"),
            RunScenario(name: "replaced", runs: [replacedRun(now: now)], opened: [RunsPresenter.rowKey(run: "demo-replaced", row: "root")],
                        note: "Done: a failed approach was worked around another way"),
            RunScenario(name: "abandoned", runs: [abandonedRun(now: now)], note: "Given up on from the card"),
            RunScenario(name: "large", runs: [largeRun(now: now)], note: "A session that ran for days: 1,004 agents"),
            RunScenario(name: "mixed", runs: mixedRuns(now: now), note: "Live runs, then the last day's finished ones"),
            RunScenario(name: "mixed-all", runs: mixedRuns(now: now), allRecent: true, note: "Every finished run of the last day listed"),
            RunScenario(name: "empty", runs: [], note: "Nothing tracked yet"),
        ]
    }

    /// Several live runs (one asking, one quiet) and five finished ones.
    public static func mixedRuns(now: Date) -> [TaskRun] {
        [inputRun(now: now), declaredRun(now: now), observedRun(now: now), quietRun(now: now), finishedRun(now: now), failedRun(now: now),
         abandonedRun(now: now), mirroredFinishedRun(now: now), shortRun(now: now)].sortedForDisplay()
    }

    /// Menu bar states: three runs going, two asking, the lead run gone quiet.
    public static func menuBarRunSets(now: Date) -> [(String, [TaskRun])] {
        let second = { var r = inputRun(now: now); r.id = "demo-input-2"; r.title = "Rename the billing tables"; return r }()
        return [
            ("one", [declaredRun(now: now)]),
            ("observed", [observedRun(now: now)]),
            ("several", [declaredRun(now: now), observedRun(now: now), mirroredRun(now: now)].sortedForDisplay()),
            ("input", [inputRun(now: now), declaredRun(now: now)].sortedForDisplay()),
            ("two-input", [inputRun(now: now), second, declaredRun(now: now)].sortedForDisplay()),
            ("quiet", [quietRun(now: now)]),
        ]
    }

    private static func ago(_ now: Date, _ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private static func mins(_ m: Double) -> Double { m * 60 }

    private static func task(_ id: String, _ title: String, depth: Int = 0, _ state: TaskState, progress: TaskProgress? = nil,
                             importance: TaskImportance = .normal, declared: Bool = true, leaf: Bool = true, steps: TaskSteps? = nil,
                             note: String? = nil, waitReason: TaskWaitReason? = nil, waitNote: String? = nil, failure: String? = nil,
                             evidence: String? = nil, confirmed: Bool = true, tokens: Int64 = 0, started: Date? = nil, ended: Date? = nil,
                             active: Int = 0, agents: Int? = nil, retries: Int = 0, stale: Bool = false, last: Date? = nil, share: Double = 0,
                             working: Double = 0) -> TaskNode {
        let parent = depth == 0 ? nil : id.split(separator: "/").dropLast().joined(separator: "/")
        let p = progress ?? (state == .done ? .complete : state == .running || state == .waiting ? TaskProgress(done: 0, inFlight: 1, estimate: 0.3) : .zero)
        return TaskNode(id: id, title: title, parent: parent, depth: depth, state: state, waitReason: waitReason, stale: stale, progress: p,
                        importance: importance, declared: declared, confirmed: confirmed, leaf: leaf,
                        counted: !(importance == .optional && state == .failed) && state != .skipped && state != .cancelled, steps: steps, note: note,
                        waitNote: waitNote, evidence: evidence, failure: failure,
                        attempts: TaskAttemptsSummary(count: agents ?? active, active: active, retries: retries), tokens: tokens,
                        startedAt: started, endedAt: ended, lastActivityAt: last ?? ended ?? started, share: share, workingSeconds: working)
    }

    /// "Move checkout to the new payments API": a plan with a three-level tree, a bit over half done.
    public static func declaredRun(now: Date) -> TaskRun {
        let w = 42.0
        let nodes = [
            task("schema", "Migrate the orders schema", .done, importance: .critical, evidence: "Migration 0042 applied on staging; row counts match",
                 tokens: 412_000, started: ago(now, 70), ended: ago(now, 52), agents: 1, share: 8 / w, working: mins(17)),
            task("api", "Port the checkout endpoints", .running, progress: TaskProgress(done: 0.55, inFlight: 0.45, estimate: 0.7), leaf: false,
                 tokens: 1_380_000, started: ago(now, 50)),
            task("api/client", "Generate the payments client", depth: 1, .done, tokens: 240_000, started: ago(now, 50), ended: ago(now, 41),
                 share: 4 / w, working: mins(9)),
            task("api/routes", "Rewrite the routes", depth: 1, .running, progress: TaskProgress(done: 0.4, inFlight: 0.6, estimate: 0.6),
                 leaf: false, tokens: 860_000, started: ago(now, 40)),
            task("api/routes/cart", "Cart and totals", depth: 2, .done, importance: .critical, tokens: 310_000, started: ago(now, 40), ended: ago(now, 22),
                 share: 4 / w, working: mins(18)),
            task("api/routes/refunds", "Refunds", depth: 2, .running, progress: TaskProgress(done: 0.25, inFlight: 0.75, estimate: 0.5), leaf: false,
                 tokens: 420_000, started: ago(now, 21), active: 2),
            task("api/routes/refunds/partial", "Partial refunds", depth: 3, .done, tokens: 120_000, started: ago(now, 21), ended: ago(now, 9),
                 share: 2 / w),
            task("api/routes/refunds/webhooks", "Refund webhooks", depth: 3, .running, progress: TaskProgress(done: 0, inFlight: 1, estimate: 0.33),
                 tokens: 150_000, started: ago(now, 12), share: 4 / w),
            task("api/routes/refunds/audit", "Audit log", depth: 3, .planned, share: 4 / w),
            task("api/routes/receipts", "Receipts", depth: 2, .running, progress: TaskProgress(done: 0.5, inFlight: 0.5, estimate: 0.5),
                 steps: TaskSteps(done: 2, total: 4), note: "Templates ported, wiring the mailer", tokens: 130_000, started: ago(now, 15), active: 1,
                 share: 4 / w, working: mins(14)),
            task("api/auth", "Keep the old session tokens working", depth: 1, .done, confirmed: false, tokens: 280_000, started: ago(now, 48),
                 ended: ago(now, 30), share: 2 / w),
            task("tests", "Cover checkout end to end", .running, progress: TaskProgress(done: 0.38, inFlight: 0.62, estimate: 0.38), importance: .critical,
                 steps: TaskSteps(done: 3, total: 8), note: "41 of 58 passing; the refund cases wait on the webhooks", tokens: 390_000,
                 started: ago(now, 18), active: 1, agents: 2, retries: 1, share: 8 / w, working: mins(16)),
            task("docs", "Update the integration guide", .planned, importance: .optional, share: 2 / w),
        ]
        return TaskRun(id: "demo-declared", title: "Move checkout to the new payments API", project: "storefront", harness: "claude-code",
                       startedAt: ago(now, 72), updatedAt: ago(now, 1), state: .running,
                       progress: TaskProgress(done: 0.62, inFlight: 0.24, estimate: 0.62), mustHaves: TaskMustHaves(done: 2, total: 3),
                       etaSeconds: 26 * 60, tokens: 2_310_000, hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(66), waitingInput: mins(4), idle: mins(2)),
                       tokensByModel: ["claude-opus-5-5": 1_900_000, "claude-haiku-5-5": 410_000], host: "com.googlecode.iterm2",
                       cwd: "/Users/demo/src/storefront")
    }

    /// Nothing declared: nine agents a session spawned, one of which spawned two more.
    public static func observedRun(now: Date) -> TaskRun {
        func agent(_ id: String, _ title: String, depth: Int = 0, _ state: TaskState, leaf: Bool = true, tokens: Int64, minutes: Double, ended: Double? = nil) -> TaskNode {
            task(id, title, depth: depth, state, declared: false, leaf: leaf, confirmed: false, tokens: tokens, started: ago(now, minutes),
                 ended: ended.map { ago(now, $0) }, active: state == .running ? 1 : 0)
        }
        let nodes = [
            agent("~agent-a1", "Survey the component library", .done, tokens: 210_000, minutes: 44, ended: 38),
            agent("~agent-a2", "Find every hard-coded colour", .running, leaf: false, tokens: 520_000, minutes: 37),
            agent("~agent-a2/~agent-b1", "Scan the web package", depth: 1, .done, tokens: 140_000, minutes: 35, ended: 24),
            agent("~agent-a2/~agent-b2", "Scan the mobile package", depth: 1, .running, tokens: 160_000, minutes: 34),
            agent("~agent-a3", "Draft the token names", .done, tokens: 90_000, minutes: 30, ended: 21),
            agent("~agent-a4", "Check contrast in dark mode", .done, tokens: 120_000, minutes: 28, ended: 16),
            agent("~agent-a5", "Check contrast in light mode", .done, tokens: 118_000, minutes: 28, ended: 15),
            agent("~agent-a6", "Write the migration notes", .done, tokens: 64_000, minutes: 14, ended: 6),
            agent("~agent-a7", "Review the token names", .done, tokens: 48_000, minutes: 12, ended: 3),
        ]
        return TaskRun(id: "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60", title: "3f9b8c1e-6a0d-4c52-9e7a-1b2c3d4e5f60", project: "design-system",
                       harness: "claude-code", startedAt: ago(now, 46), updatedAt: ago(now, 2), state: .running,
                       progress: TaskProgress(done: 0.75, inFlight: 0.25, estimate: 0.75), etaSeconds: 9 * 60, tokens: 1_470_000,
                       hasDeclaredTasks: false, nodes: nodes, time: TaskTimeSplit(working: mins(44), idle: mins(2)),
                       cwd: "/Users/demo/src/design-system")
    }

    /// An agent asked a question and is waiting for the answer.
    public static func inputRun(now: Date) -> TaskRun {
        let nodes = [
            task("inventory", "Take a snapshot", .done, evidence: "Snapshot inv-2026-11-13 taken, restore tested on staging",
                 tokens: 96_000, started: ago(now, 40), ended: ago(now, 29), agents: 1, share: 4 / 14, working: mins(11)),
            task("migrate", "Switch the queries over", .waiting, progress: TaskProgress(done: 0.2, inFlight: 0.8, estimate: 0.2), waitReason: .input,
                 waitNote: "May I drop the unused audit table?", tokens: 310_000, started: ago(now, 28), active: 1, share: 8 / 14, working: mins(22)),
            task("bench", "Compare query times", .planned, importance: .optional, share: 2 / 14),
        ]
        return TaskRun(id: "0a7c4e2b-58d1-4f39-b6a2-9e1d7c3f5b80", title: "Database upgrade", project: "inventory-service", harness: "codex",
                       startedAt: ago(now, 41), updatedAt: ago(now, 4), state: .waiting, waitReason: .input,
                       progress: TaskProgress(done: 0.40, inFlight: 0.46, estimate: 0.40), tokens: 406_000, hasDeclaredTasks: true, nodes: nodes,
                       question: TaskQuestion(text: "May I drop the unused audit table? Nothing has read it since March, and the new driver doesn't map its column types.",
                                              options: ["Drop it", "Keep it for now", "Rename it to audit_old"], task: "migrate", askedAt: ago(now, 4)),
                       time: TaskTimeSplit(working: mins(33), waitingInput: mins(4), idle: mins(1)),
                       tokensByModel: ["gpt-6-sol": 406_000], host: "com.apple.Terminal", cwd: "/Users/demo/src/inventory-service")
    }

    /// Forecast to empty the 5-hour window an hour in, pause until it resets, then finish.
    public static func timelineRun(now: Date) -> TaskRun {
        var r = declaredRun(now: now)
        r.id = "demo-timeline"
        // Tokens suggest more than the closed tasks say; the forecast is a range until more close.
        r.progress = TaskProgress(done: 0.48, inFlight: 0.38, estimate: 0.62)
        r.etaLowSeconds = mins(19)
        r.etaHighSeconds = mins(34)
        r.limitOutlook = TaskLimitOutlook(provider: .claude, pauseAt: now.addingTimeInterval(mins(30)), resumeAt: now.addingTimeInterval(mins(80)),
                                          finishAt: now.addingTimeInterval(mins(105)), tokensNeeded: 1_100_000, roomTokens: 600_000, share: 0.62)
        r.warning = "Claude 5-hour limit will likely run out first: around 2:10 PM, finish around 3:25 PM."
        return r
    }

    /// Blocked by the provider's 5-hour limit.
    public static func limitRun(now: Date) -> TaskRun {
        let nodes = [
            task("parse", "Parse the export files", .done, tokens: 180_000, started: ago(now, 90), ended: ago(now, 70), share: 0.3),
            task("dedupe", "Merge duplicate contacts", .waiting, progress: TaskProgress(done: 0, inFlight: 1, estimate: 0.45), waitReason: .limit,
                 tokens: 640_000, started: ago(now, 68), active: 1, share: 0.45),
            task("report", "Write the summary", .planned, share: 0.25),
        ]
        return TaskRun(id: "demo-limit", title: "Clean up the contacts import", project: "crm-tools", harness: "claude-code",
                       startedAt: ago(now, 92), updatedAt: ago(now, 12), state: .waiting, waitReason: .limit,
                       progress: TaskProgress(done: 0.45, inFlight: 0.3, estimate: 0.45), tokens: 820_000,
                       warning: "Claude 5-hour limit reached, back today 10:48 AM.", hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(70), waitingLimit: mins(12)))
    }

    /// The plan comes from the session's own todo list, not from the agent.
    public static func mirroredRun(now: Date) -> TaskRun {
        let titles = ["Read the failing test", "Find where the cache key is built", "Include the locale in the key", "Add a regression test",
                      "Run the whole suite", "Update the changelog", "Open the pull request"]
        let states: [TaskState] = [.done, .done, .done, .running, .planned, .planned, .planned]
        let nodes = zip(titles, states).enumerated().map { i, p in
            task("plan-\(i)", p.0, p.1, declared: false, started: p.1 == .planned ? nil : ago(now, 30 - Double(i) * 6),
                 ended: p.1 == .done ? ago(now, 26 - Double(i) * 6) : nil, share: 1.0 / 7)
        }
        return TaskRun(id: "5c2e8a91-3b7d-4f60-a1c9-d84e6b2f0a17", title: "Fix the stale prices in the cart", project: "storefront", harness: "claude-code",
                       startedAt: ago(now, 31), updatedAt: ago(now, 1), state: .running,
                       progress: TaskProgress(done: 3.0 / 7, inFlight: 1.0 / 7, estimate: 0.5), etaSeconds: mins(14), tokens: 640_000, hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(29), idle: mins(1)), mirrored: true, cwd: "/Users/demo/src/storefront")
    }

    /// Running, but nothing has moved for a while.
    public static func quietRun(now: Date) -> TaskRun {
        let nodes = [
            task("index", "Rebuild the search index", .running, progress: TaskProgress(done: 0, inFlight: 1, estimate: 0.4), tokens: 220_000,
                 started: ago(now, 40), active: 1, stale: true, last: ago(now, 18), share: 0.6),
            task("verify", "Spot-check the results", .planned, share: 0.4),
        ]
        return TaskRun(id: "demo-quiet", title: "Reindex the help centre", project: "support-site", harness: "codex",
                       startedAt: ago(now, 42), updatedAt: ago(now, 18), state: .running, stale: true,
                       progress: TaskProgress(done: 0, inFlight: 0.6, estimate: 0.24), tokens: 220_000, hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(22), idle: mins(18)))
    }

    /// The orchestrator ended its turn with tasks left.
    public static func stoppedRun(now: Date) -> TaskRun {
        let nodes = [
            task("lint", "Fix the lint errors", .done, tokens: 75_000, started: ago(now, 120), ended: ago(now, 101), share: 0.25),
            task("types", "Tighten the types", .done, tokens: 160_000, started: ago(now, 100), ended: ago(now, 64), share: 0.25),
            task("split", "Split the settings screen", .planned, share: 0.35),
            task("snapshots", "Refresh the snapshots", .planned, importance: .optional, share: 0.15),
        ]
        return TaskRun(id: "demo-stopped", title: "Tidy the settings module", project: "mobile-app", harness: "claude-code",
                       startedAt: ago(now, 122), updatedAt: ago(now, 58), state: .stopped,
                       progress: TaskProgress(done: 0.5, inFlight: 0, estimate: 0.5), tokens: 235_000, hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(56), idle: mins(8)), cwd: "/Users/demo/src/mobile-app")
    }

    /// Finished this morning; the optional benchmark failed.
    public static func finishedRun(now: Date) -> TaskRun {
        let nodes = [
            task("upgrade", "Upgrade the image library", .done, evidence: "libvips 8.17, all decoders pass", tokens: 140_000,
                 started: ago(now, 230), ended: ago(now, 205), agents: 1),
            task("thumbs", "Regenerate the thumbnails", .done, tokens: 96_000, started: ago(now, 204), ended: ago(now, 188), agents: 2, retries: 1),
            task("cdn", "Purge the CDN cache", .done, tokens: 22_000, started: ago(now, 187), ended: ago(now, 184)),
            task("resize", "Resize on upload", .done, tokens: 30_000, started: ago(now, 183), ended: ago(now, 178)),
            task("bench", "Benchmark decode times", .failed, importance: .optional,
                 failure: "The benchmark host was unreachable (connection refused on port 9100), so no timings were taken",
                 tokens: 8_000, started: ago(now, 183), ended: ago(now, 176), agents: 1, working: mins(7)),
        ]
        return TaskRun(id: "demo-finished", title: "Speed up image uploads", project: "photo-site", harness: "codex",
                       startedAt: ago(now, 278), updatedAt: ago(now, 176), state: .done, progress: .complete, tokens: 296_000,
                       scopeChanges: 2, hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(70), waitingInput: mins(22), waitingLimit: mins(10)),
                       tokensByModel: ["gpt-6-sol": 296_000])
    }

    /// Finished last night: a critical task failed.
    public static func failedRun(now: Date) -> TaskRun {
        let nodes = [
            task("build", "Build the release", .done, tokens: 60_000, started: ago(now, 700), ended: ago(now, 690)),
            task("sign", "Sign and notarize", .failed, importance: .critical, failure: "The signing certificate has expired",
                 tokens: 41_000, started: ago(now, 689), ended: ago(now, 684), agents: 1, working: mins(5)),
            task("publish", "Publish the release notes", .cancelled, failure: "Nothing to publish without a signed build"),
        ]
        return TaskRun(id: "demo-failed", title: "Ship the 2.3 release", project: "desktop-client", harness: "claude-code",
                       startedAt: ago(now, 702), updatedAt: ago(now, 684), state: .failed,
                       progress: TaskProgress(done: 0.5, inFlight: 0, estimate: 0.5), mustHaves: TaskMustHaves(done: 0, total: 1),
                       tokens: 101_000, hasDeclaredTasks: true, nodes: nodes, time: TaskTimeSplit(working: mins(16), idle: mins(2)),
                       tokensByModel: ["claude-sonnet-5-5": 101_000])
    }

    /// Finished: one approach failed and the agent took another way to the same end. Done, not
    /// "finished with failures".
    public static func replacedRun(now: Date) -> TaskRun {
        var root = task("root", "Root access + root perf tuning", .failed,
                        failure: "Locked user build: OEM-signed OTA keys, AVB locked. Doing non-root shell-level tuning instead.",
                        tokens: 8_080, started: ago(now, 250), ended: ago(now, 248), working: mins(2))
        root.replacedBy = "tune"; root.counted = false
        let nodes = [
            task("app", "Build the launcher app", .done, importance: .critical, evidence: "APK built and signed", tokens: 41_300,
                 started: ago(now, 300), ended: ago(now, 270), agents: 1, working: mins(25)),
            task("deploy", "Install and test on the box", .done, importance: .critical, evidence: "Silent update 1.11.2 → 1.12.1 verified",
                 tokens: 44_000, started: ago(now, 268), ended: ago(now, 252), working: mins(15)),
            root,
            task("tune", "Non-root perf tuning", .done, evidence: "14 apps disabled, animations 0.5×", tokens: 14_500,
                 started: ago(now, 248), ended: ago(now, 244), working: mins(4)),
        ]
        return TaskRun(id: "demo-replaced", title: "Dor Box: auto-updater + max performance", project: "box-tools", harness: "claude-code",
                       startedAt: ago(now, 300), updatedAt: ago(now, 244), state: .done, progress: .complete,
                       mustHaves: TaskMustHaves(done: 2, total: 2), tokens: 598_000, scopeChanges: 4, hasDeclaredTasks: true, nodes: nodes,
                       time: TaskTimeSplit(working: mins(50), waitingInput: mins(2), idle: mins(4)), tokensByModel: ["claude-opus-5-5": 598_000])
    }

    /// Given up on from the card after it stopped half way.
    public static func abandonedRun(now: Date) -> TaskRun {
        let nodes = [
            task("survey", "Survey the old endpoints", .done, tokens: 88_000, started: ago(now, 300), ended: ago(now, 280)),
            task("port", "Port them to the new router", .cancelled, failure: "Abandoned", tokens: 140_000, started: ago(now, 279), ended: ago(now, 200)),
            task("delete", "Delete the old router", .cancelled, failure: "Abandoned"),
        ]
        return TaskRun(id: "demo-abandoned", title: "Retire the v1 router", project: "api-gateway", harness: "claude-code",
                       startedAt: ago(now, 301), updatedAt: ago(now, 150), state: .stopped,
                       progress: TaskProgress(done: 0.33, inFlight: 0, estimate: 0.33), tokens: 228_000, hasDeclaredTasks: true, nodes: nodes,
                       abandoned: true, time: TaskTimeSplit(working: mins(98), idle: mins(52)), tokensByModel: ["claude-opus-5-5": 228_000])
    }

    /// A short mirrored run that finished cleanly.
    public static func mirroredFinishedRun(now: Date) -> TaskRun {
        let nodes = (0..<4).map { i in
            task("plan-\(i)", ["Reproduce the crash", "Guard the empty list", "Add a test", "Run the suite"][i], .done, declared: false,
                 started: ago(now, 410 - Double(i) * 5), ended: ago(now, 406 - Double(i) * 5))
        }
        return TaskRun(id: "demo-mirrored-done", title: "Fix the empty-cart crash", project: "mobile-app", harness: "codex",
                       startedAt: ago(now, 412), updatedAt: ago(now, 390), state: .done, progress: .complete, tokens: 84_000,
                       hasDeclaredTasks: true, nodes: nodes, time: TaskTimeSplit(working: mins(22)), tokensByModel: ["gpt-6-sol": 84_000], mirrored: true)
    }

    /// A quick one from early this morning.
    public static func shortRun(now: Date) -> TaskRun {
        let nodes = [task("bump", "Bump the dependencies", .done, started: ago(now, 600), ended: ago(now, 592)),
                     task("test", "Run the tests", .done, started: ago(now, 592), ended: ago(now, 588))]
        return TaskRun(id: "demo-short", title: "Weekly dependency bump", project: "photo-site", harness: "claude-code",
                       startedAt: ago(now, 601), updatedAt: ago(now, 588), state: .done, progress: .complete, tokens: 41_000,
                       hasDeclaredTasks: true, nodes: nodes, time: TaskTimeSplit(working: mins(13)), tokensByModel: ["claude-haiku-5-5": 41_000])
    }

    /// Two weeks of receipts for Activity's "Recent runs".
    public static func recentRunRecords(now: Date) -> [RunRecord] {
        var out = [finishedRun(now: now), failedRun(now: now), abandonedRun(now: now), mirroredFinishedRun(now: now), shortRun(now: now)].map(RunRecord.init)
        let older: [(String, Double, Double, TaskRunState, Int64)] = [
            ("Move search to the new index", 26, 95, .done, 1_240_000), ("Audit the billing exports", 50, 140, .partial, 610_000),
            ("Tidy the onboarding copy", 75, 25, .done, 90_000), ("Port the settings screen", 130, 210, .done, 2_050_000),
        ]
        for (i, o) in older.enumerated() {
            let end = ago(now, o.1 * 60)
            out.append(RunRecord(id: "demo-old-\(i)", title: o.0, harness: "claude-code", startedAt: end.addingTimeInterval(-o.2 * 60), endedAt: end,
                                 state: o.3, tokens: o.4, tokensByModel: ["claude-opus-5-5": o.4], tasks: "", tasksNote: ""))
        }
        return out
    }

    /// A session that ran for four days: 1,004 agents (929 done, 24 failed, 51 running), mostly
    /// under a few long-lived coordinators, compacted the way the feed writer compacts it.
    public static func largeRun(now: Date) -> TaskRun {
        var nodes: [TaskNode] = []
        var seed = 7
        func next() -> Int { seed = (seed * 16807) % 2147483647; return seed }
        let subjects = ["Triage", "Reproduce", "Patch", "Review", "Test", "Document", "Benchmark", "Refactor"]
        let objects = ["the login flow", "the sync queue", "the image cache", "the billing export", "the search index",
                       "the settings page", "the upload retry", "the audit log", "the push service", "the report builder"]
        var failed = 0
        for c in 0..<4 {
            let coord = "~agent-c\(c)"
            nodes.append(task(coord, "Coordinate batch \(c + 1) of the backlog", .running, declared: false, leaf: false, confirmed: false,
                              tokens: 4_000_000, started: ago(now, 5760 - Double(c) * 60), active: 1, last: ago(now, 1)))
            for i in 0..<250 {
                let k = c * 250 + i
                let title = subjects[next() % subjects.count] + " " + objects[next() % objects.count]
                // The newest 47 still run (with the four coordinators, 51); 24 failed along the way.
                let state: TaskState
                if k >= 1000 - 47 { state = .running }
                else if failed < 24 && k % 39 == 13 { state = .failed; failed += 1 }
                else { state = .done }
                // Spread over four days, newest last.
                let start = 5700 - Double(k) * 5.6
                nodes.append(task("\(coord)/~agent-\(k)", title, depth: 1, state, declared: false,
                                  failure: state == .failed ? "Exited with an error" : nil, confirmed: false, tokens: Int64(40_000 + next() % 160_000),
                                  started: ago(now, start), ended: state == .running ? nil : ago(now, start - 4), active: state == .running ? 1 : 0))
            }
        }
        let run = TaskRun(id: "8d2f4a6b-91c3-4e7d-a5b0-c4d3e2f1a0b9", title: "8d2f4a6b-91c3-4e7d-a5b0-c4d3e2f1a0b9", project: "support-backlog",
                          harness: "claude-code", startedAt: ago(now, 5762), updatedAt: ago(now, 1), state: .running,
                          progress: TaskProgress(done: 0.93, inFlight: 0.05, estimate: 0.94), tokens: 118_400_000, hasDeclaredTasks: false, nodes: nodes,
                          time: TaskTimeSplit(working: mins(4100), waitingInput: mins(300), idle: mins(1300)))
        return TaskCompaction.compact(run, now: now)
    }
}
