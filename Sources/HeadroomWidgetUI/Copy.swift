import Foundation
import HeadroomKit

/// Widget copy, in the popover's voice and with its formatters.
public struct Copy {
    public var now: Date
    public var calendar: Calendar = .current
    public var locale: Locale = .current

    /// "10:41 AM" today, "Thu 6 PM" later.
    public func when(_ date: Date) -> String {
        TimeFormat.dayOffset(date, now: now, calendar: calendar) == 0
            ? TimeFormat.shortClock(date, calendar: calendar, locale: locale)
            : TimeFormat.shortDayTime(date, now: now, calendar: calendar, locale: locale)
    }

    public func percent(_ f: Double) -> String { "\(Int((max(0, f) * 100).rounded()))%" }

    /// What a dial's needle means, in a few words, and the zone it's in. A forecast passed in
    /// (the session's, the Pace graph's) is said in its own words, so the widgets agree.
    public func burn(_ b: WidgetBurn, left: Double, resetsAt: Date?, idle: Bool = false,
              runsOutAt: Date? = nil, leftAtReset: Double? = nil) -> (text: String, state: PacingState?) {
        if left <= 0.0005 {
            return (resetsAt.map { "Out · back \(when($0))" } ?? "Out", .veryTight)
        }
        if idle { return ("Idle · \(percent(left)) left", nil) }
        guard let ratio = b.ratio, let perHour = b.perHour else { return ("Gathering history…", nil) }
        if ratio < 0.02 { return ("Idle · \(percent(left)) left", nil) }
        let state = BurnGauge.state(ratio)
        if let runsOutAt { return ("Runs out \(when(runsOutAt))", state) }
        if let leftAtReset { return (atReset(leftAtReset), state) }
        if ratio < 1, let resetsAt {
            return (atReset(left - perHour * resetsAt.timeIntervalSince(now) / 3600), state)
        }
        return ("Runs out \(when(now.addingTimeInterval(left / perHour * 3600)))", state)
    }

    /// "70% left at the reset", or "Lasts to the reset" when next to nothing would be.
    public func atReset(_ left: Double) -> String {
        left >= 0.005 ? "\(percent(left)) left at the reset" : "Lasts to the reset"
    }

    /// The session's forecast line, as the Pace card says it.
    public func session(_ s: WidgetSession) -> String {
        switch s.outlook {
        case .idle: "Starts with your next prompt"
        case .blocked: s.resetsAt.map { "Back at \(TimeFormat.shortClock($0, calendar: calendar, locale: locale))" } ?? "Used up"
        case .runsOut: s.runsOutAt.map { "Runs out \(when($0))" } ?? "Runs out before the reset"
        case .lasts: "Lasts to the reset"
        case .comfortable: s.leftAtReset.map(atReset) ?? "Plenty for this session"
        }
    }

    /// "renews in 20h" / "renews Wed".
    public func renews(_ date: Date) -> String {
        "renews in " + TimeFormat.compact(max(0, date.timeIntervalSince(now)))
    }

    public func ago(_ date: Date) -> String {
        let f = TimeFormat.freshness(since: date, now: now)
        return f == "now" ? "just now" : "\(f) ago"
    }

    public init(now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }
}
