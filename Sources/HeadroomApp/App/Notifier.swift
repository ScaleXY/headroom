import AppKit
import HeadroomKit
import HeadroomPresent
import UserNotifications

/// Local notifications for the moments worth an interruption: the 5-hour session nearing or
/// hitting its limit, the session coming back, the week turning tight, credits about to lapse,
/// and agent runs (`TaskAlerts`). Each event fires once; what has fired is remembered across
/// launches, pacing and runs in separate ledgers so a busy run can't push a pacing alert out.
@MainActor
final class Notifier {
    private let settings: AppSettings
    private let defaults: UserDefaults
    /// Session levels last seen per provider, to notice a warned session resetting.
    private var lastSession: [Provider: (level: SessionLevel, resetsAt: Date?)] = [:]
    private var responder: NotificationResponder?
    /// Brings a run's session forward (the "Open Session" action); set by the model.
    var openRun: ((String) -> Void)?

    nonisolated static let pacingLedger = "notifiedEvents"
    nonisolated static let runLedger = "notifiedRunEvents"
    nonisolated static let ledgerSize = 200
    /// The category run alerts with a session to open carry, and its action.
    nonisolated static let runCategory = "task.run"
    nonisolated static let openSessionAction = "open-session"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        guard Self.available else { return }
        let responder = NotificationResponder { [weak self] run in self?.openRun?(run) }
        self.responder = responder
        let center = UNUserNotificationCenter.current()
        center.delegate = responder
        let open = UNNotificationAction(identifier: Self.openSessionAction, title: "Open Session", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.runCategory, actions: [open], intentIdentifiers: [])])
    }

    /// Notifications need a real app bundle (not `swift run`).
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    var anyEnabled: Bool { NotificationKind.allCases.contains { settings.notifies($0) } }

    /// Asks macOS for permission. Completion gets whether alerts are allowed.
    static func requestAuthorization(_ done: (@MainActor (Bool) -> Void)? = nil) {
        guard available else { done?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in done?(granted) }
        }
    }

    /// Looks at every provider's current state and posts what's new.
    func evaluate(_ inputs: [PaceInput], presenter: Presenter) {
        guard Self.available, anyEnabled else { return }
        let now = presenter.now
        for input in inputs {
            guard let reading = input.reading else { continue }
            let p = input.provider
            let name = p.displayName
            let clock: (Date) -> String = { TimeFormat.clock($0, calendar: presenter.calendar, locale: presenter.locale) }

            // 5-hour session.
            let status = SessionStatus(window: reading.session, now: now, policy: presenter.policy)
            if let s = status, let resetsAt = s.resetsAt, resetsAt > now {
                let stamp = Int(resetsAt.timeIntervalSince1970 / 600)
                if s.level == .blocked {
                    post(.sessionLimit, id: "limit.\(p.rawValue).\(stamp)", title: "\(name): 5-hour limit reached",
                         body: "Back at \(clock(resetsAt)), in \(Presenter.hoursMinutes(resetsAt.timeIntervalSince(now))).")
                } else if s.level >= .amber {
                    let f = SessionForecast(window: reading.session, samples: input.samples[LimitWindow.sessionID()] ?? [], now: now)
                    var body = "\(presenter.percent(s.remaining)) left · resets \(clock(resetsAt))."
                    if let out = f.runsOutAt { body += " At this rate it runs out around \(TimeFormat.shortClock(out, calendar: presenter.calendar, locale: presenter.locale))." }
                    post(.sessionWarning, id: "warn.\(p.rawValue).\(stamp)", title: "\(name): 5-hour session \(presenter.percent(s.used)) used", body: body)
                }
            }
            // A session that warned or blocked has reset.
            if let last = lastSession[p], last.level >= .amber, let was = last.resetsAt, was <= now {
                post(.sessionReset, id: "reset.\(p.rawValue).\(Int(was.timeIntervalSince1970 / 600))", title: "\(name): 5-hour session is back",
                     body: "A fresh session is ready. The full allowance is available again.")
            }
            if let s = status { lastSession[p] = (s.level, s.resetsAt) }

            // The week turning tight.
            if let headline = reading.headline, let resetsAt = headline.resetsAt {
                let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: now, policy: presenter.policy)
                let state = input.smoothedState ?? a.state
                if state >= .tight, a.rule != .exhausted {
                    let v = VerdictWriter.verdict(for: a, window: headline, now: now, calendar: presenter.calendar, locale: presenter.locale, state: state)
                    post(.weeklyTight, id: "week.\(p.rawValue).\(Int(resetsAt.timeIntervalSince1970 / 3600)).\(state.rawValue)",
                         title: "\(name): \(state.title.lowercased()) this week", body: v.primary)
                }
            }

            // Reset credits lapsing within two days.
            for credit in reading.resetCredits {
                guard let exp = credit.expiresAt, exp > now, exp.timeIntervalSince(now) < 48 * 3600 else { continue }
                post(.creditsExpiring, id: "credit.\(p.rawValue).\(Int(exp.timeIntervalSince1970))", title: "\(name): a reset credit lapses soon",
                     body: "It expires \(TimeFormat.shortDayTime(exp, now: now, calendar: presenter.calendar, locale: presenter.locale)). Headroom never redeems one for you.")
            }
        }
    }

    private func post(_ kind: NotificationKind, id: String, title: String, body: String) {
        guard settings.notifies(kind), Self.firstTime(id, ledger: Self.pacingLedger, defaults: defaults) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = kind.rawValue
        if kind == .sessionLimit || kind == .sessionWarning { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Task-run alerts (`TaskAlerts` decides the episodes and checks the settings). Grouped by run;
    /// a repeat with the same request identifier replaces the one on screen.
    func post(_ alert: TaskAlerts.Alert) {
        guard Self.available, Self.firstTime(alert.id, ledger: Self.runLedger, defaults: defaults) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = "task.run.\(alert.run)"
        content.userInfo = ["run": alert.run]
        if alert.openable { content.categoryIdentifier = Self.runCategory }
        if alert.sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.request, content: content, trigger: nil))
    }

    /// Records `id` in `ledger` (the last `ledgerSize`) and says whether it was new.
    static func firstTime(_ id: String, ledger: String, defaults: UserDefaults) -> Bool {
        var sent = defaults.stringArray(forKey: ledger) ?? []
        guard !sent.contains(id) else { return false }
        sent.append(id)
        defaults.set(Array(sent.suffix(ledgerSize)), forKey: ledger)
        return true
    }
}

/// Receives clicks on Headroom's notifications: "Open Session" (or the alert itself) on a run
/// alert brings that run's session forward. Alerts show even while Headroom is in front.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let openRun: @MainActor @Sendable (String) -> Void

    init(openRun: @escaping @MainActor @Sendable (String) -> Void) { self.openRun = openRun }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action == Notifier.openSessionAction || action == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.categoryIdentifier == Notifier.runCategory,
              let run = response.notification.request.content.userInfo["run"] as? String else { return }
        await openRun(run)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
