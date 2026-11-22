import Foundation
import HeadroomKit

/// Every phrase a run's state is called by, in one place, so the Mac, its notifications, the
/// iPhone, the Live Activity and the Watch say the same thing. Surfaces never spell these out.
public enum RunWords {
    // Run and task states.
    public static let running = "Running"
    public static let needsInput = "Needs your input"
    /// A run that waits on you without saying what it asked.
    public static let waitingForAnswer = "An agent is waiting for your answer."
    public static let waitingOnTask = "Waiting on another task"
    /// The agent ended its turn with work open and the session is still there. Not a fault.
    public static let yourTurn = "Your turn"
    /// "Your turn · 8m": how long ago the turn ended.
    public static func yourTurn(since: String) -> String { "\(yourTurn) · \(since)" }
    /// The session ended (or went quiet for good) with work open: settled. "Left at 95%".
    public static func left(at percent: Int?) -> String { percent.map { "Left at \($0)%" } ?? "Left" }
    public static let mustHavesDone = "must-haves done"
    /// A person closed the run (`run.abandon` on disk): neutral, no blame.
    public static let closed = "Closed"
    public static let close = "Close"
    /// A task only a person can do (`task wait --for you`).
    public static let yours = "Yours"
    public static let yoursNote = "Only you can do this one"
    /// "1 for you": open tasks only the person can do.
    public static func forYou(_ n: Int) -> String { "\(n) for you" }
    /// A group with some children finished and the rest not started.
    public static let paused = "Paused with work left"
    public static let done = "Done"
    public static let partial = "Finished with failures"
    public static let failed = "Failed"
    public static let cancelled = "Cancelled"
    public static let skipped = "Skipped"
    public static let planned = "Not started"
    /// A failed approach another task took over from ("Replaced by Non-root perf tuning").
    public static func replaced(by title: String) -> String { "Replaced by \(title)" }

    /// An agent or task with no activity for a while ("Quiet for 18m").
    public static func quiet(_ duration: String) -> String { "Quiet for \(duration)" }
    /// A Mac that stopped syncing ("Mac last seen 2h ago"): never called "quiet".
    public static func macLastSeen(_ ago: String) -> String { "Mac last seen \(ago) ago" }

    /// "Waiting on the 5-hour limit", from `TaskLimits`' warning, which names the limit.
    public static func waitingOnLimit(_ warning: String?) -> String {
        let w = warning ?? ""
        if w.contains("weekly") { return "Waiting on the weekly limit" }
        if w.contains("outage") { return "Waiting out an outage" }
        if w.contains("5-hour") || w.isEmpty { return "Waiting on the 5-hour limit" }
        return "Waiting on a usage limit"
    }

    // Notifications: "<run> needs your input", "<run> finished", …
    public static func alertNeedsInput(_ run: String) -> String { "\(run) needs your input" }
    public static func alertFinished(_ run: String) -> String { "\(run) finished" }
    public static func alertPartial(_ run: String) -> String { "\(run) finished with failures" }
    public static func alertFailed(_ run: String) -> String { "\(run) failed" }
    /// A turn that did real work ended: "Storefront finished its turn after 24m".
    public static func alertTurnEnded(_ run: String, after duration: String) -> String { "\(run) finished its turn after \(duration)" }
    public static func alertQuiet(_ run: String) -> String { "\(run) went quiet" }
    public static func alertCriticalFailed(_ run: String) -> String { "\(run): a critical task failed" }

    // The menu bar, where room is short: "quiet 18m", "2 need you".
    public static func quietShort(_ duration: String) -> String { "quiet \(duration)" }
    public static func needYou(_ count: Int) -> String { "\(count) need you" }

    // Spoken (VoiceOver) forms for the menu bar.
    public static let spokenOneNeedsInput = "A run needs your input."
    public static func spokenNeedInput(_ count: Int) -> String { count == 1 ? spokenOneNeedsInput : "\(count) runs need your input." }
    public static func spokenLive(_ count: Int) -> String { "\(count) runs going." }

    // Section heads and totals on the Runs tab.
    public static let needsYouSection = "Needs you"
    public static let workingSection = "Working"
    public static let today = "Today"
    public static let yesterday = "Yesterday"
    /// The day's receipt when nothing is running.
    public static let nothingRunning = "Nothing running · today so far"
    /// "3 short sessions · 12m": sessions too small to list one by one.
    public static func shortSessions(_ n: Int) -> String { n == 1 ? "1 short session" : "\(n) short sessions" }
    /// "4 runs", "1 run".
    public static func runs(_ n: Int) -> String { n == 1 ? "1 run" : "\(n) runs" }
    /// "1h 26m working": time worked, which is what a run's time means everywhere but its own page.
    public static func working(_ duration: String) -> String { "\(duration) working" }

    /// Who is asking, at the top of a question: "Switch the queries over is asking".
    public static func asking(_ task: String?) -> String { task.map { "\($0) is asking" } ?? "The agent is asking" }
    /// A plan read from the harness's own list (`plan.mirror`), not declared by the agent.
    public static let fromSessionPlan = "from the session's plan"

    /// The run's state in plain words. `limitWarning` names the limit for a run waiting on one;
    /// `left` and `percent` say a stopped run settled, and how far it got.
    public static func state(_ s: TaskRunState, waitReason: TaskWaitReason?, abandoned: Bool = false, limitWarning: String? = nil,
                             left: Bool = false, percent: Int? = nil) -> String {
        if abandoned { return closed }
        switch s {
        case .running: return running
        case .waiting:
            switch waitReason ?? .dependency {
            case .input: return needsInput
            case .limit: return waitingOnLimit(limitWarning)
            case .dependency: return waitingOnTask
            case .you: return yourTurn
            }
        case .stopped: return left ? Self.left(at: percent) : yourTurn
        case .done: return done
        case .partial: return partial
        case .failed: return failed
        }
    }
}
