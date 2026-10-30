import HeadroomKit
import SwiftUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What the 5-hour session Live Activity shows. Small (well under ActivityKit's 4 KB), and built
/// so the activity stays right between updates: the countdown ticks on its own and the forecast
/// is a fixed time, not a moving duration.
public struct SessionActivityState: Codable, Hashable, Sendable {
    public var used: Double
    public var resetsAt: Date
    public var startedAt: Date?
    public var level: SessionLevel
    public var outlook: SessionForecast.Outlook
    public var runsOutAt: Date?
    public var leftAtReset: Double?
    public var weekLeft: Double?
    public var weekState: PacingState?
    public var updatedAt: Date
    public var sourceDevice: String?

    public init(used: Double, resetsAt: Date, startedAt: Date?, level: SessionLevel, outlook: SessionForecast.Outlook, runsOutAt: Date?,
                leftAtReset: Double?, weekLeft: Double?, weekState: PacingState?, updatedAt: Date, sourceDevice: String?) {
        self.used = used; self.resetsAt = resetsAt; self.startedAt = startedAt; self.level = level; self.outlook = outlook
        self.runsOutAt = runsOutAt; self.leftAtReset = leftAtReset; self.weekLeft = weekLeft; self.weekState = weekState
        self.updatedAt = updatedAt; self.sourceDevice = sourceDevice
    }

    /// The state for an account in the feed, or nil when no session is running.
    public static func from(_ p: WidgetProvider, generatedAt: Date) -> SessionActivityState? {
        guard let s = p.session, let resetsAt = s.resetsAt, !s.isIdle else { return nil }
        return SessionActivityState(used: s.used, resetsAt: resetsAt, startedAt: s.startedAt, level: s.level, outlook: s.outlook,
                                    runsOutAt: s.runsOutAt, leftAtReset: s.leftAtReset, weekLeft: p.week?.left, weekState: p.week?.state,
                                    updatedAt: p.readingAt ?? generatedAt, sourceDevice: p.sourceDevice)
    }

    public var left: Double { max(0, 1 - used) }

    /// The tone the session is drawn in: its forecast's until it warns, then amber and rose.
    public var tone: PacingState {
        switch level {
        case .normal: WidgetSession(used: used, resetsAt: resetsAt, startedAt: startedAt, level: level, outlook: outlook, runsOutAt: runsOutAt,
                                    leftAtReset: leftAtReset, burn: WidgetBurn(perHour: nil, averagePerHour: nil, lastingPerHour: nil), chart: nil).tone
        case .amber: .tight
        case .rose, .blocked: .veryTight
        }
    }

    /// The forecast in a line.
    public func forecast(_ copy: Copy) -> String {
        if resetsAt <= copy.now { return "Session's back · 100% available" }
        switch outlook {
        case .blocked: return "Used up · back \(copy.when(resetsAt))"
        case .runsOut:
            guard let runsOutAt else { return "Runs out before the reset" }
            let early = resetsAt.timeIntervalSince(runsOutAt)
            return "Runs out ~\(copy.when(runsOutAt))" + (early >= 60 ? ", \(TimeFormat.countdown(early)) early" : "")
        case .lasts: return "Lasts to the reset"
        case .comfortable: return leftAtReset.map(copy.atReset) ?? "Plenty for this session"
        case .idle: return "Starts with your next prompt"
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
/// The session Live Activity: one per account.
public struct SessionActivityAttributes: ActivityAttributes {
    public typealias ContentState = SessionActivityState
    public var accountID: String
    public var provider: Provider
    public var shortLabel: String

    public init(accountID: String, provider: Provider, shortLabel: String) {
        self.accountID = accountID; self.provider = provider; self.shortLabel = shortLabel
    }
}
#endif

// MARK: - Presentations

/// The Lock Screen and banner presentation (and StandBy, scaled up).
public struct SessionActivityLockScreen: View {
    public var provider: Provider
    public var label: String
    public var state: SessionActivityState
    public var now: Date

    public init(provider: Provider, label: String, state: SessionActivityState, now: Date = Date()) {
        self.provider = provider; self.label = label; self.state = state; self.now = now
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    public var body: some View {
        let p = Palette(scheme), tone = p.tone(state.tone), copy = Copy(now: now, calendar: calendar, locale: locale)
        let back = state.resetsAt <= now
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandTile(provider: provider, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1).privacySensitive()
                    Text("5-hour session").font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    if back {
                        Text("Back").font(.system(size: 24, weight: .semibold)).foregroundStyle(p.tone(.plenty).text)
                    } else {
                        Countdown(now: now, to: state.resetsAt)
                            .font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(state.level >= .amber ? tone.text : p.ink)
                            .multilineTextAlignment(.trailing).frame(maxWidth: 120, alignment: .trailing)
                    }
                    Caps(back ? "ready" : "to reset", size: 8)
                }
            }
            HStack(spacing: 10) {
                CellMeter(state: back ? .plenty : state.tone, cells: PacingEngine.cells(remaining: back ? 1 : state.left), height: 11)
                Text(copy.percent(back ? 1 : state.left)).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(p.ink)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if state.level >= .amber, !back { WarningGlyph(fill: tone.text, ink: p.cardSolid, size: 11) }
                Text(state.forecast(copy)).font(.system(size: 12, weight: .medium)).foregroundStyle(state.outlook == .runsOut && !back ? tone.text : p.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let weekLeft = state.weekLeft, let weekState = state.weekState {
                    Text("Week \(copy.percent(weekLeft))").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(p.tone(weekState).text)
                }
            }
            Text("Updated \(copy.ago(state.updatedAt))" + (state.sourceDevice.map { " · \($0)" } ?? ""))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted2)
        }
        .padding(14)
    }
}

/// The Dynamic Island's compact leading: the provider mark, tinted by the session's level.
public struct SessionActivityCompactLeading: View {
    public var provider: Provider
    public var state: SessionActivityState
    public init(provider: Provider, state: SessionActivityState) { self.provider = provider; self.state = state }
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        MarkShape(provider: provider).fill(state.level >= .amber ? Palette(.dark).tone(state.tone).text : BrandColors.of(provider).light)
            .frame(width: 16, height: 16)
    }
}

/// The Dynamic Island's compact trailing: the countdown.
public struct SessionActivityCompactTrailing: View {
    public var state: SessionActivityState
    public var now: Date
    public init(state: SessionActivityState, now: Date = Date()) { self.state = state; self.now = now }

    public var body: some View {
        Countdown(now: now, to: state.resetsAt)
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(state.level >= .amber ? Palette(.dark).tone(state.tone).text : .white)
            .frame(maxWidth: 64)
    }
}

/// The Dynamic Island's minimal presentation, and the Watch Smart Stack's ring: what's left.
public struct SessionActivityRing: View {
    public var state: SessionActivityState
    public var width: CGFloat
    public init(state: SessionActivityState, width: CGFloat = 2.5) { self.state = state; self.width = width }

    public var body: some View {
        Ring(fraction: state.left, tone: Palette(.dark).tone(state.tone), width: width)
    }
}

/// The Dynamic Island's expanded bottom region.
public struct SessionActivityExpandedBottom: View {
    public var state: SessionActivityState
    public var now: Date
    public init(state: SessionActivityState, now: Date = Date()) { self.state = state; self.now = now }

    public var body: some View {
        let p = Palette(.dark), copy = Copy(now: now)
        VStack(alignment: .leading, spacing: 6) {
            CellMeter(state: state.tone, cells: PacingEngine.cells(remaining: state.left), height: 9)
            HStack {
                Text(state.forecast(copy)).font(.system(size: 12, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
                Spacer()
                if let weekLeft = state.weekLeft, let weekState = state.weekState {
                    Text("Week \(copy.percent(weekLeft))").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(p.tone(weekState).text)
                }
            }
        }
    }
}

/// The Apple Watch Smart Stack presentation (`.small` supplemental family).
public struct SessionActivityWatch: View {
    public var provider: Provider
    public var state: SessionActivityState
    public var now: Date
    public init(provider: Provider, state: SessionActivityState, now: Date = Date()) { self.provider = provider; self.state = state; self.now = now }

    public var body: some View {
        HStack(spacing: 8) {
            ZStack {
                SessionActivityRing(state: state, width: 4)
                MarkShape(provider: provider).fill(BrandColors.of(provider).light).frame(width: 12, height: 12)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Countdown(now: now, to: state.resetsAt)
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                Text("\(Copy(now: now).percent(state.left)) left · 5H").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}
