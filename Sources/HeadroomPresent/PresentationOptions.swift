import Foundation
import HeadroomKit

/// How the 5-hour session appears on each Pace card.
public enum SessionDetail: String, CaseIterable, Sendable {
    /// Its own panel with a timeline and a forecast; it moves to the top once it warns.
    case detailed
    /// A row in the details list, and a banner once it warns.
    case compact

    public var title: String { self == .detailed ? "Detailed" : "Compact" }
}

/// The optional pieces of a Pace card.
public enum CardPart: String, CaseIterable, Sendable {
    case weekMeter, weekGraph, sessionMeter, sessionGraph
}

/// What the five menu bar cells measure.
public enum MeterFocus: String, CaseIterable, Sendable {
    case week, session, tighter

    public var title: String {
        switch self {
        case .week: "This week"
        case .session: "5-hour session"
        case .tighter: "Whichever is tighter"
        }
    }
}

/// Settings that shape what the cards and the menu bar show.
public struct PresentationOptions: Equatable, Sendable {
    public var sessionDetail: SessionDetail = .detailed
    public var meterFocus: MeterFocus = .week
    public var alwaysShowSessionTimer = false
    public var showPercent = false
    /// Meters and graphs to draw on each Pace card.
    public var parts: Set<CardPart> = Set(CardPart.allCases)

    public init(sessionDetail: SessionDetail = .detailed, meterFocus: MeterFocus = .week, alwaysShowSessionTimer: Bool = false, showPercent: Bool = false, parts: Set<CardPart> = Set(CardPart.allCases)) {
        self.sessionDetail = sessionDetail
        self.meterFocus = meterFocus
        self.alwaysShowSessionTimer = alwaysShowSessionTimer
        self.showPercent = showPercent
        self.parts = parts
    }
}

/// What the menu bar shows for one provider (PLAN §3.5). Hashable: it is the render key.
public struct MenuBarProviderModel: Hashable {
    public var provider: Provider
    public var state: PacingState
    public var cells: Int
    public var hourglass: Bool
    /// Session warning ring + countdown ("48m") while the 5-hour session is ≥ 75%.
    public var session: SessionWarning?
    /// Blocked (session/weekly/model cap at 100%, or major outage): ⏸ + countdown.
    public var blockedCountdown: String?
    public var fault: Bool
    public var spoken: String
    /// "82%" after the meter (Settings).
    public var percent: String? = nil
    /// The cells show the 5-hour session rather than the week.
    public var tracksSession = false

    public struct SessionWarning: Hashable {
        public var level: SessionLevel
        public var used: Double
        public var countdown: String

        public init(level: SessionLevel, used: Double, countdown: String) {
            self.level = level
            self.used = used
            self.countdown = countdown
        }
    }

    public init(provider: Provider, state: PacingState, cells: Int, hourglass: Bool, session: SessionWarning? = nil, blockedCountdown: String? = nil, fault: Bool, spoken: String, percent: String? = nil, tracksSession: Bool = false) {
        self.provider = provider
        self.state = state
        self.cells = cells
        self.hourglass = hourglass
        self.session = session
        self.blockedCountdown = blockedCountdown
        self.fault = fault
        self.spoken = spoken
        self.percent = percent
        self.tracksSession = tracksSession
    }
}

public enum MenuBarMode: String, CaseIterable, Codable, Sendable {
    case both, mostUrgent, claude, codex

    public var title: String {
        switch self {
        case .both: "Both"
        case .mostUrgent: "Most urgent"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
