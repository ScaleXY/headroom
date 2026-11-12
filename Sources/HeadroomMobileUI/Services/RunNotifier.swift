import Foundation
import HeadroomPresent
import HeadroomSync
import UserNotifications

/// Local notifications about agent runs, posted as a sync brings news: a run that newly needs an
/// answer, or one that finished. Unlike the reset reminders these can't be scheduled ahead, so
/// they arrive as fast as the Mac syncs and the phone is woken. Each episode alerts once
/// (`RunAlertLedger`), however many syncs repeat it.
@MainActor
public enum RunNotifier {
    static let prefix = "headroom-run."

    /// Records what `runs` say and posts what's due. Sample data never notifies.
    public static func notify(_ runs: [RunDigest], prefs: MobilePreferences, isDemo: Bool, now: Date = Date()) async {
        guard !isDemo else { return }
        var ledger = prefs.runAlerts
        let due = ledger.observe(runs, now: now, needsInput: prefs.notifyRunNeedsInput, finished: prefs.notifyRunFinished)
        prefs.runAlerts = ledger
        guard !due.isEmpty else { return }
        let presenter = RunsPresenter(now: now, calendar: .current, locale: .current)
        let center = UNUserNotificationCenter.current()
        for (kind, run) in due {
            let copy = kind == .needsInput ? presenter.needsInputAlert(run) : presenter.finishedAlert(run)
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            content.threadIdentifier = "headroom.runs"
            try? await center.add(UNNotificationRequest(identifier: prefix + kind.rawValue + "." + run.id + "." + String(Int(now.timeIntervalSince1970)),
                                                        content: content, trigger: nil))
        }
    }
}
