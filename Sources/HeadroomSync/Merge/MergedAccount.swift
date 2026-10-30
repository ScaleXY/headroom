import Foundation
import HeadroomKit
import HeadroomPresent

/// One Mac that syncs, as readers show it.
public struct DeviceInfo: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var model: String?
    public var appVersion: String
    public var lastSeenAt: Date
    public var state: DevicePowerState
    public var enabledProviders: [Provider]
    /// Merged account ids this Mac reports, signed in now first.
    public var accounts: [String]
    /// Merged account id → why this Mac's last read failed.
    public var faults: [String: Fault]

    /// A laptop or a desktop, for the glyph. Apple silicon model identifiers don't say, so the
    /// computer name ("Athul's MacBook Pro") decides.
    public var isLaptop: Bool { name.localizedCaseInsensitiveContains("book") }

    /// Heard from in the last 30 minutes.
    public func isQuiet(now: Date) -> Bool { now.timeIntervalSince(lastSeenAt) > 30 * 60 }
}

/// One provider account, normalised across every Mac that reports it: the freshest reading, the
/// union of their history, and the sum of their activity.
public struct MergedAccount: Identifiable, Sendable {
    /// `provider:accountKey`.
    public var id: String
    public var provider: Provider
    public var accountKey: String
    public var email: String?
    /// The email, or "Claude · MAX 20×" (with " · 2" when two would read the same).
    public var label: String
    /// "Claude", or "Claude · athul" when there are two Claude accounts.
    public var shortLabel: String
    /// Every Mac that reports this account, newest first.
    public var deviceIDs: [String]
    /// The Mac whose reading is shown.
    public var sourceDevice: String?
    /// The freshest reading, with windows past their reset rolled over.
    public var reading: LimitReading?
    /// A window was rolled over by the clock rather than by a reading.
    public var projected: Bool
    /// History merged from every Mac.
    public var history: AccountHistory
    public var activity: [ActivitySlot]
    public var fault: Fault?
    /// Device ID → that Mac's own fault, when it has one.
    public var deviceFaults: [String: Fault]
    public var smoothedState: PacingState?
    public var policy: PacingPolicy
    public var planMonthlyOverride: Double?
    public var outage: String?
    public var isActive: Bool
    /// The newest word from any Mac about this account.
    public var updatedAt: Date

    /// What the Mac's `AppModel.paceInput(_:)` builds for this account, from the merged parts.
    public func paceInput(now: Date) -> PaceInput {
        var input = PaceInput(provider: provider, reading: reading)
        input.fault = fault
        guard let reading else { return input }
        input.samples = history.windows.mapValues(\.samples)
        if let session = history.session { input.samples[LimitWindow.sessionID()] = session.samples }
        let since = now.addingTimeInterval(-(Presenter.sessionTrailHours + 5) * 3600)
        input.pastSessions = history.finishedSessions(since: since, now: now)
        input.smoothedState = projected ? nil : smoothedState
        if let early = history.earlyResetAt, let start = reading.headline?.windowStart, early >= start { input.earlyResetAt = early }
        if let start = reading.headline?.windowStart { input.weekCostMicros = micros(from: start, to: now) }
        input.planMonthlyOverride = planMonthlyOverride
        return input
    }

    /// Cost in [from, to), on quarter-hour slots.
    public func micros(from: Date, to: Date) -> Int64 {
        let a = ActivitySlot.slot(for: from), b = ActivitySlot.slot(for: to)
        return activity.reduce(0) { $1.slot >= a && $1.slot < b ? $0 + $1.micros : $0 }
    }

    /// Bins over consecutive `edges`, as `UsageBuckets.series` cuts them.
    public func bins(edges: [Date]) -> [HourTotal] {
        guard edges.count >= 2 else { return [] }
        let bounds = edges.map(ActivitySlot.slot(for:))
        var out = [HourTotal](repeating: HourTotal(tokens: 0, dollars: 0), count: edges.count - 1)
        var micros = [Int64](repeating: 0, count: edges.count - 1)
        for s in activity where s.slot >= bounds.first! && s.slot < bounds.last! {
            var l = 0, r = bounds.count - 1
            while r - l > 1 {
                let m = (l + r) / 2
                if bounds[m] <= s.slot { l = m } else { r = m }
            }
            out[l].tokens += s.tokens.total
            micros[l] += s.micros
        }
        for i in out.indices { out[i].dollars = Double(micros[i]) / 1_000_000 }
        return out
    }

    /// The Activity tab's input, in the shape the Mac's bucket store hands `ActivityPresenter`.
    public var aggregates: [HourAggregate] {
        activity.map { s in
            HourAggregate(provider: provider, hour: s.start, model: s.model, project: nil, tokens: s.tokens, micros: s.micros,
                          priced: s.unpricedTokens == 0,
                          classMicros: ClassMicros(input: s.classMicros.count > 0 ? s.classMicros[0] : 0,
                                                   cacheWrite: s.classMicros.count > 1 ? s.classMicros[1] : 0,
                                                   cacheRead: s.classMicros.count > 2 ? s.classMicros[2] : 0,
                                                   output: s.classMicros.count > 3 ? s.classMicros[3] : 0))
        }
    }
}

/// Everything readers show, merged.
public struct SyncSnapshot: Sendable {
    /// Active accounts first, each group most recently updated first.
    public var accounts: [MergedAccount]
    public var devices: [DeviceInfo]
    public var unreadable: Int
    public var tooNew: Int
    /// The newest heartbeat from any Mac.
    public var lastHeard: Date?

    public init(accounts: [MergedAccount] = [], devices: [DeviceInfo] = [], unreadable: Int = 0, tooNew: Int = 0, lastHeard: Date? = nil) {
        self.accounts = accounts; self.devices = devices; self.unreadable = unreadable; self.tooNew = tooNew; self.lastHeard = lastHeard
    }

    public func account(_ id: String) -> MergedAccount? { accounts.first { $0.id == id } }
    public func device(_ id: String) -> DeviceInfo? { devices.first { $0.id == id } }
}
