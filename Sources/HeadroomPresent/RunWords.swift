import Foundation
import HeadroomKit

/// Every phrase a run's state is called by, in one place, so the Mac, its notifications, the
/// iPhone, the Live Activity and the Watch say the same thing. Surfaces never spell these out.
public enum RunWords {
    // Run and task states.
    public static let running = "Running"
    public static let needsInput = "Needs your input"
    public static let waitingOnTask = "Waiting on another task"
    public static let stopped = "Stopped with work left"
    /// A group with some children finished and the rest not started.
    public static let paused = "Paused with work left"
    public static let done = "Done"
    public static let partial = "Finished with failures"
    public static let failed = "Failed"
    public static let cancelled = "Cancelled"
    public static let skipped = "Skipped"
    public static let abandoned = "Abandoned"
    public static let planned = "Not started"

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
    public static func alertStopped(_ run: String) -> String { "\(run) stopped with work left" }
    public static func alertQuiet(_ run: String) -> String { "\(run) went quiet" }
    public static func alertCriticalFailed(_ run: String) -> String { "\(run): a critical task failed" }

    /// The run's state in plain words. `limitWarning` names the limit for a run waiting on one.
    public static func state(_ s: TaskRunState, waitReason: TaskWaitReason?, abandoned: Bool = false, limitWarning: String? = nil) -> String {
        if abandoned { return Self.abandoned }
        switch s {
        case .running: return running
        case .waiting:
            switch waitReason ?? .dependency {
            case .input: return needsInput
            case .limit: return waitingOnLimit(limitWarning)
            case .dependency: return waitingOnTask
            }
        case .stopped: return stopped
        case .done: return done
        case .partial: return partial
        case .failed: return failed
        }
    }
}
