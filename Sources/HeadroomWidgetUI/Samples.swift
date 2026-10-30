import Foundation
import HeadroomKit

/// Sample feeds: the widget gallery's preview and every state the review renders cover.
public enum WidgetSamples {
    public enum Scenario: String, CaseIterable, Sendable {
        /// A busy afternoon: the session in the redline, the week a little fast.
        case busy
        /// Cruising: both well under the lasting pace.
        case calm
        /// The 5-hour session used up, waiting for its reset.
        case blocked
        /// Nothing running right now.
        case idle
        /// Claude and Codex side by side.
        case both
    }

    public static func feed(_ scenario: Scenario, now: Date = Date()) -> WidgetFeed {
        switch scenario {
        case .busy:
            return WidgetFeed(generatedAt: now, providers: [claude(now: now, weekLeft: 0.62, weekBurn: 1.3, weekAvg: 0.8,
                                                                   sessionUsed: 0.84, sessionBurn: 2.2, sessionElapsed: 3.2)])
        case .calm:
            return WidgetFeed(generatedAt: now, providers: [claude(now: now, weekLeft: 0.82, weekBurn: 0.55, weekAvg: 0.45,
                                                                   sessionUsed: 0.31, sessionBurn: 0.6, sessionElapsed: 2.1)])
        case .blocked:
            var p = claude(now: now, weekLeft: 0.41, weekBurn: 1.7, weekAvg: 1.1, sessionUsed: 1, sessionBurn: 0, sessionElapsed: 4.1)
            p.blockedUntil = p.session?.resetsAt
            return WidgetFeed(generatedAt: now, providers: [p])
        case .idle:
            return WidgetFeed(generatedAt: now, providers: [claude(now: now, weekLeft: 0.74, weekBurn: 0, weekAvg: 0.6,
                                                                   sessionUsed: 0, sessionBurn: 0, sessionElapsed: nil)])
        case .both:
            var codex = claude(now: now, weekLeft: 0.27, weekBurn: 1.9, weekAvg: 1.2, sessionUsed: 0.58, sessionBurn: 1.1, sessionElapsed: 2.6,
                               provider: .codex)
            codex.plan = "PRO"
            return WidgetFeed(generatedAt: now, providers: [claude(now: now, weekLeft: 0.82, weekBurn: 0.7, weekAvg: 0.5,
                                                                   sessionUsed: 0.46, sessionBurn: 0.9, sessionElapsed: 1.8), codex])
        }
    }

    /// One provider with a believable week (busy days, quiet nights) and a day of sessions.
    static func claude(now: Date, weekLeft: Double, weekBurn: Double, weekAvg: Double, sessionUsed: Double, sessionBurn: Double,
                       sessionElapsed: Double?, provider: Provider = .claude) -> WidgetProvider {
        let cal = Calendar.current
        // The week renews at the next 6 AM, five days from now: two and a bit days in.
        let resetBase = cal.nextDate(after: now, matching: DateComponents(hour: 6, minute: 0), matchingPolicy: .nextTime) ?? now
        let weekReset = resetBase.addingTimeInterval(4 * 86400)
        let weekStart = weekReset.addingTimeInterval(-7 * 86400)
        let hoursLeft = weekReset.timeIntervalSince(now) / 3600
        let lasting = weekLeft / hoursLeft
        let weekState: PacingState = weekLeft / (hoursLeft / 168) >= 1.35 ? .plenty : weekLeft / (hoursLeft / 168) >= 0.95 ? .onPace
            : weekLeft / (hoursLeft / 168) >= 0.75 ? .tight : .veryTight
        let nowT = now.timeIntervalSince(weekStart) / 3600

        // Usage piles up in the working hours.
        var raw: [(Double, Double)] = []
        var acc = 0.0
        var t = 0.0
        while t <= nowT {
            let hour = cal.component(.hour, from: weekStart.addingTimeInterval(t * 3600))
            acc += (9...23).contains(hour) ? 1 + 0.6 * sin(t * 0.9) * sin(t * 0.37) : 0.05
            raw.append((t, acc))
            t += 0.5
        }
        let used = 1 - weekLeft
        let points = raw.map { WidgetPoint(t: $0.0, u: $0.1 / max(acc, 0.001) * used) }
        let perHour = weekBurn * lasting
        let runsOut = weekBurn >= 1
        let endT = runsOut ? nowT + weekLeft / max(perHour, 0.0001) : 168
        let endRemaining = runsOut ? 0 : max(0, weekLeft - weekAvg * lasting * hoursLeft)
        let week = WidgetWeek(
            caption: "left this week", left: weekLeft, state: weekState,
            multiple: (weekLeft / (hoursLeft / 168) * 10).rounded() / 10, cells: max(1, Int((weekLeft * 5).rounded())),
            caret: hoursLeft / 168, resetsAt: weekReset, hourglass: weekState == .plenty && hoursLeft < 48,
            verdictTitle: weekState.title,
            verdict: runsOut ? "At this rate you run out \(TimeFormat.shortDayTime(now.addingTimeInterval(weekLeft / max(perHour, 0.0001) * 3600), now: now, calendar: cal, locale: .current)), ahead of the renewal."
                : "On track to renew with room to spare. Spend it before it renews \(TimeFormat.weekdayShort(weekReset, calendar: cal, locale: .current)).",
            burn: WidgetBurn(perHour: perHour, averagePerHour: weekAvg * lasting, lastingPerHour: lasting),
            chart: WidgetChart(start: weekStart, hours: 168, nowT: nowT, points: BurnGauge.thin(points, limit: 160),
                               endT: endT, endRemaining: endRemaining, runsOut: runsOut, evenFrom: 0)
        )

        let session = sessionSample(now: now, used: sessionUsed, burn: sessionBurn, elapsed: sessionElapsed)
        var hourly: [Int64] = []
        for h in 0..<24 {
            let hour = cal.component(.hour, from: now.addingTimeInterval(Double(h - 23) * 3600))
            let busy = (9...23).contains(hour)
            hourly.append(busy ? Int64(900_000 + 1_400_000 * abs(sin(Double(h) * 1.7))) : Int64(h % 3 == 0 ? 40_000 : 0))
        }
        return WidgetProvider(id: provider, plan: provider == .claude ? "MAX 20×" : "PRO", readingAt: now, week: week, session: session,
                              hourlyTokens: hourly, tokens24h: hourly.reduce(0, +), cost24hUSD: Double(hourly.reduce(0, +)) / 1_000_000 * 1.9,
                              weekCostUSD: 214.6)
    }

    /// The current session plus two earlier ones (one ran dry), as the 24-hour trail.
    static func sessionSample(now: Date, used: Double, burn: Double, elapsed: Double?) -> WidgetSession {
        let active = elapsed != nil && used > 0
        let start = now.addingTimeInterval(-(elapsed ?? 0) * 3600)
        let reset = start.addingTimeInterval(5 * 3600)
        let end = active ? reset : now
        let chartStart = end.addingTimeInterval(-24 * 3600)
        func T(_ d: Date) -> Double { d.timeIntervalSince(chartStart) / 3600 }

        var pts: [WidgetPoint] = []
        // Earlier sessions: (hours before the current start, peak, hours to peak).
        let past: [(Double, Double, Double)] = [(15.5, 0.62, 3.6), (8.2, 1.0, 3.1)]
        for (ago, peak, rise) in past {
            let s = (active ? start : now).addingTimeInterval(-ago * 3600)
            for i in 0...12 {
                let f = Double(i) / 12
                pts.append(WidgetPoint(t: T(s) + rise * f, u: peak * (f * f * (3 - 2 * f))))
            }
            pts.append(WidgetPoint(t: T(s) + 5, u: peak))
            pts.append(WidgetPoint(t: T(s) + 5, u: 0, refill: true))
        }
        let lastingPerHour = active ? max(0, 1 - used) / max(reset.timeIntervalSince(now) / 3600, 0.01) : 1
        var outlook: SessionForecast.Outlook = .idle
        var level: SessionLevel = .normal
        var runsOutAt: Date?
        var leftAtReset: Double?
        if active, let elapsed {
            for i in 0...14 {
                let f = Double(i) / 14
                pts.append(WidgetPoint(t: T(start) + elapsed * f, u: used * pow(f, 1.4)))
            }
            let perHour = burn * lastingPerHour
            level = used >= 1 ? .blocked : used >= 0.9 ? .rose : used >= 0.75 ? .amber : .normal
            if used >= 1 {
                outlook = .blocked
            } else if burn >= 1 {
                outlook = .runsOut
                runsOutAt = now.addingTimeInterval((1 - used) / max(perHour, 0.0001) * 3600)
            } else {
                leftAtReset = max(0, (1 - used) - perHour * reset.timeIntervalSince(now) / 3600)
                outlook = (leftAtReset ?? 0) >= SessionForecast.comfortableLeft ? .comfortable : .lasts
            }
        }
        let nowT = T(now)
        let chart = WidgetChart(start: chartStart, hours: 24, nowT: nowT, points: pts,
                                endT: runsOutAt.map(T) ?? T(end), endRemaining: active ? (runsOutAt == nil ? (leftAtReset ?? max(0, 1 - used)) : 0) : 1,
                                runsOut: runsOutAt != nil, evenFrom: nil)
        return WidgetSession(used: active ? used : 0, resetsAt: active ? reset : nil, startedAt: active ? start : nil, level: level,
                             outlook: outlook, runsOutAt: runsOutAt, leftAtReset: leftAtReset,
                             burn: WidgetBurn(perHour: active ? burn * lastingPerHour : 0, averagePerHour: active ? used / max(elapsed ?? 1, 0.1) : nil,
                                              lastingPerHour: active ? lastingPerHour : 1),
                             chart: chart)
    }
}
