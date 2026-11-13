import Foundation

/// What a provider is spending right now across every session on this Mac, from the app's own
/// usage logs. The basis for a run's share of the spend, and for turning the 5-hour window's
/// percent into tokens. Counts new tokens (input, cache writes, output), as runs do.
public struct ProviderSpend: Sendable, Hashable {
    /// New tokens an hour over the recent past (the last 45 minutes or so).
    public var tokensPerHour: Double
    /// New tokens spent since the current 5-hour window began, when its start is known.
    public var windowTokens: Int64?

    public init(tokensPerHour: Double, windowTokens: Int64? = nil) {
        self.tokensPerHour = tokensPerHour; self.windowTokens = windowTokens
    }
}

/// Reads a folded run against the allowance it spends: a run whose provider is blocked is
/// waiting on that limit, and a live run gets an outlook: when the 5-hour window runs out under
/// it, when it resets, when the run finishes counting the pause, and its share of the spend.
public enum TaskLimits {
    /// The providers the run spends while it isn't finished: its harness's, and each active attempt's.
    public static func providers(of run: TaskRun) -> Set<Provider> {
        guard !run.state.isTerminal else { return [] }
        var out: Set<Provider> = []
        if let p = provider(named: run.harness) { out.insert(p) }
        for n in run.nodes where n.attempts.active > 0 {
            if let p = provider(named: n.attempts.last?.provider) { out.insert(p) }
        }
        return out
    }

    /// One line telling an agent how much room `provider`'s 5-hour window has left, e.g.
    /// "5-hour window 38% left, resets 3 PM"; nil when unknown. The CLI appends it to its echo.
    public static func roomLine(_ provider: Provider, providers snapshots: [ProviderSnapshot], now: Date,
                                calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let s = snapshots.first(where: { $0.id == provider }) else { return nil }
        let clock = { TimeFormat.shortClock($0, calendar: calendar, locale: locale) }
        if let b = s.blocked, b.by == "session" || b.by == "weekly", b.until.map({ $0 > now }) ?? true {
            let which = b.by == "weekly" ? "Weekly limit" : "5-hour window"
            return "\(which) used up" + (b.until.map { ", back \(TimeFormat.shortDayTime($0, now: now, calendar: calendar, locale: locale))" } ?? "")
        }
        guard let session = s.session else { return nil }
        let left = Int((max(0, min(1, session.left)) * 100).rounded())
        var line = "5-hour window \(left)% left"
        if let reset = session.resetsAt, reset > now { line += ", resets \(clock(reset))" }
        if let out = session.runsOutAt, out > now, session.resetsAt.map({ out < $0 }) ?? true {
            line += "; at this pace it runs out around \(clock(out))"
        }
        return line
    }

    /// `claude`, `claude-code`, `anthropic` and `codex`, `openai`; nil for anything else.
    public static func provider(named name: String?) -> Provider? {
        guard let n = name?.lowercased(), !n.isEmpty else { return nil }
        if n.hasPrefix("claude") || n == "anthropic" { return .claude }
        if n.hasPrefix("codex") || n == "openai" { return .codex }
        return nil
    }

    /// Fills `warning` and `limitOutlook`, and makes a running or waiting run whose provider is
    /// blocked wait for `limit` (a stopped run stays stopped: nothing is spending). The first
    /// blocked provider wins; otherwise the outlook of the provider whose window runs out first.
    /// `spend` is each provider's current spend on this Mac (`ProviderSpend`), when known.
    public static func adjust(_ run: TaskRun, providers snapshots: [ProviderSnapshot], spend: [Provider: ProviderSpend] = [:], now: Date,
                              calendar: Calendar = .current, locale: Locale = .current) -> TaskRun {
        var r = run
        let used = providers(of: run)
        guard !used.isEmpty else { return r }
        let live = run.state == .running || run.state == .waiting
        let relevant = snapshots.filter { used.contains($0.id) }.sorted { $0.id < $1.id }
        for s in relevant {
            guard let b = s.blocked, b.until.map({ $0 > now }) ?? true else { continue }
            let what: String
            switch b.by {
            case "session": what = "\(s.id.displayName) 5-hour limit reached"
            case "weekly": what = "\(s.id.displayName) weekly limit reached"
            case "outage": what = "\(s.id.displayName) is having an outage"
            default: what = "\(s.id.displayName) \(b.detail ?? "model") limit reached"
            }
            r.warning = what + (b.until.map { ", back \(TimeFormat.shortDayTime($0, now: now, calendar: calendar, locale: locale))" } ?? "") + "."
            if live {
                if r.waitReason != .input { r.state = .waiting; r.waitReason = .limit }
                r.limitOutlook = outlook(run, snapshot: s, spend: spend[s.id], now: now)
            }
            return r
        }
        guard live else { return r }
        // Each provider the run spends, the one whose window gives out first leading.
        let outlooks = relevant.compactMap { s in outlook(run, snapshot: s, spend: spend[s.id], now: now).map { (s, $0) } }
        let primary = provider(named: run.harness)
        let lead = outlooks.filter { $0.1.pauseAt != nil }.min { $0.1.pauseAt! < $1.1.pauseAt! }
            ?? outlooks.first { $0.0.id == primary } ?? outlooks.first
        r.limitOutlook = lead?.1
        if let (s, o) = lead, let pause = o.pauseAt, let finish = unpausedFinish(run, now: now) {
            // The sentence older surfaces show: the finish here is the one without the pause.
            let clock = { TimeFormat.shortClock($0, calendar: calendar, locale: locale) }
            r.warning = "\(s.id.displayName) 5-hour limit will likely run out first: around \(clock(pause)), finish around \(clock(finish))."
        }
        return r
    }

    /// When the run would finish if nothing stopped it: its remaining tokens at its recent rate,
    /// else the fold's forecast.
    static func unpausedFinish(_ run: TaskRun, now: Date) -> Date? {
        if let need = run.tokensToFinish, let rate = run.recentTokensPerHour, rate > 0 {
            return now.addingTimeInterval(max(0, Double(need)) / rate * 3600)
        }
        return run.etaSeconds.map { now.addingTimeInterval(max(0, $0)) }
    }

    /// How a live run sits against one provider's 5-hour window. Nil when nothing is known.
    static func outlook(_ run: TaskRun, snapshot s: ProviderSnapshot, spend: ProviderSpend?, now: Date) -> TaskLimitOutlook? {
        var o = TaskLimitOutlook(provider: s.id)
        let rate = run.recentTokensPerHour.flatMap { $0 > 0 ? $0 : nil }
        let total = spend.map(\.tokensPerHour).flatMap { $0 > 0 ? $0 : nil }
        if let rate, let total { o.share = min(1, rate / max(total, rate)) } else if rate != nil, spend != nil { o.share = 1 }
        o.tokensNeeded = run.tokensToFinish.map { max(0, $0) }
        let session = s.session
        // The window's size in tokens, from what this Mac spent in it against the percent used.
        if let session, let w = spend?.windowTokens, w > 0, session.used >= 0.05 {
            o.roomTokens = Int64((Double(w) / session.used * max(0, session.left)).rounded())
        }
        let reset = session?.resetsAt.flatMap { $0 > now ? $0 : nil }
        let finish = unpausedFinish(run, now: now)

        if let b = s.blocked, b.until.map({ $0 > now }) ?? true {
            // Already paused: it picks up when the block lifts.
            o.pauseAt = now
            o.resumeAt = b.until
            if let finish, let until = b.until { o.finishAt = until.addingTimeInterval(finish.timeIntervalSince(now)) }
        } else {
            // When the window gives out at the provider's current pace, if before it resets.
            var out = session?.runsOutAt.flatMap { $0 > now ? $0 : nil }
            if out == nil, let room = o.roomTokens, let total {
                out = now.addingTimeInterval(Double(room) / total * 3600)
            }
            if let o2 = out, let reset, o2 >= reset { out = nil }
            if let finish, let out, out < finish {
                o.pauseAt = out
                o.resumeAt = reset
                o.finishAt = reset.map { $0.addingTimeInterval(finish.timeIntervalSince(out)) }
            } else {
                o.finishAt = finish
            }
        }
        let empty = o.pauseAt == nil && o.finishAt == nil && o.share == nil && o.roomTokens == nil && o.tokensNeeded == nil
        return empty ? nil : o
    }
}
