import Foundation

/// `widgets.json`: what the desktop widgets draw, written by the app next to `snapshot.json`.
/// Unlike the snapshot it isn't a public schema: it carries the graphs and burn rates the widgets
/// need, already reduced to a few hundred points, and changes with them.
public struct WidgetFeed: Codable, Sendable, Hashable {
    public static let currentSchema = 1

    public var schema: Int
    public var generatedAt: Date
    public var providers: [WidgetProvider]

    public init(generatedAt: Date, providers: [WidgetProvider]) {
        self.schema = Self.currentSchema
        self.generatedAt = generatedAt
        self.providers = providers
    }

    public func provider(_ p: Provider) -> WidgetProvider? { providers.first { $0.id == p } }

    /// The provider a one-provider widget shows: the one that needs watching most.
    public var focus: WidgetProvider? {
        providers.filter { $0.week != nil || $0.session != nil }.max { $0.urgency < $1.urgency } ?? providers.first
    }

    // MARK: File

    public static let fileName = "widgets.json"

    /// `~/Library/Application Support/Headroom/widgets.json` in the user's real home, also from
    /// inside the sandboxed widget extension (whose own home is its container).
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent(fileName)
        }
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func read(from url: URL = url) -> WidgetFeed? {
        guard let data = try? Data(contentsOf: url),
              let feed = try? SnapshotFile.decoder().decode(WidgetFeed.self, from: data),
              feed.schema == currentSchema else { return nil }
        return feed
    }
}

public struct WidgetProvider: Codable, Sendable, Hashable {
    public var id: Provider
    /// Plan pill text ("MAX 20×").
    public var plan: String?
    public var readingAt: Date?
    /// Why the last read failed, when it did.
    public var fault: String?
    public var week: WidgetWeek?
    public var session: WidgetSession?
    /// Tokens in each of the last 24 hours, oldest first.
    public var hourlyTokens: [Int64]
    public var tokens24h: Int64
    public var cost24hUSD: Double
    public var weekCostUSD: Double?
    /// Blocked by a limit (or an outage) until then.
    public var blockedUntil: Date?

    public init(id: Provider, plan: String? = nil, readingAt: Date? = nil, fault: String? = nil, week: WidgetWeek? = nil,
                session: WidgetSession? = nil, hourlyTokens: [Int64] = [], tokens24h: Int64 = 0, cost24hUSD: Double = 0,
                weekCostUSD: Double? = nil, blockedUntil: Date? = nil) {
        self.id = id; self.plan = plan; self.readingAt = readingAt; self.fault = fault; self.week = week; self.session = session
        self.hourlyTokens = hourlyTokens; self.tokens24h = tokens24h; self.cost24hUSD = cost24hUSD
        self.weekCostUSD = weekCostUSD; self.blockedUntil = blockedUntil
    }

    /// How pressing this provider is: blocked, then the hotter burn, then the tighter state.
    var urgency: Double {
        if blockedUntil != nil { return 100 }
        let burns = [week?.burn, session?.burn].compactMap { $0?.ratio }.filter(\.isFinite)
        let state = Double(week?.state.rawValue ?? 0)
        return state * 2 + (burns.max() ?? 0)
    }
}

/// The weekly (or monthly) allowance: the popover's hero, meter, graph and verdict.
public struct WidgetWeek: Codable, Sendable, Hashable {
    /// "left this week", "left this week · Fable".
    public var caption: String
    public var left: Double
    public var state: PacingState
    /// Sustainable multiple S; nil in the last hour.
    public var multiple: Double?
    public var cells: Int
    /// Even-pace position along the meter, nil to hide.
    public var caret: Double?
    public var resetsAt: Date
    public var hourglass: Bool
    public var verdictTitle: String
    public var verdict: String
    public var burn: WidgetBurn
    public var chart: WidgetChart?

    public init(caption: String, left: Double, state: PacingState, multiple: Double?, cells: Int, caret: Double?, resetsAt: Date,
                hourglass: Bool, verdictTitle: String, verdict: String, burn: WidgetBurn, chart: WidgetChart?) {
        self.caption = caption; self.left = left; self.state = state; self.multiple = multiple; self.cells = cells
        self.caret = caret; self.resetsAt = resetsAt; self.hourglass = hourglass; self.verdictTitle = verdictTitle
        self.verdict = verdict; self.burn = burn; self.chart = chart
    }
}

/// The 5-hour session: where it stands, where it's heading, and the last day of sessions.
public struct WidgetSession: Codable, Sendable, Hashable {
    public var used: Double
    public var resetsAt: Date?
    public var startedAt: Date?
    public var level: SessionLevel
    public var outlook: SessionForecast.Outlook
    public var runsOutAt: Date?
    public var leftAtReset: Double?
    public var burn: WidgetBurn
    /// The 24-hour trail (dips and refills), nil without history.
    public var chart: WidgetChart?

    public init(used: Double, resetsAt: Date?, startedAt: Date?, level: SessionLevel, outlook: SessionForecast.Outlook, runsOutAt: Date?,
                leftAtReset: Double?, burn: WidgetBurn, chart: WidgetChart?) {
        self.used = used; self.resetsAt = resetsAt; self.startedAt = startedAt; self.level = level; self.outlook = outlook
        self.runsOutAt = runsOutAt; self.leftAtReset = leftAtReset; self.burn = burn; self.chart = chart
    }

    public var left: Double { max(0, 1 - used) }
    public var isIdle: Bool { outlook == .idle }
}

/// How fast an allowance is burning, against the rate that would last exactly to its reset.
public struct WidgetBurn: Codable, Sendable, Hashable {
    /// Used fraction per hour right now (recent burn).
    public var perHour: Double?
    /// The longer average (24 hours for the week, the session so far for 5 hours).
    public var averagePerHour: Double?
    /// The rate that lands at 0% exactly at the reset: what's left ÷ hours left.
    public var lastingPerHour: Double?

    public init(perHour: Double?, averagePerHour: Double?, lastingPerHour: Double?) {
        self.perHour = perHour; self.averagePerHour = averagePerHour; self.lastingPerHour = lastingPerHour
    }

    /// `perHour ÷ lastingPerHour`: 1 runs out right at the reset, 2 in half the time left.
    /// `.infinity` once nothing is left; nil without a burn reading.
    public var ratio: Double? { BurnGauge.ratio(perHour, lasting: lastingPerHour) }
    public var averageRatio: Double? { BurnGauge.ratio(averagePerHour, lasting: lastingPerHour) }
}

/// A glide graph: used share over time, with a dotted projection from now.
public struct WidgetChart: Codable, Sendable, Hashable {
    public var start: Date
    public var hours: Double
    public var nowT: Double
    public var points: [WidgetPoint]
    public var endT: Double
    public var endRemaining: Double
    public var runsOut: Bool
    /// Where the even-pace diagonal starts (it ends at `hours`); nil hides it.
    public var evenFrom: Double?

    public init(start: Date, hours: Double, nowT: Double, points: [WidgetPoint], endT: Double, endRemaining: Double,
                runsOut: Bool, evenFrom: Double?) {
        self.start = start; self.hours = hours; self.nowT = nowT; self.points = points; self.endT = endT
        self.endRemaining = endRemaining; self.runsOut = runsOut; self.evenFrom = evenFrom
    }
}

public struct WidgetPoint: Codable, Sendable, Hashable {
    /// Hours since the chart's start.
    public var t: Double
    /// Used share.
    public var u: Double
    /// A reset: the line steps back up here.
    public var refill: Bool?

    public init(t: Double, u: Double, refill: Bool = false) {
        self.t = (t * 1000).rounded() / 1000
        self.u = (u * 10000).rounded() / 10000
        self.refill = refill ? true : nil
    }
}

/// The Burn-o-meter's scale: how fast you're spending against the pace that lasts to the reset.
public enum BurnGauge {
    /// The dial's last mark: 3× the lasting pace.
    public static let maxRatio = 3.0

    public static func ratio(_ perHour: Double?, lasting: Double?) -> Double? {
        guard let perHour, let lasting else { return nil }
        if lasting <= 0 { return perHour > 0 || lasting == 0 ? .infinity : nil }
        return max(0, perHour) / lasting
    }

    /// Zones on the dial, as pacing colors: cruising (azure) while it lasts with room to spare,
    /// on pace (pearl) near 1×, then amber, then the rose redline from 1.6×.
    public static func state(_ ratio: Double) -> PacingState {
        switch ratio {
        case ..<0.8: .plenty
        case ..<1.05: .onPace
        case ..<1.6: .tight
        default: .veryTight
        }
    }

    /// Zone edges in ratio terms, for drawing the bands.
    public static let zones: [(from: Double, to: Double, state: PacingState)] = [
        (0, 0.8, .plenty), (0.8, 1.05, .onPace), (1.05, 1.6, .tight), (1.6, maxRatio, .veryTight),
    ]

    /// Reduces a series to about `limit` points for the widgets, keeping every reset.
    public static func thin(_ points: [WidgetPoint], limit: Int) -> [WidgetPoint] {
        guard points.count > limit, limit > 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        var keep = Set((0..<limit).map { Int((Double($0) * step).rounded()) })
        for (i, p) in points.enumerated() where p.refill == true {
            keep.insert(i)
            if i > 0 { keep.insert(i - 1) }
        }
        return keep.sorted().map { points[$0] }
    }
}
