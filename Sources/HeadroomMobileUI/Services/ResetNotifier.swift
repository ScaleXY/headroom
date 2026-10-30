import Foundation
import HeadroomKit
import UserNotifications

/// Local notifications at times the Macs already reported, so they arrive on time even when no
/// sync does: a 5-hour session that warned is back, or a week is about to renew with room unused.
@MainActor
public enum ResetNotifier {
    static let prefix = "headroom."

    public static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Replaces the pending notifications with the ones this feed calls for.
    public static func schedule(_ feed: WidgetFeed, sessionBack: Bool, weekRenews: Bool, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        var wanted: [String: UNNotificationRequest] = [:]
        for p in feed.providers where p.isActive != false {
            let name = p.shortLabel ?? p.id.displayName
            if sessionBack, let s = p.session, let resetsAt = s.resetsAt, resetsAt > now, s.level >= .amber {
                let id = prefix + "session.\(p.key).\(Int(resetsAt.timeIntervalSince1970))"
                wanted[id] = request(id, at: resetsAt, title: "\(name): 5-hour session is back",
                                     body: "A fresh session is ready. The full allowance is available again.")
            }
            if weekRenews, let w = p.week, w.left >= 0.2 {
                let at = w.resetsAt.addingTimeInterval(-3600)
                if at > now {
                    let id = prefix + "week.\(p.key).\(Int(w.resetsAt.timeIntervalSince1970))"
                    wanted[id] = request(id, at: at, title: "\(name) renews in an hour",
                                         body: "About \(Int((w.left * 100).rounded()))% of this week is still unused.")
                }
            }
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        let stale = pending.filter { wanted[$0] == nil }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for (id, req) in wanted where !pending.contains(id) { try? await center.add(req) }
    }

    static func request(_ id: String, at date: Date, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "headroom"
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
}
