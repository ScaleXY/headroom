#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI

/// The agent-run Live Activity: one at a time, for the most pressing live run on any Mac.
///
/// ActivityKit lets an app start an activity only from the foreground (a background start needs
/// push-to-start, which needs a server), so it starts when Headroom is opened with a run live.
/// Once started, every rebuild (in the foreground, or when a sync wakes the app) updates it and
/// ends it when the run finishes or its Mac goes quiet. Between wakes it can't change; the stale
/// date greys it out when no word has come for a while.
@MainActor
public final class RunActivityController {
    /// Without an update for this long, iOS shows the activity as stale. The Mac publishes progress
    /// at least every 5 minutes and a heartbeat every 10 while a run is live.
    static let staleAfter: TimeInterval = 20 * 60
    /// A finished run's activity lingers this long on the Lock Screen.
    static let lingerAfterEnd: TimeInterval = 15 * 60

    public init() {}

    private var active: [Activity<RunActivityAttributes>] { Activity<RunActivityAttributes>.activities.filter { $0.activityState == .active } }

    /// Brings the activity up to date with `runs` (most pressing first). `canStart` while in the
    /// foreground: the only time a new activity may be requested, or one swapped for a more
    /// pressing run.
    public func sync(_ runs: [RunDigest], enabled: Bool, canStart: Bool, now: Date = Date()) {
        let presenter = RunsPresenter(now: now, calendar: .current, locale: .current)
        let target = enabled ? runs.first(where: \.isLive) : nil
        var kept = false
        for activity in active {
            let id = activity.attributes.runID, activityID = activity.id
            let run = runs.first { $0.id == id }
            guard let run, run.isLive, enabled else {
                // Finished: show how it ended for a while. Gone or its Mac quiet: say so, then go.
                let final = run.map { RunActivityState.from($0, presenter: presenter) }
                Task { await Self.end(activityID, content: final.map { ActivityContent(state: $0, staleDate: nil) },
                                      policy: run?.state.isTerminal == true ? .after(now.addingTimeInterval(Self.lingerAfterEnd)) : .immediate) }
                continue
            }
            if canStart, let target, target.id != id || kept {
                Task { await Self.end(activityID, content: nil, policy: .immediate) }
                continue
            }
            kept = true
            let content = content(RunActivityState.from(run, presenter: presenter), run: run, now: now)
            Task { await Self.update(activityID, content: content) }
        }
        guard canStart, !kept, let target, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(attributes: RunActivityAttributes(runID: target.id),
                                  content: content(RunActivityState.from(target, presenter: presenter), run: target, now: now), pushType: nil)
    }

    private func content(_ state: RunActivityState, run: RunDigest, now: Date) -> ActivityContent<RunActivityState> {
        ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter), relevanceScore: run.needsInput ? 100 : 60)
    }

    // Activities aren't Sendable, so the async calls find them again by ID off the main actor.
    nonisolated private static func update(_ id: String, content: ActivityContent<RunActivityState>) async {
        for a in Activity<RunActivityAttributes>.activities where a.id == id { await a.update(content) }
    }

    nonisolated private static func end(_ id: String, content: ActivityContent<RunActivityState>?, policy: ActivityUIDismissalPolicy) async {
        for a in Activity<RunActivityAttributes>.activities where a.id == id { await a.end(content, dismissalPolicy: policy) }
    }
}
#endif
