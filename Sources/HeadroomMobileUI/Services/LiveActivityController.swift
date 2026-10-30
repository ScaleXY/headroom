#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation
import HeadroomKit
import HeadroomWidgetUI

/// The 5-hour session Live Activity: started from the app (or a widget's Track button), updated
/// whenever the app rebuilds (in the foreground, or woken by a sync), and ended at the reset.
/// Between updates it stays right on its own: the countdown ticks, and it greys out when stale.
@MainActor
public final class LiveActivityController {
    /// Without an update for this long, iOS shows the activity as stale.
    static let staleAfter: TimeInterval = 30 * 60
    private var alerted: [String: SessionLevel] = [:]

    public init() {}

    public var tracked: Set<String> { Set(Activity<SessionActivityAttributes>.activities.filter { $0.activityState == .active }.map(\.attributes.accountID)) }

    public var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Starts tracking an account's running session.
    public func start(_ accountID: String, feed: WidgetFeed) {
        guard enabled, !tracked.contains(accountID), let p = feed.account(accountID),
              let state = SessionActivityState.from(p, generatedAt: feed.generatedAt) else { return }
        let attributes = SessionActivityAttributes(accountID: accountID, provider: p.id, shortLabel: p.shortLabel ?? p.id.displayName)
        _ = try? Activity.request(attributes: attributes, content: content(state), pushType: nil)
        alerted[accountID] = state.level
    }

    public func stop(_ accountID: String) {
        for a in Activity<SessionActivityAttributes>.activities where a.attributes.accountID == accountID {
            let id = a.id
            Task { await Self.end(id, content: nil, policy: .immediate) }
        }
    }

    /// Brings every running activity up to date, ends the ones whose session is over, and (when
    /// asked, in the foreground) starts one for each account with a session running.
    public func sync(_ feed: WidgetFeed, autoStart: Bool) {
        for activity in Activity<SessionActivityAttributes>.activities where activity.activityState == .active {
            let id = activity.attributes.accountID
            guard let p = feed.account(id), let state = SessionActivityState.from(p, generatedAt: feed.generatedAt),
                  state.resetsAt > Date() else {
                end(activity)
                continue
            }
            // Ring the bell once per level, only as it escalates.
            var alert: AlertConfiguration?
            if state.level > (alerted[id] ?? .normal), state.level >= .amber {
                alert = AlertConfiguration(title: "\(activity.attributes.shortLabel): 5-hour session \(Int((state.used * 100).rounded()))% used",
                                           body: "\(state.forecast(Copy(now: Date())))", sound: .default)
                alerted[id] = state.level
            }
            let activityID = activity.id, next = content(state)
            Task { await Self.update(activityID, content: next, alert: alert) }
        }
        guard autoStart else { return }
        for p in feed.providers where p.isActive != false {
            if let key = p.account, p.session.map({ !$0.isIdle }) == true { start(key, feed: feed) }
        }
    }

    private func end(_ activity: Activity<SessionActivityAttributes>) {
        var final = activity.content.state
        let reset = final.resetsAt
        final.used = 0
        final.level = .normal
        final.outlook = .idle
        final.updatedAt = Date()
        let id = activity.id
        Task { await Self.end(id, content: ActivityContent(state: final, staleDate: nil), policy: .after(max(Date(), reset).addingTimeInterval(15 * 60))) }
        alerted[activity.attributes.accountID] = nil
    }

    // Activities aren't Sendable, so the async calls find them again by ID off the main actor.
    nonisolated private static func update(_ id: String, content: ActivityContent<SessionActivityState>, alert: AlertConfiguration?) async {
        for a in Activity<SessionActivityAttributes>.activities where a.id == id { await a.update(content, alertConfiguration: alert) }
    }

    nonisolated private static func end(_ id: String, content: ActivityContent<SessionActivityState>?, policy: ActivityUIDismissalPolicy) async {
        for a in Activity<SessionActivityAttributes>.activities where a.id == id { await a.end(content, dismissalPolicy: policy) }
    }

    private func content(_ state: SessionActivityState) -> ActivityContent<SessionActivityState> {
        ActivityContent(state: state, staleDate: min(state.resetsAt, state.updatedAt.addingTimeInterval(Self.staleAfter)),
                        relevanceScore: state.level >= .amber ? 100 : 50)
    }
}
#endif
