import Foundation
import HeadroomKit

/// Everything the Pace card needs for one provider, gathered from live state or a fixture.
public struct PaceInput {
    public var provider: Provider
    public var reading: LimitReading?
    /// Glide history per window id.
    public var samples: [String: [UsageSample]] = [:]
    /// Finished 5-hour sessions from about the last day, oldest first: the session graph's trail.
    public var pastSessions: [SessionRecord] = []
    public var fault: Fault? = nil
    /// Tracker-smoothed state, when available (live app). Fixtures use the raw analysis.
    public var smoothedState: PacingState? = nil
    public var weekCostMicros: Int64? = nil
    public var planMonthlyOverride: Double? = nil
    /// Start of the current window when it reset early (an early reset happened this week).
    public var earlyResetAt: Date? = nil
    /// Live agent runs spending this provider and their shares of its current spend (live app only).
    public var runSpend: [RunSpend] = []

    public init(provider: Provider, reading: LimitReading? = nil, samples: [String: [UsageSample]] = [:], pastSessions: [SessionRecord] = [], fault: Fault? = nil, smoothedState: PacingState? = nil, weekCostMicros: Int64? = nil, planMonthlyOverride: Double? = nil, earlyResetAt: Date? = nil) {
        self.provider = provider
        self.reading = reading
        self.samples = samples
        self.pastSessions = pastSessions
        self.fault = fault
        self.smoothedState = smoothedState
        self.weekCostMicros = weekCostMicros
        self.planMonthlyOverride = planMonthlyOverride
        self.earlyResetAt = earlyResetAt
    }
}

/// Turns Kit analyses into card models: the single place UI copy is assembled.
@MainActor
public struct Presenter {
    public var now: Date
    public var calendar: Calendar = Display.calendar
    public var locale: Locale = Display.locale
    public var policy: PacingPolicy = .standard
    public var options = PresentationOptions()

    public func paceCard(_ input: PaceInput) -> PaceCardModel {
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
        // The banner shows from the warning level up. The detailed session panel no longer takes its
        // place on the Limits card; it is still built (below) for the widgets' session chart.
        if let s = session, s.showsBanner, let resetsAt = s.resetsAt {
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
            let percentLeft = Int((a.remaining * 100).rounded())
            let renewCaption = TimeFormat.renewalCaption(a.resetsAt, now: now, calendar: calendar, locale: locale)
            let scope = headline.kind == .modelWeekly ? (headline.label ?? "model") + " " : ""
            model.hero = HeroModel(
                percentLeft: percentLeft, label: label,
                renewValue: TimeFormat.compact(a.timeLeft),
                renewCaption: renewCaption,
                hourglass: a.hourglass,
                renewIn: TimeFormat.renewIn(a.timeLeft),
                renewAt: TimeFormat.renewAt(a.resetsAt, now: now, calendar: calendar, locale: locale),
                tooltip: "\(percentLeft)% of this \(period)'s \(scope)allowance left · \(renewCaption)"
            )
            let opacity: Double = input.fault != nil ? 0.5 : (blocked || a.rule == .exhausted ? 0.4 : 1)
            model.meter = MeterModel(state: state, cells: a.cells, caret: a.rule == .exhausted ? nil : a.evenPaceMarker, opacity: opacity)
            let g = glide(a, samples: samples, state: state)
            model.glide = g
            let v = VerdictWriter.verdict(for: a, window: headline, now: now, calendar: calendar, locale: locale, state: state)
            model.verdict = VerdictModel(state: v.state, title: v.title, multiple: v.multipleText, primary: v.primary, secondary: v.secondary)
            model.callout = callout(reading, headline: headline, earlyResetAt: input.earlyResetAt)

            // One chart for the week and what's under it: the lane, its keys, a caption and the stat strip.
            let forecast = reading.session.map { SessionForecast(window: $0, samples: input.samples[LimitWindow.sessionID()] ?? [], now: now) }
            let lane = forecast.map { sessionLane(g, forecast: $0, status: session, input: input) } ?? dailyLane(g, period: period)
            if options.parts.contains(.sessionGraph) { model.lane = lane }
            model.keys = limitsKeys(state: state, lane: model.lane, period: period)
            model.chartCaption = forecast.flatMap { chartCaption($0, weekLeft: a.remaining, period: period) }
            model.stats = statStrip(a, state: state, period: period, lane: lane, forecast: forecast, status: session)
        }

        model.showsMeter = options.parts.contains(.weekMeter)
        model.showsGlide = options.parts.contains(.weekGraph)

        if detailed, let s = session {
            let samples = input.samples[LimitWindow.sessionID()] ?? []
            let forecast = SessionForecast(window: reading.session, samples: samples, now: now)
            let weekLeft = reading.headline?.remaining
            model.sessionModule = sessionModule(s, forecast: forecast, weekLeft: weekLeft, samples: samples, past: input.pastSessions)
        }
        model.spending = spendSplit(input.runSpend)

        // Detail rows. The stat strip carries the 5-hour session when there is one.
        if model.stats.isEmpty, let s = session, !s.showsBanner, let w = reading.session {
            model.rows.append(DetailRowModel(
                icon: .ring(used: s.used, level: s.level), label: "5-hour session",
                value: "\(percent(s.remaining)) left",
                suffix: w.resetsAt.map { TimeFormat.clock($0, calendar: calendar, locale: locale) }
            ))
        }
        if let row = creditsRow(reading) { model.rows.append(row) }
        if let micros = input.weekCostMicros {
            let multiple = PlanComparison.multiple(weeklyCostMicros: micros, plan: reading.plan, monthlyOverrideUSD: input.planMonthlyOverride,
                                                   window: reading.headline?.effectiveDuration ?? 7 * 86400)
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

    public func sessionModule(_ s: SessionStatus, forecast f: SessionForecast, weekLeft: Double?, samples: [UsageSample] = [],
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

    /// Live runs shown by name in "What's spending it"; the rest count as other sessions.
    public nonisolated static let spendRunsShown = 3

    /// The 5-hour window's current spend split by live run, then everything else. Nil when no
    /// live run is spending the provider.
    public func spendSplit(_ runs: [RunSpend]) -> SpendSplitModel? {
        let live = runs.filter { $0.share >= 0.005 }.sorted { ($0.share, $1.title) > ($1.share, $0.title) }
        guard !live.isEmpty else { return nil }
        let shown = Array(live.prefix(Self.spendRunsShown))
        // Rates come from slightly different windows: never more than the whole.
        let total = shown.reduce(0) { $0 + $1.share }
        let scale = total > 1 ? 1 / total : 1
        var shares = shown.map { $0.share * scale }
        let other = max(0, 1 - shares.reduce(0, +))
        if other >= 0.005 { shares.append(other) }
        let percents = Self.wholePercents(shares)
        var slices = zip(shown, percents).enumerated().map { i, pair in
            SpendSplitModel.Slice(label: pair.0.title, share: shares[i], percent: "\(pair.1)%", isOther: false)
        }
        if other >= 0.005 {
            slices.append(SpendSplitModel.Slice(label: "other sessions", share: other, percent: "\(percents.last ?? 0)%", isOther: true))
        }
        return SpendSplitModel(title: "What's spending it", slices: slices)
    }

    /// Whole percents that add up to 100 (largest remainder).
    nonisolated static func wholePercents(_ shares: [Double]) -> [Int] {
        let sum = shares.reduce(0, +)
        guard sum > 0 else { return shares.map { _ in 0 } }
        let exact = shares.map { $0 / sum * 100 }
        var out = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { exact[$0] - Double(out[$0]) > exact[$1] - Double(out[$1]) }
        for i in order.prefix(max(0, 100 - out.reduce(0, +))) { out[i] += 1 }
        return out
    }

    /// Hours of 5-hour headroom the session graph shows between sessions, ending now.
    public nonisolated static let sessionTrailHours: Double = 24

    /// The 5-hour session graph. While a session runs it spans that session, start to reset, so now
    /// sits where it is in the window and the forecast runs on to the reset. Between sessions it is
    /// the last day: each session dips as it's used and refills at its reset. Nil when there's nothing to show.
    private func sessionGlide(_ f: SessionForecast, samples: [UsageSample], past: [SessionRecord], state: PacingState) -> GlideModel? {
        let live: (start: Date, reset: Date)? = f.isActive ? f.startedAt.flatMap { s in f.resetsAt.map { (s, $0) } } : nil
        let end = live?.reset ?? now
        let origin = live?.start ?? end.addingTimeInterval(-Self.sessionTrailHours * 3600)
        let hours = end.timeIntervalSince(origin) / 3600
        func t(_ d: Date) -> Double { d.timeIntervalSince(origin) / 3600 }

        var points: [GlideModel.Point] = []
        var lastReset: Date?
        // A session starts empty with its first message, fills up, and refills at its reset. A start
        // is the reset less five hours, and resets drift by a moment between readings: one that falls
        // just before the last reset would be drawn inside the session before it.
        func add(start: Date, samples: [UsageSample], until: Date) {
            let start = max(start, lastReset ?? start)
            points.append(GlideModel.Point(t: t(start), used: 0))
            points += samples.filter { $0.time > start && $0.time <= until }.map { GlideModel.Point(t: t($0.time), used: $0.used) }
        }
        for record in past.sorted(by: { $0.start < $1.start }) where live == nil && record.resetsAt > origin && record.resetsAt <= now {
            let before = points.count
            if record.samples.isEmpty {
                // Saved before samples were kept: only the peak is known, so the climb is drawn as a gap.
                points.append(GlideModel.Point(t: t(max(record.start, lastReset ?? record.start)), used: 0))
                points.append(GlideModel.Point(t: t(record.hitLimitAt ?? record.resetsAt), used: record.peakUsed))
            } else {
                add(start: record.start, samples: record.samples, until: record.resetsAt)
            }
            guard points.count > before, let last = points.last else { continue }
            if last.t < t(record.resetsAt) { points.append(GlideModel.Point(t: t(record.resetsAt), used: last.used)) }
            points.append(GlideModel.Point(t: t(record.resetsAt), used: 0, refill: true))
            lastReset = record.resetsAt
        }
        let pastDip = points.contains { $0.used > 0 && $0.t > 0 }

        var nowT = t(now)
        var projection = (t: nowT, remaining: 1.0)
        var runsOut = false
        var label: String? = nil
        if let live {
            add(start: live.start, samples: samples, until: now)
            points.append(GlideModel.Point(t: nowT, used: f.used))
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
        // No even-pace diagonal: the meter above marks even pace.
        g.evenPaceFrom = nil
        return g
    }

    /// "<1m", "48m", "2h", "2h 12m".
    public static func hoursMinutes(_ seconds: TimeInterval) -> String {
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

    // MARK: Limits chart: the lane, keys, caption and stat strip

    /// "Tue 9 AM – 2 PM".
    private func sessionSpan(_ start: Date, _ reset: Date) -> String {
        TimeFormat.weekdayShort(start, calendar: calendar, locale: locale) + " " + TimeFormat.shortClock(start, calendar: calendar, locale: locale)
            + " – " + TimeFormat.shortClock(reset, calendar: calendar, locale: locale)
    }

    /// The 5-hour lane: every stored session that overlaps the window, clipped to it, plus the one running now.
    public func sessionLane(_ g: GlideModel, forecast f: SessionForecast, status: SessionStatus?, input: PaceInput) -> LimitsLaneModel {
        let start = g.windowStart, hours = g.hours
        func t(_ d: Date) -> Double { d.timeIntervalSince(start) / 3600 }
        let short: (Date) -> String = { TimeFormat.shortClock($0, calendar: calendar, locale: locale) }
        let liveStart = f.isActive ? f.startedAt : nil

        var sessions: [LaneSession] = []
        for r in input.pastSessions.sorted(by: { $0.start < $1.start }) {
            let s = max(0, t(r.start)), e = min(hours, t(r.resetsAt))
            guard e > s, r.start < now else { continue }
            // The running session comes from the reading; a stored copy of it (its reset drifts) would draw it twice.
            if let live = liveStart, r.resetsAt > live.addingTimeInterval(600) { continue }
            let peak = min(max(r.peakUsed, 0), 1)
            var tip = sessionSpan(r.start, r.resetsAt)
            if r.hitLimit {
                tip += r.hitLimitAt.map { " · hit the limit, paused \(short($0)) until \(short(r.resetsAt))" } ?? " · hit the limit"
            } else {
                tip += " · peaked at \(percent(peak))"
            }
            sessions.append(LaneSession(start: s, end: e, peak: peak, hitLimit: r.hitLimit, tooltip: tip))
        }

        var current: LaneCurrentSession? = nil
        if let s0 = liveStart, let reset = f.resetsAt, t(reset) > 0, t(s0) < hours {
            let level = status?.level ?? SessionLevel(used: f.used, policy: policy)
            let blocked = f.outlook == .blocked
            let projected = blocked ? nil : f.burnPerHour.map { min(1, f.used + $0 * f.timeLeft / 3600) }
            var tip = sessionSpan(s0, reset)
            if blocked {
                let hit = (input.samples[LimitWindow.sessionID()] ?? []).first { $0.used >= 1 && $0.time >= s0 }?.time
                tip += hit.map { " · hit the limit, paused \(short($0)) until \(short(reset))" } ?? " · hit the limit, paused until \(short(reset))"
            } else {
                tip += " · \(percent(f.used)) used so far"
                if let out = f.runsOutAt {
                    tip += " · runs out around \(TimeFormat.clock(out, calendar: calendar, locale: locale))"
                } else if let p = projected {
                    tip += " · about \(percent(p)) used by the reset"
                }
            }
            current = LaneCurrentSession(start: max(0, t(s0)), end: min(hours, t(reset)), used: min(max(f.used, 0), 1),
                                         projectedUsed: projected, runsOutAt: blocked ? nil : f.runsOutAt.map(t).flatMap { $0 <= hours ? $0 : nil },
                                         level: level, tooltip: tip)
        }
        return LimitsLaneModel(kind: .sessions, hours: hours, sessions: sessions, current: current, warnAt: policy.sessionAmber)
    }

    /// Used share at hour `t` along the glide's history (held flat before the first point and after the last).
    nonisolated static func usedAt(_ t: Double, in points: [GlideModel.Point]) -> Double {
        let pts = points.sorted { $0.t < $1.t }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if t <= first.t { return first.used }
        if t >= last.t { return last.used }
        let i = pts.lastIndex { $0.t <= t } ?? 0
        let a = pts[i], b = pts[min(i + 1, pts.count - 1)]
        return b.t > a.t ? a.used + (b.used - a.used) * (t - a.t) / (b.t - a.t) : b.used
    }

    /// The daily-use lane, for plans without a 5-hour window: one bar per local day, the share of the
    /// window that day used (the drop in what's left across it), against an even day's share.
    public func dailyLane(_ g: GlideModel, period: String = "week") -> LimitsLaneModel {
        let hours = max(g.hours, 1)
        var bounds: [Double] = [0]
        var day = calendar.startOfDay(for: g.windowStart)
        while let next = calendar.date(byAdding: .day, value: 1, to: day) {
            day = next
            let h = day.timeIntervalSince(g.windowStart) / 3600
            if h >= hours - 0.01 { break }
            if h > 0.01 { bounds.append(h) }
        }
        bounds.append(hours)
        let days = zip(bounds, bounds.dropFirst()).map { x0, x1 -> LaneDay in
            let even = (x1 - x0) / hours
            let isToday = g.nowT >= x0 && g.nowT < x1
            let name = TimeFormat.weekdayLong(g.windowStart.addingTimeInterval((x0 + x1) / 2 * 3600), calendar: calendar, locale: locale)
            guard x0 < g.nowT else { return LaneDay(start: x0, end: x1, used: nil, even: even, isToday: false, isHeavy: false) }
            let used = max(0, Self.usedAt(min(x1, g.nowT), in: g.points) - Self.usedAt(x0, in: g.points))
            return LaneDay(start: x0, end: x1, used: used, even: even, isToday: isToday, isHeavy: used > even * 1.5,
                           label: used >= 0.005 ? percent(used) : nil,
                           tooltip: "\(name)\(isToday ? " so far" : "") · \(percent(used)) of the \(period) (an even day is \(percent(even)))")
        }
        return LimitsLaneModel(kind: .daily, hours: hours, days: days, warnAt: policy.sessionAmber)
    }

    /// The keys row: the week's line, then what the lane shows.
    public func limitsKeys(state: PacingState, lane: LimitsLaneModel?, period: String = "week") -> [LimitsKey] {
        var keys = [LimitsKey(mark: .line, text: "This \(period)", tone: .state(state))]
        switch lane?.kind {
        case .sessions?:
            keys.append(LimitsKey(mark: .bar, text: "5-hour sessions", tone: .neutral))
            keys.append(LimitsKey(mark: .dash, text: "warns at \(percent(lane?.warnAt ?? policy.sessionAmber))", tone: .amber))
            if (lane?.limitHits ?? 0) > 0 { keys.append(LimitsKey(mark: .cross, text: "limit hit", tone: .rose)) }
        case .daily?:
            keys.append(LimitsKey(mark: .bar, text: "used each day", tone: .neutral))
            keys.append(LimitsKey(mark: .dash, text: "an even day", tone: .faint))
        case nil:
            break
        }
        return keys
    }

    /// Under the chart, only when something applies: the live session runs out before its reset, or it's paused.
    public func chartCaption(_ f: SessionForecast, weekLeft: Double, period: String = "week") -> String? {
        let clock: (Date) -> String = { TimeFormat.clock($0, calendar: calendar, locale: locale) }
        switch f.outlook {
        case .runsOut:
            guard let out = f.runsOutAt, let reset = f.resetsAt else { return nil }
            return "This 5-hour session runs out around \(clock(out)) at this rate, \(Self.hoursMinutes(reset.timeIntervalSince(out))) before the reset."
        case .blocked:
            guard let reset = f.resetsAt else { return nil }
            return "Paused until \(clock(reset)). \(percent(weekLeft)) of the \(period) is still left after it."
        default:
            return nil
        }
    }

    /// The four cells under the chart. With a 5-hour window: week, session, its reset and the limits hit.
    /// Without: week, today, a day's share to last, and the busiest day.
    public func statStrip(_ a: PacingAnalysis, state: PacingState, period: String, lane: LimitsLaneModel,
                          forecast f: SessionForecast?, status: SessionStatus?) -> [StatCell] {
        let week = StatCell(label: period.uppercased(), value: percent(a.remaining), sub: "left", tone: .state(state))
        if let f {
            let level = status?.level ?? .normal
            let tone: StatCell.Tone = switch level {
            case .normal: .plain
            case .amber: .amber
            case .rose, .blocked: .rose
            }
            let session: StatCell = switch f.outlook {
            case .idle: StatCell(label: "5-HOUR", value: "Full", sub: "nothing used")
            case .blocked: StatCell(label: "5-HOUR", value: "Paused", sub: "limit reached", tone: .rose)
            default: StatCell(label: "5-HOUR", value: percent(f.remaining), sub: "left", tone: tone)
            }
            let resets = f.isActive
                ? StatCell(label: "RESETS", value: Self.hoursMinutes(f.timeLeft),
                           sub: f.resetsAt.map { TimeFormat.clock($0, calendar: calendar, locale: locale) } ?? "")
                : StatCell(label: "RESETS", value: "5h", sub: "available")
            let hits = lane.limitHits
            return [week, session, resets, StatCell(label: "LIMITS HIT", value: "\(hits)", sub: "this \(period)", tone: hits > 0 ? .rose : .plain)]
        }
        let today = lane.days.first(where: \.isToday)
        let daysLeft = a.timeLeft / 86400
        let perDay = daysLeft >= 1 ? a.remaining / daysLeft : a.remaining
        let busiest = lane.days.filter { $0.used != nil }.max { ($0.used ?? 0) < ($1.used ?? 0) }
        let busiestName = busiest.map {
            TimeFormat.weekdayLong(a.windowStart.addingTimeInterval(($0.start + $0.end) / 2 * 3600), calendar: calendar, locale: locale)
        }
        return [
            week,
            StatCell(label: "TODAY", value: percent(today?.used ?? 0), sub: "of the \(period)"),
            StatCell(label: "PER DAY", value: percent(perDay), sub: "to renewal"),
            StatCell(label: "BUSIEST", value: busiest.map { percent($0.used ?? 0) } ?? "—", sub: busiestName ?? ""),
        ]
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

    public func percent(_ f: Double) -> String { "\(Int((max(0, f) * 100).rounded()))%" }

    public init(now: Date, calendar: Calendar = Display.calendar, locale: Locale = Display.locale, policy: PacingPolicy = .standard, options: PresentationOptions = PresentationOptions()) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.policy = policy
        self.options = options
    }
}
