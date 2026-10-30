import Foundation
import HeadroomKit

// What a Mac posts to iCloud, one payload per record. Every field decodes leniently: a field that
// is missing or no longer parses takes its default, so payloads from older and newer apps still
// read (see the decode-old-format fixtures in `HeadroomSyncTests`). Never add a required field.

/// The payload format readers understand. Bump only for a change older readers can't skip over.
public enum PayloadVersion {
    public static let current = 1
}

/// A glide series, kept exact so the phone draws what the Mac draws.
public struct SeriesPayload: Codable, Sendable, Hashable {
    /// Seconds since 1970.
    public var t: [Double]
    /// Used share, 0…1.
    public var u: [Double]

    public init(_ samples: [UsageSample]) {
        t = samples.map(\.time.timeIntervalSince1970)
        u = samples.map(\.used)
    }

    public var samples: [UsageSample] {
        zip(t, u).map { UsageSample(time: Date(timeIntervalSince1970: $0), used: $1) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = c.lenient(.t, [Double]())
        let u = c.lenient(.u, [Double]())
        let n = min(t.count, u.count)
        self.t = Array(t.prefix(n))
        self.u = Array(u.prefix(n))
    }
}

/// One window's history on one Mac: the week, a model cap, or the 5-hour session in progress.
public struct WindowPayload: Codable, Sendable, Hashable {
    public var id: String
    public var resetsAt: Date
    public var duration: TimeInterval
    public var series: SeriesPayload

    public init(_ w: WindowHistory) {
        id = w.id; resetsAt = w.resetsAt; duration = w.duration; series = SeriesPayload(w.samples)
    }

    public var history: WindowHistory {
        var w = WindowHistory(id: id, resetsAt: resetsAt, duration: duration)
        w.samples = series.samples
        return w
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        resetsAt = try c.decode(Date.self, forKey: .resetsAt)
        duration = c.lenient(.duration, 7 * 86400)
        series = c.lenient(.series, SeriesPayload([]))
    }
}

/// Whether a Mac is awake, as it last said.
public enum DevicePowerState: String, Codable, Sendable, Hashable {
    case awake, sleeping, quitting
}

/// One Mac: who it is and the settings readers need to match it exactly.
public struct DevicePayload: Codable, Sendable, Hashable {
    public var v = PayloadVersion.current
    /// The computer name ("Athul's MacBook Pro").
    public var name: String
    /// `hw.model` ("Mac15,3").
    public var model: String?
    public var appVersion: String
    public var enabledProviders: [Provider]
    /// Provider raw value → the account signed in on this Mac now.
    public var currentAccounts: [String: String]
    /// The 5-hour warning level from Settings.
    public var sessionWarnAt: Double
    /// Provider raw value → monthly plan price set in Settings.
    public var planPriceOverrides: [String: Double]
    /// Provider raw value → major outage text.
    public var outages: [String: String]
    public var state: DevicePowerState
    /// When this Mac turned sync on.
    public var syncSince: Date?

    public init(name: String, model: String?, appVersion: String, enabledProviders: [Provider], currentAccounts: [String: String],
                sessionWarnAt: Double, planPriceOverrides: [String: Double], outages: [String: String], state: DevicePowerState,
                syncSince: Date?) {
        self.name = name; self.model = model; self.appVersion = appVersion; self.enabledProviders = enabledProviders
        self.currentAccounts = currentAccounts; self.sessionWarnAt = sessionWarnAt; self.planPriceOverrides = planPriceOverrides
        self.outages = outages; self.state = state; self.syncSince = syncSince
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.lenient(.v, PayloadVersion.current)
        name = c.lenient(.name, "Mac")
        model = c.lenient(.model, nil)
        appVersion = c.lenient(.appVersion, "")
        enabledProviders = c.lenient(.enabledProviders, [String]()).compactMap(Provider.init(rawValue:))
        currentAccounts = c.lenient(.currentAccounts, [:])
        sessionWarnAt = c.lenient(.sessionWarnAt, 0.75)
        planPriceOverrides = c.lenient(.planPriceOverrides, [:])
        outages = c.lenient(.outages, [:])
        state = c.lenient(.state, .awake)
        syncSince = c.lenient(.syncSince, nil)
    }

    /// The pacing policy this Mac draws with.
    public var policy: PacingPolicy { .sessionWarning(at: sessionWarnAt) }
}

/// One account as one Mac sees it now: the latest reading and the current windows' history.
public struct AccountLivePayload: Codable, Sendable, Hashable {
    public var v = PayloadVersion.current
    public var reading: LimitReading?
    /// Why the last read failed, when it did.
    public var fault: Fault?
    public var faultAt: Date?
    /// The state the Mac's tracker shows (smoothed against flicker).
    public var shownState: PacingState?
    public var headlineID: String?
    public var earlyResetAt: Date?
    public var sessionHitsThisWindow: Int
    public var planThisWindow: String?
    /// Long windows (the week and any model caps).
    public var windows: [WindowPayload]
    /// The 5-hour session in progress.
    public var session: WindowPayload?
    /// Signed in on this Mac now.
    public var isCurrent: Bool
    /// The account's email, when the provider exposes it.
    public var email: String?

    public init(reading: LimitReading?, fault: Fault?, faultAt: Date?, shownState: PacingState?, headlineID: String?, earlyResetAt: Date?,
                sessionHitsThisWindow: Int, planThisWindow: String?, windows: [WindowPayload], session: WindowPayload?, isCurrent: Bool,
                email: String?) {
        self.reading = reading; self.fault = fault; self.faultAt = faultAt; self.shownState = shownState; self.headlineID = headlineID
        self.earlyResetAt = earlyResetAt; self.sessionHitsThisWindow = sessionHitsThisWindow; self.planThisWindow = planThisWindow
        self.windows = windows; self.session = session; self.isCurrent = isCurrent; self.email = email
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.lenient(.v, PayloadVersion.current)
        reading = c.lenient(.reading, nil)
        fault = c.lenient(.fault, nil)
        faultAt = c.lenient(.faultAt, nil)
        shownState = c.lenient(.shownState, nil)
        headlineID = c.lenient(.headlineID, nil)
        earlyResetAt = c.lenient(.earlyResetAt, nil)
        sessionHitsThisWindow = c.lenient(.sessionHitsThisWindow, 0)
        planThisWindow = c.lenient(.planThisWindow, nil)
        windows = c.lenientArray(.windows)
        session = c.lenient(.session, nil)
        isCurrent = c.lenient(.isCurrent, false)
        email = c.lenient(.email, nil)
    }
}

/// One account's finished weeks and 5-hour sessions as one Mac recorded them.
public struct AccountArchivePayload: Codable, Sendable, Hashable {
    public var v = PayloadVersion.current
    public var weeks: [WeekRecord]
    public var sessions: [SessionRecord]

    public init(weeks: [WeekRecord], sessions: [SessionRecord]) { self.weeks = weeks; self.sessions = sessions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.lenient(.v, PayloadVersion.current)
        weeks = c.lenientArray(.weeks)
        sessions = c.lenientArray(.sessions)
    }
}

/// Usage in one quarter-hour for one model, read from one Mac's logs. Never carries a project.
public struct ActivitySlot: Codable, Sendable, Hashable {
    /// `floor(epochSeconds / 900)`, as the Mac's bucket store keys it.
    public var slot: Int
    public var model: String
    public var tokens: TokenCounts
    /// API-equivalent cost in micro-dollars.
    public var micros: Int64
    /// Tokens on models with no price (in `tokens`, not in `micros`).
    public var unpricedTokens: Int64
    /// Micro-dollars by token class: input, cache write, cache read, output.
    public var classMicros: [Int64]

    public static let seconds = 900

    public init(slot: Int, model: String, tokens: TokenCounts, micros: Int64, unpricedTokens: Int64, classMicros: [Int64]) {
        self.slot = slot; self.model = model; self.tokens = tokens; self.micros = micros
        self.unpricedTokens = unpricedTokens; self.classMicros = classMicros
    }

    public var start: Date { Date(timeIntervalSince1970: TimeInterval(slot * Self.seconds)) }
    public var day: Int { Int((Double(slot * Self.seconds) / 86400).rounded(.down)) }
    public static func slot(for date: Date) -> Int { Int((date.timeIntervalSince1970 / Double(seconds)).rounded(.down)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(Int.self, forKey: .slot)
        model = c.lenient(.model, "unknown")
        tokens = c.lenient(.tokens, .zero)
        micros = c.lenient(.micros, 0)
        unpricedTokens = c.lenient(.unpricedTokens, 0)
        classMicros = c.lenient(.classMicros, [0, 0, 0, 0])
    }
}

/// One UTC day of one account's activity on one Mac.
public struct ActivityDayPayload: Codable, Sendable, Hashable {
    public var v = PayloadVersion.current
    /// `floor(epochSeconds / 86400)`.
    public var day: Int
    public var slots: [ActivitySlot]

    public init(day: Int, slots: [ActivitySlot]) { self.day = day; self.slots = slots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.lenient(.v, PayloadVersion.current)
        day = c.lenient(.day, 0)
        slots = c.lenientArray(.slots)
    }
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when it's missing or doesn't parse.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// The elements at `key` that parse, skipping any that don't.
    func lenientArray<T: Decodable>(_ key: Key) -> [T] {
        guard var items = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [T] = []
        while !items.isAtEnd {
            if let item = try? items.decode(T.self) { out.append(item) } else { _ = try? items.decode(Skip.self) }
        }
        return out
    }
}

/// Consumes one element of any shape.
private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}
