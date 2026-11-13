import AppKit
import HeadroomKit

/// What a person can do to a run from the Mac: bring its session forward, copy a resume command,
/// hide it, give up on it. Contract stub: the services workstream implements these; the Runs tab
/// (and the notification actions) call them.
@MainActor
enum RunActions {
    /// Brings the app hosting the run's session to the front (its terminal, editor or the desktop app).
    static func openSession(_ run: TaskRun) {}

    /// `cd '<folder>' && claude --resume <id>` (or `codex resume <id>`), when the run can be resumed.
    static func resumeCommand(_ run: TaskRun) -> String? { nil }

    static func copyResumeCommand(_ run: TaskRun) {}

    /// Writes `run.hide` to the run's journal as the user.
    static func hide(_ runID: String, hidden: Bool = true) {}

    /// Writes `run.abandon` to the run's journal as the user.
    static func abandon(_ runID: String) {}
}
