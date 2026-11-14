import Foundation
import HeadroomPresent
import HeadroomSync
import UserNotifications

/// Local notifications about agent runs, posted as a sync brings news: a run that newly needs an
/// answer (the question itself when the Mac shares it), one that stopped with work left, or one
/// that finished. Unlike the reset reminders these can't be scheduled ahead, so they arrive as fast
/// as the Mac syncs and the phone is woken. Each episode alerts once (`RunAlertLedger`), however
/// many syncs repeat it. While you're at the Mac a needs-input alert is held, scheduled for two
/// minutes after you last touched it, and withdrawn if you answer there first.
@MainActor
public enum RunNotifier {
    static let prefix = "headroom-run."

    /// Records what `runs` say and posts what's due. Sample data never notifies.
    public static func notify(_ runs: [RunDigest], prefs: MobilePreferences, isDemo: Bool, now: Date = Date()) async {
        guard !isDemo else { return }
        let before = prefs.runAlerts
        var ledger = before
        let decision = ledger.observe(runs, now: now, needsInput: prefs.notifyRunNeedsInput, finished: prefs.notifyRunFinished,
                                      stopped: prefs.notifyRunStopped)
        // Most rebuilds change nothing; skip the encode, the App Group write and the change notification.
        if ledger != before { prefs.runAlerts = ledger }
        let center = UNUserNotificationCenter.current()
        if !decision.withdraw.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: decision.withdraw.map(heldID))
        }
        guard !decision.due.isEmpty else { return }
        let presenter = RunsPresenter(now: now, calendar: .current, locale: .current)
        for alert in decision.due {
            let run = alert.run
            let copy = switch alert.kind {
            case .needsInput: presenter.needsInputAlert(run)
            case .stopped: presenter.stoppedAlert(run)
            case .finished: presenter.finishedAlert(run)
            }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            content.threadIdentifier = "headroom.runs"
            if let at = alert.deliverAt {
                // Same identifier each time, so a later sync moves it rather than adding another.
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSince(now)), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: heldID(run.id), content: content, trigger: trigger))
            } else {
                try? await center.add(UNNotificationRequest(identifier: prefix + alert.kind.rawValue + "." + run.id + "." + String(Int(now.timeIntervalSince1970)),
                                                            content: content, trigger: nil))
            }
        }
    }

    static func heldID(_ run: String) -> String { prefix + "held." + run }
}
