import Foundation
import HeadroomKit

/// Past weeks and recent 5-hour sessions, as the Activity tab shows them.
@MainActor
public enum HistoryPresenter {
    /// Sessions shown in the 5-hour sessions card.
    public static let maxSessionBars = 18

    /// Finished weeks (up to the last seven) beside this week so far.
    ///
    /// `sessions` are the account's stored 5-hour sessions when it has a 5-hour limit (nil when it
    /// doesn't): the card then says how many of the last seven days' sessions hit the limit, in a
    /// chip beside one other (ran out, early resets, or unused on average).
    public static func pastWeeks(_ input: PaceInput, records: [WeekRecord], sessionHitsThisWindow: Int, earlyResetAt: Date?,
                                 sessions: [SessionRecord]? = nil,
                                 now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> PastWeeksModel {
        let p = input.provider
        guard records.count >= 1, let reading = input.reading, let headline = reading.headline, headline.resetsAt != nil else {
            return PastWeeksModel(provider: p, weeks: [], planChange: nil, chips: [], collecting: true)
        }
        let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: now)
        var cols = records.map { r in
            WeekColumn(used: r.finalUsed, ranOutHoursEarly: r.hoursEarly, sessionHits: r.sessionHits, earlyResets: r.earlyReset ? 1 : 0,
                       caption: "Week to \(TimeFormat.monthDay(r.scheduledEnd, calendar: calendar, locale: locale)) · \(Int((r.finalUsed * 100).rounded()))% used")
        }
        let projected: Double = a.projectedRunOut.map { $0 < a.resetsAt ? 1 : 1 - (a.projectedUnusedAtReset ?? 0) } ?? (1 - (a.projectedUnusedAtReset ?? a.remaining))
        cols.append(WeekColumn(used: 1 - a.remaining, projected: max(projected, 1 - a.remaining), sessionHits: sessionHitsThisWindow,
                               earlyResets: earlyResetAt != nil ? 1 : 0, isCurrent: true, caption: "This week · \(Int(((1 - a.remaining) * 100).rounded()))% used so far"))
        var change: (after: Int, pill: String)? = nil
        let plans = records.map(\.plan) + [reading.plan?.pill]
        for i in 1..<plans.count where plans[i] != plans[i - 1] && plans[i] != nil && plans[i - 1] != nil { change = (i - 1, plans[i] ?? "") }
        let ranOut = records.filter(\.ranOut).count
        let ranOutChip: (color: PastWeeksModel.ChipDot, text: String) = (.rose, "ran out \(ranOut) of \(records.count)")
        let early = records.filter(\.earlyReset).count
        let otherChip: (color: PastWeeksModel.ChipDot, text: String)
        if early > 0 {
            otherChip = (.spark, "\(early) early reset\(early == 1 ? "" : "s")")
        } else {
            let unused = records.map { max(0, 1 - $0.finalUsed) }.reduce(0, +) / Double(records.count)
            otherChip = (.azure, "\(Int((unused * 100).rounded()))% unused avg")
        }
        let hit = sessions.flatMap { sessionsHit($0, now: now) }
        // Two chips fit beside the name: with the sessions count, the one other that matters most.
        let chips = hit.map { [ranOut > 0 ? ranOutChip : otherChip, $0.chip] } ?? [ranOutChip, otherChip]
        return PastWeeksModel(provider: p, weeks: cols, planChange: change, chips: chips, collecting: false, sessionsHit: hit)
    }

    /// Finished 5-hour sessions of the last seven days and how many hit the limit; nil when there
    /// were none.
    public static func sessionsHit(_ sessions: [SessionRecord], now: Date) -> PastWeeksModel.SessionsHit? {
        let week = sessions.filter { !$0.inProgress && $0.start > now.addingTimeInterval(-7 * 86400) && $0.start <= now }
        guard !week.isEmpty else { return nil }
        return PastWeeksModel.SessionsHit(hit: week.filter(\.hitLimit).count, total: week.count)
    }

    /// The 5-hour sessions card from stored sessions (newest last).
    public static func sessions(_ p: Provider, sessions: [SessionRecord], warnAt: Double, now: Date,
                                calendar: Calendar = Display.calendar, locale: Locale = Display.locale) -> SessionHistoryModel {
        let shown = Array(sessions.suffix(maxSessionBars))
        var lastDay: Int?
        let bars = shown.map { s -> SessionBar in
            let day = calendar.ordinality(of: .day, in: .era, for: s.start)
            let label = day != lastDay ? TimeFormat.weekdayShort(s.start, calendar: calendar, locale: locale).uppercased() : nil
            lastDay = day
            let span = TimeFormat.shortDayTime(s.start, now: now, calendar: calendar, locale: locale) + " – " + TimeFormat.shortClock(s.resetsAt, calendar: calendar, locale: locale)
            var tip = "\(span) · peak \(Int((s.peakUsed * 100).rounded()))%"
            if let short = s.cutShort, s.hitLimit { tip += " · hit the limit \(Presenter.hoursMinutes(short)) before the reset" }
            if s.inProgress { tip = "Running now · \(Int((s.peakUsed * 100).rounded()))% used so far" }
            return SessionBar(peak: min(max(s.peakUsed, 0), 1), hitLimit: s.hitLimit, inProgress: s.inProgress, dayLabel: label, tooltip: tip)
        }
        let week = sessions.filter { !$0.inProgress && $0.start > now.addingTimeInterval(-7 * 86400) }
        var chips: [(color: PastWeeksModel.ChipDot, text: String)] = []
        if !week.isEmpty {
            let hits = week.filter(\.hitLimit).count
            chips.append((.rose, "\(hits) of \(week.count) hit the limit"))
            let avg = week.map(\.peakUsed).reduce(0, +) / Double(week.count)
            chips.append((.azure, "\(Int((avg * 100).rounded()))% avg peak"))
        }
        return SessionHistoryModel(provider: p, bars: bars, warnAt: warnAt, chips: chips)
    }
}
