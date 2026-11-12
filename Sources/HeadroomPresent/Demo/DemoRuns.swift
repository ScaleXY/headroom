import Foundation
import HeadroomKit

/// Agent-run fixtures for the Runs tab, the menu bar indicator and Settings (`--render runs`).
/// Every title is an invented, generic example.
extension Demo {
    public struct RunScenario {
        public var name: String
        public var runs: [TaskRun]
        public var expanded: Set<String>
        public var note: String

        public init(name: String, runs: [TaskRun], expanded: Set<String> = [], note: String) {
            self.name = name; self.runs = runs; self.expanded = expanded; self.note = note
        }
    }

    public static func runScenarios(now: Date) -> [RunScenario] {
        let declared = declaredRun(now: now), observed = observedRun(now: now)
        return [
            RunScenario(name: "declared", runs: [declared], note: "A declared plan in progress, three levels deep"),
            RunScenario(name: "declared-expanded", runs: [declared], expanded: [declared.id], note: "The same run with its finished rows shown"),
            RunScenario(name: "observed", runs: [observed], note: "Nothing declared: the agents Headroom saw spawned"),
            RunScenario(name: "input", runs: [inputRun(now: now)], note: "An agent is waiting on an answer"),
            RunScenario(name: "limit", runs: [limitRun(now: now)], note: "Waiting on the 5-hour limit, with the warning"),
            RunScenario(name: "stopped", runs: [stoppedRun(now: now)], note: "The orchestrator stopped with work left"),
            RunScenario(name: "finished", runs: [finishedRun(now: now)], note: "Done, with a failed optional task"),
            RunScenario(name: "large", runs: [largeRun(now: now)], note: "A session that ran for days: 1,004 agents"),
            RunScenario(name: "mixed", runs: [inputRun(now: now), declared, observed, finishedRun(now: now), failedRun(now: now)].sortedForDisplay(),
                        note: "Live runs, then the last day's finished ones"),
            RunScenario(name: "empty", runs: [], note: "Nothing tracked yet"),
        ]
    }

    private static func ago(_ now: Date, _ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private static func task(_ id: String, _ title: String, depth: Int = 0, _ state: TaskState, progress: TaskProgress? = nil,
                             importance: TaskImportance = .normal, declared: Bool = true, leaf: Bool = true, steps: TaskSteps? = nil,
                             note: String? = nil, waitReason: TaskWaitReason? = nil, waitNote: String? = nil, failure: String? = nil,
                             confirmed: Bool = true, tokens: Int64 = 0, started: Date? = nil, ended: Date? = nil, active: Int = 0,
                             stale: Bool = false, last: Date? = nil) -> TaskNode {
        let parent = depth == 0 ? nil : id.split(separator: "/").dropLast().joined(separator: "/")
        let p = progress ?? (state == .done ? .complete : state == .running || state == .waiting ? TaskProgress(done: 0, inFlight: 1, estimate: 0.3) : .zero)
        return TaskNode(id: id, title: title, parent: parent, depth: depth, state: state, waitReason: waitReason, stale: stale, progress: p,
                        importance: importance, declared: declared, confirmed: confirmed, leaf: leaf,
                        counted: !(importance == .optional && state == .failed) && state != .skipped, steps: steps, note: note,
                        waitNote: waitNote, failure: failure, attempts: TaskAttemptsSummary(count: active, active: active), tokens: tokens,
                        startedAt: started, endedAt: ended, lastActivityAt: last ?? ended ?? started)
    }

    /// "Move checkout to the new payments API": a plan with a three-level tree, half done.
    public static func declaredRun(now: Date) -> TaskRun {
        let nodes = [
            task("schema", "Migrate the orders schema", .done, importance: .critical, tokens: 412_000, started: ago(now, 70), ended: ago(now, 52)),
            task("api", "Port the checkout endpoints", .running, progress: TaskProgress(done: 0.55, inFlight: 0.45, estimate: 0.7), leaf: false,
                 tokens: 1_380_000, started: ago(now, 50)),
            task("api/client", "Generate the payments client", depth: 1, .done, tokens: 240_000, started: ago(now, 50), ended: ago(now, 41)),
            task("api/routes", "Rewrite the routes", depth: 1, .running, progress: TaskProgress(done: 0.4, inFlight: 0.6, estimate: 0.6),
                 leaf: false, tokens: 860_000, started: ago(now, 40)),
            task("api/routes/cart", "Cart and totals", depth: 2, .done, tokens: 310_000, started: ago(now, 40), ended: ago(now, 22)),
            task("api/routes/refunds", "Refunds", depth: 2, .running, progress: TaskProgress(done: 0.25, inFlight: 0.75, estimate: 0.5), leaf: false,
                 tokens: 420_000, started: ago(now, 21), active: 2),
            task("api/routes/refunds/partial", "Partial refunds", depth: 3, .done, tokens: 120_000, started: ago(now, 21), ended: ago(now, 9)),
            task("api/routes/refunds/webhooks", "Refund webhooks", depth: 3, .running, tokens: 150_000, started: ago(now, 12)),
            task("api/routes/refunds/audit", "Audit log", depth: 3, .planned),
            task("api/routes/receipts", "Receipts", depth: 2, .running, steps: TaskSteps(done: 2, total: 4), note: "Templates ported, wiring the mailer",
                 tokens: 130_000, started: ago(now, 15), active: 1),
            task("api/auth", "Keep the old session tokens working", depth: 1, .done, confirmed: false, tokens: 280_000, started: ago(now, 48), ended: ago(now, 30)),
            task("tests", "Cover checkout end to end", .running, importance: .critical, steps: TaskSteps(done: 3, total: 8), note: "41 of 58 passing",
                 tokens: 390_000, started: ago(now, 18), active: 1),
            task("docs", "Update the integration guide", .planned, importance: .optional),
        ]
        return TaskRun(id: "demo-declared", title: "Move checkout to the new payments API", project: "storefront", harness: "claude-code",
                       startedAt: ago(now, 72), updatedAt: ago(now, 1), state: .running,
                       progress: TaskProgress(done: 0.46, inFlight: 0.31, estimate: 0.58), mustHaves: TaskMustHaves(done: 1, total: 2),
                       etaSeconds: 26 * 60, tokens: 2_310_000, hasDeclaredTasks: true, nodes: nodes)
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
                       hasDeclaredTasks: false, nodes: nodes)
    }

    /// An agent asked a question and is waiting for the answer.
    public static func inputRun(now: Date) -> TaskRun {
        let nodes = [
            task("inventory", "List the tables still on the old driver", .done, tokens: 96_000, started: ago(now, 40), ended: ago(now, 31)),
            task("migrate", "Switch the queries over", .waiting, progress: TaskProgress(done: 0.5, inFlight: 0.5, estimate: 0.6), waitReason: .input,
                 waitNote: "Asks whether it may drop the unused audit table", tokens: 310_000, started: ago(now, 30), active: 1),
            task("bench", "Compare query times", .planned, importance: .optional),
        ]
        return TaskRun(id: "demo-input", title: "Database upgrade", project: "inventory-service", harness: "codex",
                       startedAt: ago(now, 41), updatedAt: ago(now, 4), state: .waiting, waitReason: .input,
                       progress: TaskProgress(done: 0.38, inFlight: 0.31, estimate: 0.44), tokens: 406_000, hasDeclaredTasks: true, nodes: nodes)
    }

    /// Blocked by the provider's 5-hour limit.
    public static func limitRun(now: Date) -> TaskRun {
        let nodes = [
            task("parse", "Parse the export files", .done, tokens: 180_000, started: ago(now, 90), ended: ago(now, 70)),
            task("dedupe", "Merge duplicate contacts", .waiting, waitReason: .limit, tokens: 640_000, started: ago(now, 68), active: 1),
            task("report", "Write the summary", .planned),
        ]
        return TaskRun(id: "demo-limit", title: "Clean up the contacts import", project: "crm-tools", harness: "claude-code",
                       startedAt: ago(now, 92), updatedAt: ago(now, 12), state: .waiting, waitReason: .limit,
                       progress: TaskProgress(done: 0.33, inFlight: 0.33, estimate: 0.5), tokens: 820_000,
                       warning: "Claude 5-hour limit reached, back today 10:48 AM.", hasDeclaredTasks: true, nodes: nodes)
    }

    /// The orchestrator ended its turn with tasks left.
    public static func stoppedRun(now: Date) -> TaskRun {
        let nodes = [
            task("lint", "Fix the lint errors", .done, tokens: 75_000, started: ago(now, 120), ended: ago(now, 101)),
            task("types", "Tighten the types", .done, tokens: 160_000, started: ago(now, 100), ended: ago(now, 64)),
            task("split", "Split the settings screen", .planned),
            task("snapshots", "Refresh the snapshots", .planned, importance: .optional),
        ]
        return TaskRun(id: "demo-stopped", title: "Tidy the settings module", project: "mobile-app", harness: "claude-code",
                       startedAt: ago(now, 122), updatedAt: ago(now, 58), state: .stopped,
                       progress: TaskProgress(done: 0.5, inFlight: 0, estimate: 0.5), tokens: 235_000, hasDeclaredTasks: true, nodes: nodes)
    }

    /// Finished this morning; the optional benchmark failed.
    public static func finishedRun(now: Date) -> TaskRun {
        let nodes = [
            task("upgrade", "Upgrade the image library", .done, tokens: 140_000, started: ago(now, 230), ended: ago(now, 205)),
            task("thumbs", "Regenerate the thumbnails", .done, tokens: 96_000, started: ago(now, 204), ended: ago(now, 188)),
            task("cdn", "Purge the CDN cache", .done, tokens: 22_000, started: ago(now, 187), ended: ago(now, 184)),
            task("bench", "Benchmark decode times", .failed, importance: .optional, failure: "The benchmark host was unreachable",
                 tokens: 38_000, started: ago(now, 183), ended: ago(now, 176)),
        ]
        return TaskRun(id: "demo-finished", title: "Speed up image uploads", project: "photo-site", harness: "codex",
                       startedAt: ago(now, 232), updatedAt: ago(now, 176), state: .done, progress: .complete, tokens: 296_000,
                       hasDeclaredTasks: true, nodes: nodes)
    }

    /// Finished last night: a critical task failed.
    public static func failedRun(now: Date) -> TaskRun {
        let nodes = [
            task("build", "Build the release", .done, tokens: 60_000, started: ago(now, 700), ended: ago(now, 690)),
            task("sign", "Sign and notarize", .failed, importance: .critical, failure: "The signing certificate has expired",
                 tokens: 41_000, started: ago(now, 689), ended: ago(now, 684)),
            task("publish", "Publish the release notes", .cancelled),
        ]
        return TaskRun(id: "demo-failed", title: "Ship the 2.3 release", project: "desktop-client", harness: "claude-code",
                       startedAt: ago(now, 702), updatedAt: ago(now, 684), state: .failed,
                       progress: TaskProgress(done: 0.5, inFlight: 0, estimate: 0.5), mustHaves: TaskMustHaves(done: 0, total: 1),
                       tokens: 101_000, hasDeclaredTasks: true, nodes: nodes)
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
                          progress: TaskProgress(done: 0.93, inFlight: 0.05, estimate: 0.94), tokens: 118_400_000, hasDeclaredTasks: false, nodes: nodes)
        return TaskCompaction.compact(run, now: now)
    }
}
