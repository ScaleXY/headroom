import Foundation

/// Reads a folded run against the allowance it spends: a run whose provider is blocked is
/// waiting on that limit, and one forecast to outlast the 5-hour session gets a warning.
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

    /// `claude`, `claude-code`, `anthropic` and `codex`, `openai`; nil for anything else.
    public static func provider(named name: String?) -> Provider? {
        guard let n = name?.lowercased(), !n.isEmpty else { return nil }
        if n.hasPrefix("claude") || n == "anthropic" { return .claude }
        if n.hasPrefix("codex") || n == "openai" { return .codex }
        return nil
    }

    /// Fills `warning` (and makes a blocked run wait for `limit`). The first blocked provider
    /// wins; otherwise the first whose 5-hour session runs out before the forecast finish.
    public static func adjust(_ run: TaskRun, providers snapshots: [ProviderSnapshot], now: Date,
                              calendar: Calendar = .current, locale: Locale = .current) -> TaskRun {
        var r = run
        let used = providers(of: run)
        guard !used.isEmpty else { return r }
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
            if r.waitReason != .input { r.state = .waiting; r.waitReason = .limit }
            return r
        }
        guard let eta = run.etaSeconds else { return r }
        let finish = now.addingTimeInterval(eta)
        for s in relevant {
            guard let out = s.session?.runsOutAt, out > now, out < finish else { continue }
            let clock = { TimeFormat.shortClock($0, calendar: calendar, locale: locale) }
            r.warning = "\(s.id.displayName) 5-hour limit will likely run out first: around \(clock(out)), finish around \(clock(finish))."
            return r
        }
        return r
    }
}
