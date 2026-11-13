import Foundation
import HeadroomKit
import HeadroomPresent

extension DemoRecords {
    /// The Mac's run fixtures with what the second pass on task tracking adds filled in, as the
    /// Mac's fold would fill it: where the time went, a forecast range, how a run sits against its
    /// window, tokens by model, task shares, and the question a waiting run asks. Runs this doesn't
    /// know pass through unchanged.
    public static func detailed(_ r: TaskRun, now: Date) -> TaskRun {
        var r = r
        func min(_ m: Double) -> Double { m * 60 }
        func at(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }
        switch r.id {
        case "demo-declared":
            r.time = TaskTimeSplit(working: min(64), waitingInput: min(6), idle: min(2))
            r.etaLowSeconds = min(20); r.etaHighSeconds = min(35)
            r.limitOutlook = TaskLimitOutlook(provider: .claude, pauseAt: at(30), resumeAt: at(80), finishAt: at(105), tokensNeeded: 1_100_000,
                                              roomTokens: 600_000, share: 0.62)
            r.tokensByModel = ["claude-opus-5-5": 1_900_000, "claude-haiku-5-5": 410_000]
            let shares: [String: Double] = ["schema": 0.16, "api/client": 0.08, "api/routes/cart": 0.1, "api/routes/refunds/partial": 0.05,
                                            "api/routes/refunds/webhooks": 0.07, "api/routes/refunds/audit": 0.04, "api/routes/receipts": 0.08,
                                            "api/auth": 0.08, "tests": 0.24, "docs": 0.1]
            r.nodes = r.nodes.map { n in var n = n; n.share = shares[n.id] ?? 0; return n }
        case "demo-input":
            r.time = TaskTimeSplit(working: min(33), waitingInput: min(4), idle: min(4))
            r.question = TaskQuestion(text: "May I drop the unused audit table? Nothing has read it since March.", options: ["Drop it", "Keep it for now"],
                                      task: "migrate", askedAt: at(-4))
        case "demo-limit":
            r.time = TaskTimeSplit(working: min(70), waitingLimit: min(12), idle: min(10))
            r.limitOutlook = TaskLimitOutlook(provider: .claude, pauseAt: at(-12), resumeAt: at(36), finishAt: at(70), share: 0.48)
        case "demo-finished":
            r.time = TaskTimeSplit(working: min(40), waitingInput: min(9), waitingLimit: min(4), idle: min(3))
            r.tokensByModel = ["gpt-6-sol": 296_000]
            r.scopeChanges = 2
        case "demo-failed":
            r.time = TaskTimeSplit(working: min(14), idle: min(4))
            r.tokensByModel = ["claude-sonnet-5-5": 101_000]
        default:
            if !r.hasDeclaredTasks, !r.state.isTerminal { r.time = TaskTimeSplit(working: r.updatedAt.timeIntervalSince(r.startedAt) * 0.9) }
        }
        return r
    }
}
