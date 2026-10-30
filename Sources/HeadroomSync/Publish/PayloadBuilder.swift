import Foundation
import HeadroomKit

/// Turns what a Mac knows into payloads. Pure: the Mac's publisher, the demo fixtures and the
/// tests all build records the same way.
public enum PayloadBuilder {
    public static func live(reading: LimitReading?, history: AccountHistory?, fault: Fault?, faultAt: Date?, isCurrent: Bool,
                            email: String?) -> AccountLivePayload {
        let h = history ?? AccountHistory()
        return AccountLivePayload(
            reading: reading, fault: fault, faultAt: fault == nil ? nil : faultAt, shownState: h.tracker?.shown, headlineID: h.headlineID,
            earlyResetAt: h.earlyResetAt, sessionHitsThisWindow: h.sessionHitsThisWindow, planThisWindow: h.planThisWindow,
            windows: h.windows.values.sorted { $0.id < $1.id }.map(WindowPayload.init), session: h.session.map(WindowPayload.init),
            isCurrent: isCurrent, email: email)
    }

    public static func archive(_ history: AccountHistory) -> AccountArchivePayload {
        AccountArchivePayload(weeks: history.weeks, sessions: history.sessions)
    }

    /// Slots grouped into one payload per account and UTC day.
    public static func activityDays(_ slots: [(provider: Provider, accountKey: String, slot: ActivitySlot)]) -> [ActivityDayKey: ActivityDayPayload] {
        var days: [ActivityDayKey: [ActivitySlot]] = [:]
        for s in slots where s.slot.tokens.total > 0 || s.slot.micros > 0 {
            days[ActivityDayKey(provider: s.provider, accountKey: s.accountKey, day: s.slot.day), default: []].append(s.slot)
        }
        return days.mapValues { list in
            ActivityDayPayload(day: list[0].day, slots: list.sorted { ($0.slot, $0.model) < ($1.slot, $1.model) })
        }
    }

    /// The key for an account the provider didn't identify. It belongs to one Mac and never merges.
    public static func deviceScopedKey(_ provider: Provider, deviceID: String) -> String {
        provider.rawValue + "-device-" + deviceID
    }
}

public struct ActivityDayKey: Hashable, Sendable {
    public var provider: Provider
    public var accountKey: String
    public var day: Int

    public init(provider: Provider, accountKey: String, day: Int) { self.provider = provider; self.accountKey = accountKey; self.day = day }
}

/// When each provider's signed-in account changed on a Mac. Logs carry no account, so activity is
/// attributed to whichever account was signed in at the time.
public struct AccountTimeline: Codable, Sendable, Hashable {
    public struct Span: Codable, Sendable, Hashable {
        public var since: Date
        public var accountKey: String
        public init(since: Date, accountKey: String) { self.since = since; self.accountKey = accountKey }
    }

    /// Provider raw value → spans, oldest first.
    public var spans: [String: [Span]] = [:]

    public init() {}

    /// Notes the account seen at `at`. Returns whether it changed.
    @discardableResult
    public mutating func record(_ provider: Provider, accountKey: String, at: Date) -> Bool {
        var list = spans[provider.rawValue] ?? []
        if list.last?.accountKey == accountKey { return false }
        list.append(Span(since: at, accountKey: accountKey))
        spans[provider.rawValue] = list
        return true
    }

    /// The account signed in at `date`. Before the first span, the first span's account.
    public func account(_ provider: Provider, at date: Date) -> String? {
        guard let list = spans[provider.rawValue], let first = list.first else { return nil }
        return list.last { $0.since <= date }?.accountKey ?? first.accountKey
    }

    /// Forgets spans that ended before `date`, keeping the one in force then.
    public mutating func prune(before date: Date) {
        for (p, list) in spans {
            guard let keepFrom = list.lastIndex(where: { $0.since <= date }), keepFrom > 0 else { continue }
            spans[p] = Array(list[keepFrom...])
        }
    }
}
