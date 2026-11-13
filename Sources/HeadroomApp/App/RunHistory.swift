import Foundation
import HeadroomKit

/// Receipts of finished runs, kept after their event files are pruned, for the Activity tab's
/// recent runs. Contract stub: the Runs-tab workstream implements it; `TaskTracker` calls `record`
/// after every fold.
@MainActor
final class RunHistory {
    static let shared = RunHistory()

    /// Every fold's runs; keeps a small summary of each that finished.
    func record(_ runs: [TaskRun]) {}
}
