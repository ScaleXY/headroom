import AppKit
import HeadroomCore
import HeadroomKit

/// Everything the Pace card needs for one provider, gathered from live state or a fixture.
struct PaceInput {
    var provider: Provider
    var reading: LimitReading?
    /// Glide history per window id.
    var samples: [String: [UsageSample]] = [:]
    /// Finished 5-hour sessions from about the last day, oldest first: the session graph's trail.
    var pastSessions: [SessionRecord] = []
    var fault: Fault? = nil
    /// Tracker-smoothed state, when available (live app). Fixtures use the raw analysis.
    var smoothedState: PacingState? = nil
    var weekCostMicros: Int64? = nil
    var planMonthlyOverride: Double? = nil
    /// Start of the current window when it reset early (an early reset happened this week).
    var earlyResetAt: Date? = nil
}

/// Turns Kit analyses into card models: the single place UI copy is assembled.
@MainActor
struct Presenter {
    var now: Date
    var calendar: Calendar = Display.calendar
    var locale: Locale = Display.locale
    var policy: PacingPolicy = .standard
    var options = PresentationOptions()

    func paceCard(_ input: PaceInput) -> PaceCardModel {
        let p = input.provider
        guard let reading = input.reading else {
            return PaceCardModel(
                provider: p, plan: nil,
                freshness: Freshness(text: input.fault == nil ? "…" : "—", status: input.fault == nil ? .stale : .error,
                                     tooltip: input.fault?.message(for: p, lastGood: nil)),
                session: nil, hero: nil, meter: nil, glide: nil, verdict: nil, callout: nil, rows: [],
                fault: input.fault.map { FaultBannerModel(message: $0.message(for: p, lastGood: nil), detail: retryDetail($0)) }
                    ?? FaultBannerModel(message: "Waiting for the first \(p.displayName) reading…", detail: nil)
            )
        }

        let age = now.timeIntervalSince(reading.fetchedAt)
        let lastGoodClock = TimeFormat.clock(reading.fetchedAt, calendar: calendar, locale: locale)
        let freshness = Freshness(
            text: TimeFormat.freshness(since: reading.fetchedAt, now: now),
            status: input.fault != nil ? .error : (age <= 300 ? .fresh : .stale),
            tooltip: input.fault.map { $0.message(for: p, lastGood: lastGoodClock) } ?? "Updated \(lastGoodClock) · \(sourceLabel(reading.source))"
        )

        let session = SessionStatus(window: reading.session, now: now, policy: policy)
        var model = PaceCardModel(provider: p, plan: reading.plan?.pill, freshness: freshness, session: nil, hero: nil,
                                  meter: nil, glide: nil, verdict: nil, callout: nil, rows: [], fault: nil)

        let detailed = options.sessionDetail == .detailed && reading.session != nil
        if !detailed, let s = session, s.showsBanner, let resetsAt = s.resetsAt {
            let clock = TimeFormat.clock(resetsAt, calendar: calendar, locale: locale)
            model.session = SessionBannerModel(
                level: s.level, used: s.used, title: s.title,
                subtitle: s.level == .blocked ? "back at \(clock)" : "\(percent(s.remaining)) left · resets \(clock)",
                countdown: TimeFormat.compact(s.countdown ?? 0), caption: "to reset"
            )
        }

        let blocked = session?.level == .blocked
        if let headline = reading.headline, headline.resetsAt != nil {
            let samples = input.samples[headline.id] ?? []
            let a = PacingEngine.analyze(window: headline, samples: samples, now: now, policy: policy)
            let state = input.smoothedState ?? a.state
            let period = a.isMonthly ? "month" : "week"
            let label = headline.kind == .modelWeekly ? "left this \(period) · \(headline.label ?? "model")" : "left this \(period)"
            model.hero = HeroModel(
                percentLeft: Int((a.remaining * 100).rounded()), label: label,
                renewValue: TimeFormat.compact(a.timeLeft),
                renewCaption: TimeFormat.renewalCaption(a.resetsAt, now: now, calendar: calendar, locale: locale),
                hourglass: a.hourglass
            )
            let opacity: Double = input.fault != nil ? 0.5 : (blocked || a.rule == .exhausted ? 0.4 : 1)
            model.meter = MeterModel(state: state, cells: a.cells, caret: a.rule == .exhausted ? nil : a.evenPaceMarker, opacity: opacity)
            model.glide = glide(a, samples: samples, state: state)
            let v = VerdictWriter.verdict(for: a, window: headline, now: now, calendar: calendar, locale: locale, state: state)
            model.verdict = VerdictModel(state: v.state, title: v.title, multiple: v.multipleText, primary: v.primary, secondary: v.secondary)
            model.callout = callout(reading, headline: headline, earlyResetAt: input.earlyResetAt)
        }

        model.showsMeter = options.parts.contains(.weekMeter)
        model.showsGlide = options.parts.contains(.weekGraph)

        if detailed, let s = session {
            let samples = input.samples[LimitWindow.sessionID()] ?? []
            let forecast = SessionForecast(window: reading.session, samples: samples, now: now)
            let weekLeft = reading.headline?.remaining
            model.sessionModule = sessionModule(s, forecast: forecast, weekLeft: weekLeft, samples: samples, past: input.pastSessions)
        }

        // Detail rows.
        if !detailed, let s = session, !s.showsBanner, let w = reading.session {
            model.rows.append(DetailRowModel(
                icon: .ring(used: s.used, level: s.level), label: "5-hour session",
                value: "\(percent(s.remaining)) left",
                suffix: w.resetsAt.map { TimeFormat.clock($0, calendar: calendar, locale: locale) }
            ))
        }
        if let row = creditsRow(reading) { model.rows.append(row) }
        if let micros = input.weekCostMicros {
            let multiple = PlanComparison.multiple(weeklyCostMicros: micros, plan: reading.plan, monthlyOverrideUSD: input.planMonthlyOverride)
            model.rows.append(DetailRowModel(
                icon: .coin(p), label: "This \(model.hero?.label.contains("month") == true ? "month" : "week") at API rates",
                value: NumberFormat.dollars(micros: micros, style: .compact),
                suffix: multiple.map { NumberFormat.multiple($0, suffix: "plan") }
            ))
        }

        if let f = input.fault {
            model.fault = FaultBannerModel(message: f.message(for: p, lastGood: lastGoodClock), detail: retryDetail(f, age: age))
        }
        return model
    }

    // MARK: Pieces

    func sessionModule(_ s: SessionStatus, forecast f: SessionForecast, weekLeft: Double?, samples: [UsageSample] = [],
                       past: [SessionRecord] = []) -> SessionModuleModel {
        let clock: (Date) -> String = { TimeFormat.clock($0, calendar: calendar, locale: locale) }
        var m = SessionModuleModel(level: s.level, outlook: f.outlook, tone: f.pacingState, used: f.used, elapsed: f.elapsed,
                                   projectedUsed: nil, title: s.title, subtitle: "", countdown: "", caption: "to reset", forecast: "",
                                   startLabel: f.startedAt.map(clock), endLabel: f.resetsAt.map(clock), onTop: s.showsBanner)
        switch f.outlook {
        case .idle:
            m.level = .normal
            m.title = "5-hour session"
            m.subtitle = "Full · nothing used yet"
            m.countdown = "5h"
            m.caption = "available"
            m.forecast = "The 5-hour clock starts with your next message."
            m.startLabel = nil
            m.endLabel = nil
            m.onTop = false
            // A fresh session reads as a full meter; the graph still shows the day's earlier sessions.
            if options.parts.contains(.sessionMeter) { m.meter = MeterModel(state: .plenty, cells: 5, caret: nil, opacity: 1) }
            if options.parts.contains(.sessionGraph) { m.glide = sessionGlide(f, samples: [], past: past, state: .plenty) }
            return m
        case .blocked:
            m.subtitle = f.resetsAt.map { "back at \(clock($0))" } ?? "paused until the reset"
            m.forecast = weekLeft.map { "Paused until the reset. \(percent($0)) of the week is still left after it." }
                ?? "Paused until the reset."
        case .comfortable:
            if let left = f.leftAtReset {
                m.forecast = left >= 0.995 ? "Barely touched. Nearly all of it renews unused." : "At this rate about \(percent(left)) is left when it resets."
            } else {
                m.forecast = "Just started. A forecast follows after ten minutes."
            }
        case .lasts:
            let left = f.leftAtReset ?? 0
            m.forecast = left >= 0.01 ? "At this rate it lasts to the reset, with \(percent(left)) to spare." : "At this rate it lasts right up to the reset."
        case .runsOut:
            if let out = f.runsOutAt, let reset = f.resetsAt {
                m.forecast = "At this rate it runs out around \(TimeFormat.shortClock(out, calendar: calendar, locale: locale)), \(Self.hoursMinutes(reset.timeIntervalSince(out))) before the reset."
            }
        }
        if f.outlook != .blocked {
            m.subtitle = "\(percent(f.remaining)) left" + (f.resetsAt.map { " · resets \(clock($0))" } ?? "")
        }
        m.countdown = Self.hoursMinutes(f.timeLeft)
        if let burn = f.burnPerHour, f.outlook != .blocked { m.projectedUsed = min(1, f.used + burn * f.timeLeft / 3600) }
        // Past the warning the session wears the warning's color; before it, its own pace.
        let state: PacingState = switch s.level {
        case .normal: f.pacingState
        case .amber: .tight
        case .rose, .blocked: .veryTight
        }
        if options.parts.contains(.sessionMeter) {
            m.meter = MeterModel(state: state, cells: PacingEngine.cells(remaining: f.remaining),
                                 caret: f.outlook == .blocked ? nil : 1 - f.elapsed, opacity: 1)
        }
        if options.parts.contains(.sessionGraph) { m.glide = sessionGlide(f, samples: samples, past: past, state: state) }
        return m
    }

    /// Hours of 5-hour headroom the session graph shows, ending at the current session's reset.
    static let sessionTrailHours: Double = 24

    /// The last day of 5-hour headroom: each session dips as it's used and refills at its reset,
    /// then the current one runs on to where the recent burn takes it. Nil when there's nothing to show.
    private func sessionGlide(_ f: SessionForecast, samples: [UsageSample], past: [SessionRecord], state: PacingState) -> GlideModel? {
        let hours = Self.sessionTrailHours
        let end = f.isActive ? (f.resetsAt ?? now) : now
        let origin = end.addingTimeInterval(-hours * 3600)
        func t(_ d: Date) -> Double { d.timeIntervalSince(origin) / 3600 }

        var points: [GlideModel.Point] = []
        // A session starts empty with its first message, fills up, and refills at its reset.
        func add(start: Date, samples: [UsageSample], until: Date) {
            points.append(GlideModel.Point(t: t(start), used: 0))
            points += samples.filter { $0.time > start && $0.time <= until }.map { GlideModel.Point(t: t($0.time), used: $0.used) }
        }
        let liveStart = f.isActive ? f.startedAt : nil
        for record in past.sorted(by: { $0.start < $1.start }) where record.resetsAt > origin && record.resetsAt <= (liveStart ?? now) {
            let before = points.count
            if record.samples.isEmpty {
                // Saved before samples were kept: only the peak is known, so the climb is drawn as a gap.
                points.append(GlideModel.Point(t: t(record.start), used: 0))
                points.append(GlideModel.Point(t: t(record.hitLimitAt ?? record.resetsAt), used: record.peakUsed))
            } else {
                add(start: record.start, samples: record.samples, until: record.resetsAt)
            }
            guard points.count > before, let last = points.last else { continue }
            if last.t < t(record.resetsAt) { points.append(GlideModel.Point(t: t(record.resetsAt), used: last.used)) }
            points.append(GlideModel.Point(t: t(record.resetsAt), used: 0, refill: true))
        }
        let pastDip = points.contains { $0.used > 0 && $0.t > 0 }

        var nowT = t(now)
        var projection = (t: nowT, remaining: 1.0)
        var runsOut = false
        var label: String? = nil
        var evenFrom: Double? = nil
        if f.isActive, let start = f.startedAt {
            add(start: start, samples: samples, until: now)
            points.append(GlideModel.Point(t: nowT, used: f.used))
            evenFrom = t(start)
            projection = (nowT, f.remaining)
            if f.outlook == .blocked {
                projection = (nowT, 0)
            } else if let out = f.runsOutAt {
                projection = (t(out), 0)
                runsOut = true
            } else if let left = f.leftAtReset {
                projection = (hours, left)
                if left >= 0.005 { label = "\(percent(left)) left at reset" }
            }
        } else {
            // Between sessions the headroom is full; with no earlier dips there's nothing to graph.
            guard pastDip else { return nil }
            nowT = hours
            points.append(GlideModel.Point(t: nowT, used: 0))
        }
        // Clip to the chart: the last point before its left edge stands in at the edge.
        if let lastBefore = points.lastIndex(where: { $0.t < 0 }) {
            points[lastBefore].t = 0
            points.removeFirst(lastBefore)
        }
        if points.first.map({ $0.t > 0.1 && $0.used == 0 }) ?? false { points.insert(GlideModel.Point(t: 0, used: 0), at: 0) }

        var g = GlideModel(hours: hours, windowStart: origin, nowT: nowT, points: points, projectionEnd: projection,
                           runsOut: runsOut, endLabel: label, state: state)
        g.evenPaceFrom = evenFrom
        return g
    }

    /// "<1m", "48m", "2h", "2h 12m".
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func glide(_ a: PacingAnalysis, samples: [UsageSample], state: PacingState) -> GlideModel {
        let hours = a.duration / 3600
        let nowT = a.elapsed * hours
        var points = samples
            .filter { $0.time >= a.windowStart && $0.time <= now }
            .map { GlideModel.Point(t: $0.time.timeIntervalSince(a.windowStart) / 3600, used: $0.used) }
        if points.first.map({ $0.t > 0.5 }) ?? true { points.insert(GlideModel.Point(t: 0, used: 0), at: 0) }
        points.append(GlideModel.Point(t: nowT, used: 1 - a.remaining))
        var end = (t: nowT, remaining: a.remaining)
        var runsOut = false
        var label: String? = nil
        if a.rule == .exhausted {
            end = (nowT, 0)
        } else if let runOut = a.recentRunOut {
            // A heavy stretch right now: show where it ends, not where the 24-hour average does.
            end = (runOut.timeIntervalSince(a.windowStart) / 3600, 0)
            runsOut = true
        } else if let runOut = a.projectedRunOut, runOut < a.resetsAt {
            end = (runOut.timeIntervalSince(a.windowStart) / 3600, 0)
            runsOut = true
        } else if let unused = a.projectedUnusedAtReset {
            end = (hours, unused)
            if unused >= 0.005 { label = "\(percent(unused)) renews unused" }
        } else {
            // No burn history yet: project at even pace.
            end = (hours, max(0, a.remaining - a.timeFraction))
        }
        return GlideModel(hours: hours, windowStart: a.windowStart, nowT: nowT, points: points, projectionEnd: end,
                          runsOut: runsOut, endLabel: label, state: state)
    }

    private func callout(_ r: LimitReading, headline: LimitWindow, earlyResetAt: Date?) -> CalloutModel? {
        let caps = r.modelCaps.filter { $0.id != headline.id }
        if let empty = caps.first(where: { $0.used >= 1 }) {
            let when = empty.resetsAt.map { " · resets " + TimeFormat.shortDayTime($0, now: now, calendar: calendar, locale: locale) } ?? ""
            return CalloutModel(kind: .capEmpty, text: "\(empty.label ?? "Model") weekly cap reached\(when) · other models still available")
        }
        let tight = caps.compactMap { cap -> (LimitWindow, PacingAnalysis)? in
            guard cap.resetsAt != nil, cap.remaining < headline.remaining else { return nil }
            let a = PacingEngine.analyze(window: cap, samples: [], now: now, policy: policy)
            return a.state >= .tight ? (cap, a) : nil
        }.min { $0.0.remaining < $1.0.remaining }
        if let (cap, a) = tight {
            return CalloutModel(kind: .capTight, text: "\(cap.label ?? "Model") cap \(percent(cap.remaining)) left · \(a.state.word == "tight" ? "getting tight" : a.state.word)")
        }
        if let early = earlyResetAt, let resetsAt = headline.resetsAt {
            let day = TimeFormat.weekdayShort(early, calendar: calendar, locale: locale)
            let next = TimeFormat.dayAndClock(resetsAt, now: now, calendar: calendar, locale: locale)
            return CalloutModel(kind: .earlyReset, text: "Reset early on \(day) · new week to \(next)")
        }
        return nil
    }

    private func creditsRow(_ r: LimitReading) -> DetailRowModel? {
        let total = r.totalResetCredits
        guard total > 0 else { return nil }
        let sorted = r.resetCredits.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let horizon = policy.creditExpiryHighlight
        let soon = sorted.filter { $0.expiresAt.map { $0.timeIntervalSince(now) <= horizon && $0 > now } ?? false }
        let tooltip = sorted.map { c in
            let name = c.title ?? "Reset credit"
            let count = c.count > 1 ? " ×\(c.count)" : ""
            let exp = c.expiresAt.map { "expires " + TimeFormat.dayAndClock($0, now: now, calendar: calendar, locale: locale) } ?? "no expiry"
            return "\(name)\(count) · \(exp)"
        }.joined(separator: "\n")
        if let first = soon.first, let exp = first.expiresAt {
            // Only the credits lapsing at that soonest moment; later ones are in the tooltip.
            let n = soon.filter { $0.expiresAt == exp }.reduce(0) { $0 + $1.count }
            return DetailRowModel(icon: .hourglass(highlight: true), label: "Reset credits",
                                  value: "\(n) \(n == 1 ? "lapses" : "lapse") in \(TimeFormat.compact(exp.timeIntervalSince(now)))",
                                  suffix: "\(total) total", highlight: true, tooltip: tooltip.isEmpty ? nil : tooltip)
        }
        return DetailRowModel(icon: .hourglass(highlight: false), label: "Reset credits", value: "\(total) available",
                              suffix: nil, tooltip: tooltip.isEmpty ? nil : tooltip)
    }

    private func retryDetail(_ f: Fault, age: TimeInterval? = nil) -> String? {
        let ageText = age.map { " · reading is \(TimeFormat.compact($0)) old" } ?? ""
        switch f {
        case .enterprise, .apiKeyLogin: return nil
        default: return "Retrying automatically" + ageText
        }
    }

    private func sourceLabel(_ s: ReadingSource) -> String {
        switch s {
        case .api: "usage API"
        case .appServer: "Codex app-server"
        case .passiveLog: "Codex session log"
        case .cliText: "claude /usage"
        }
    }

    func percent(_ f: Double) -> String { "\(Int((max(0, f) * 100).rounded()))%" }
}
