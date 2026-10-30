import HeadroomKit
import SwiftUI
import WidgetKit

/// The complications: one set for the iPhone and iPad Lock Screen and for Apple Watch faces.
public enum ComplicationKind: String, CaseIterable, Sendable {
    /// The 5-hour session: what's left and the time to its reset.
    case session
    /// The week (or the month): what's left and the pacing state.
    case week
    /// Week and session together, or the two accounts that need watching most.
    case pace
    /// The Burn-o-meter: how fast you're spending against the pace that lasts.
    case burn

    public var kind: String { "com.scalexy.headroom.complication.\(rawValue)" }

    public var title: String {
        switch self {
        case .session: "5-Hour Session"
        case .week: "This Week"
        case .pace: "Headroom"
        case .burn: "Burn-o-meter"
        }
    }

    public var summary: String {
        switch self {
        case .session: "Time to the 5-hour reset, and what's left."
        case .week: "What's left this week, and whether you're on pace."
        case .pace: "The week and the 5-hour session at a glance."
        case .burn: "How fast you're spending against the pace that lasts."
        }
    }

    /// Shapes this kind draws (the Pace kind has no circle; corners are watchOS only).
    public var shapes: [AccessoryShape] {
        switch self {
        case .pace: [.rectangular, .inline]
        default: [.circular, .rectangular, .inline, .corner]
        }
    }
}

/// Accessory widget shapes, independent of `WidgetFamily` so the Mac can render previews.
public enum AccessoryShape: String, CaseIterable, Sendable {
    case circular, rectangular, inline, corner
}

/// Full color on colorful faces; one tint on the Lock Screen, StandBy at night and tinted faces.
public enum AccessoryTint: Sendable {
    case color, mono
}

extension EnvironmentValues {
    /// Set by the extension from `widgetRenderingMode`, and by previews directly.
    @Entry public var accessoryTint: AccessoryTint = .color
    /// Previews drawn at a fixed moment can't use ticking timers (they always count from the real
    /// clock), so they set this and countdowns print as of `now` instead.
    @Entry public var staticTimers = false
    /// Drawn by `ImageRenderer` (previews, review PNGs), which can't draw controls such as `Link`.
    @Entry public var drawnOffscreen = false
}

/// Time left to `end`: ticking on device, fixed in previews.
public struct Countdown: View {
    public var now: Date
    public var end: Date
    public init(now: Date, to end: Date) { self.now = now; self.end = end }
    @Environment(\.staticTimers) private var staticTimers

    public var body: some View {
        if staticTimers {
            let s = max(0, Int(end.timeIntervalSince(now)))
            Text(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
        } else {
            Text(timerInterval: now...max(now, end), countsDown: true, showsHours: true)
        }
    }
}

/// One complication for one account, as of `now`.
public struct ComplicationView: View {
    public var kind: ComplicationKind
    public var shape: AccessoryShape
    /// The account it shows; nil before the first sync.
    public var provider: WidgetProvider?
    /// The next account down, for the Pace kind's second row.
    public var second: WidgetProvider?
    /// When the Macs were last heard from.
    public var generatedAt: Date?
    public var now: Date

    public init(kind: ComplicationKind, shape: AccessoryShape, provider: WidgetProvider?, second: WidgetProvider? = nil,
                generatedAt: Date?, now: Date) {
        self.kind = kind; self.shape = shape; self.provider = provider; self.second = second
        self.generatedAt = generatedAt; self.now = now
    }

    @Environment(\.accessoryTint) private var tint
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var stale: Bool { generatedAt.map { now.timeIntervalSince($0) > 20 * 60 } ?? true }
    var copy: Copy { Copy(now: now, calendar: calendar, locale: locale) }

    public var body: some View {
        if let p = provider, p.week != nil || p.session != nil {
            switch shape {
            case .circular: circular(p)
            case .rectangular: rectangular(p)
            case .inline: Text(inline(p))
            case .corner: corner(p)
            }
        } else {
            empty
        }
    }

    // MARK: Circular

    @ViewBuilder
    private func circular(_ p: WidgetProvider) -> some View {
        switch kind {
        case .session, .pace:
            let s = AccessoryMath.session(p, now: now)
            AccessoryRing(fraction: s.left, tone: s.tone, dim: stale) {
                VStack(spacing: 0) {
                    if let resetsAt = s.resetsAt {
                        Countdown(now: now, to: resetsAt)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(1)
                        Text("5H").font(.system(size: 7.5, weight: .bold)).opacity(0.7)
                    } else {
                        Text(copy.percent(s.left)).font(.system(size: 14, weight: .semibold).monospacedDigit()).minimumScaleFactor(0.6)
                        Text("5H").font(.system(size: 7.5, weight: .bold)).opacity(0.7)
                    }
                }
                .padding(.horizontal, 6)
            }
        case .week:
            let w = AccessoryMath.week(p, now: now)
            AccessoryRing(fraction: w.left, tone: w.state, dim: stale) {
                VStack(spacing: 0) {
                    Text(copy.percent(w.left)).font(.system(size: 14, weight: .semibold).monospacedDigit()).minimumScaleFactor(0.6)
                    Text(w.short).font(.system(size: 7.5, weight: .bold)).opacity(0.7)
                }
            }
        case .burn:
            let b = AccessoryMath.burn(p)
            AccessoryDial(ratio: b.ratio, dim: stale) {
                Text(b.label).font(.system(size: 12, weight: .semibold).monospacedDigit()).minimumScaleFactor(0.6)
            }
        }
    }

    // MARK: Rectangular

    @ViewBuilder
    private func rectangular(_ p: WidgetProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch kind {
            case .session:
                let s = AccessoryMath.session(p, now: now)
                header(p, trailing: "5H")
                Text(s.isIdle ? "Ready · \(copy.percent(s.left))" : "\(copy.percent(s.left)) left")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit()).widgetAccentableIfMono(tint)
                AccessoryCells(fraction: s.left, tone: s.tone)
                Text(s.line(copy)).font(.system(size: 11, weight: .medium)).lineLimit(1).opacity(0.8)
            case .week:
                let w = AccessoryMath.week(p, now: now)
                header(p, trailing: w.short)
                Text("\(copy.percent(w.left)) left").font(.system(size: 15, weight: .semibold).monospacedDigit()).widgetAccentableIfMono(tint)
                AccessoryCells(fraction: w.left, tone: w.state)
                Text("\(w.state.word) · \(w.renews(copy))").font(.system(size: 11, weight: .medium)).lineLimit(1).opacity(0.8)
            case .pace:
                if let second, second.key != p.key {
                    row(p)
                    row(second)
                } else {
                    let w = AccessoryMath.week(p, now: now), s = AccessoryMath.session(p, now: now)
                    header(p, trailing: nil)
                    paceLine("WK", w.left, tone: w.state, detail: w.state.word)
                    paceLine("5H", s.left, tone: s.tone, detail: s.resetsAt.map { "resets " + copy.when($0) } ?? "ready")
                }
            case .burn:
                let b = AccessoryMath.burn(p)
                header(p, trailing: "BURN")
                HStack(spacing: 10) {
                    gaugeColumn("5H", ratio: b.session)
                    gaugeColumn("WK", ratio: b.week)
                }
                Text(b.sentence).font(.system(size: 11, weight: .medium)).lineLimit(1).opacity(0.8)
            }
            if stale, let generatedAt {
                Text(copy.ago(generatedAt)).font(.system(size: 9, weight: .medium)).opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ p: WidgetProvider, trailing: String?) -> some View {
        HStack(spacing: 4) {
            MarkShape(provider: p.id).fill(tint == .color ? BrandColors.of(p.id).base : .primary).frame(width: 10, height: 10)
            Text(p.shortLabel ?? p.id.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1).privacySensitive(p.shortLabel != nil && p.shortLabel != p.id.displayName)
            Spacer(minLength: 2)
            if let trailing { Text(trailing).font(.system(size: 9, weight: .bold)).opacity(0.6) }
        }
    }

    private func row(_ p: WidgetProvider) -> some View {
        let w = AccessoryMath.week(p, now: now)
        return HStack(spacing: 5) {
            MarkShape(provider: p.id).fill(tint == .color ? BrandColors.of(p.id).base : .primary).frame(width: 10, height: 10)
            Text(p.shortLabel ?? p.id.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            AccessoryCells(fraction: w.left, tone: w.state).frame(width: 40)
            Text(copy.percent(w.left)).font(.system(size: 12, weight: .semibold).monospacedDigit()).widgetAccentableIfMono(tint)
        }
    }

    private func paceLine(_ label: String, _ left: Double, tone: PacingState, detail: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9, weight: .bold)).opacity(0.6).frame(width: 16, alignment: .leading)
            AccessoryCells(fraction: left, tone: tone).frame(width: 40)
            Text(copy.percent(left)).font(.system(size: 12, weight: .semibold).monospacedDigit()).widgetAccentableIfMono(tint)
            Text(detail).font(.system(size: 10, weight: .medium)).lineLimit(1).opacity(0.75)
        }
    }

    private func gaugeColumn(_ label: String, ratio: Double?) -> some View {
        HStack(spacing: 4) {
            AccessoryDial(ratio: ratio, dim: stale) { EmptyView() }.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8.5, weight: .bold)).opacity(0.6)
                Text(AccessoryMath.ratioText(ratio)).font(.system(size: 13, weight: .semibold).monospacedDigit()).widgetAccentableIfMono(tint)
            }
        }
    }

    // MARK: Inline

    private func inline(_ p: WidgetProvider) -> String {
        let name = p.shortLabel ?? p.id.displayName
        switch kind {
        case .session:
            let s = AccessoryMath.session(p, now: now)
            return s.resetsAt.map { "\(name) 5h \(copy.percent(s.left)) · \(TimeFormat.countdown($0.timeIntervalSince(now)))" } ?? "\(name) 5h ready"
        case .week:
            let w = AccessoryMath.week(p, now: now)
            return "\(name) \(copy.percent(w.left)) · \(w.state.word)"
        case .pace:
            let w = AccessoryMath.week(p, now: now)
            if let second, second.key != p.key {
                let w2 = AccessoryMath.week(second, now: now)
                return "\(p.id.displayName) \(copy.percent(w.left)) · \(second.id.displayName) \(copy.percent(w2.left))"
            }
            let s = AccessoryMath.session(p, now: now)
            return "\(name) \(copy.percent(w.left)) · 5h \(copy.percent(s.left))"
        case .burn:
            let b = AccessoryMath.burn(p)
            return "\(name) burning \(AccessoryMath.ratioText(b.ratio))"
        }
    }

    // MARK: Corner (watch faces)

    @ViewBuilder
    private func corner(_ p: WidgetProvider) -> some View {
        switch kind {
        case .week:
            let w = AccessoryMath.week(p, now: now)
            Text(copy.percent(w.left)).font(.system(size: 14, weight: .semibold).monospacedDigit()).cornerLabel(fraction: w.left, text: "\(p.id.displayName) week")
        case .burn:
            let b = AccessoryMath.burn(p)
            Text(AccessoryMath.ratioText(b.ratio)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                .cornerLabel(fraction: min((b.ratio ?? 0) / BurnGauge.maxRatio, 1), text: "Burn")
        default:
            let s = AccessoryMath.session(p, now: now)
            Text(copy.percent(s.left)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                .cornerLabel(fraction: s.left, text: s.resetsAt.map { "5h · " + TimeFormat.countdown($0.timeIntervalSince(now)) } ?? "5h ready")
        }
    }

    // MARK: Empty

    @ViewBuilder
    private var empty: some View {
        switch shape {
        case .circular, .corner:
            ZStack {
                AccessoryBackdrop()
                HeadroomMarkView(size: 22).opacity(0.8)
            }
        case .rectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Headroom").font(.system(size: 13, weight: .semibold))
                Text("Turn on sync in Headroom on your Mac.").font(.system(size: 11, weight: .medium)).opacity(0.8).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .inline:
            Text("Headroom · waiting for your Mac")
        }
    }
}

// MARK: - Pieces

/// The accessory backing disc, as the system draws it.
struct AccessoryBackdrop: View {
    var body: some View {
        #if os(iOS) || os(watchOS)
        AccessoryWidgetBackground()
        #else
        Circle().fill(Color.primary.opacity(0.18))
        #endif
    }
}

/// A full ring of what's left, drawn by hand so it looks the same on every platform and in previews.
struct AccessoryRing<Center: View>: View {
    var fraction: Double
    var tone: PacingState
    var dim: Bool
    @ViewBuilder var center: Center
    @Environment(\.accessoryTint) private var tint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            AccessoryBackdrop()
            Circle().inset(by: 3.5).stroke(Color.primary.opacity(0.18), lineWidth: 4.5)
            Circle().inset(by: 3.5).trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(tint == .color ? Palette(scheme).tone(tone).text : .primary, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentableIfMono(tint)
                .opacity(dim ? 0.55 : 1)
            center
        }
    }
}

/// A Burn-o-meter in miniature: a 240° arc from 0 to 3× with a marker at the burn ratio.
struct AccessoryDial<Center: View>: View {
    var ratio: Double?
    var dim: Bool
    @ViewBuilder var center: Center
    @Environment(\.accessoryTint) private var tint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let r = side / 2 - 4
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let f = min(max((ratio ?? 0).isFinite ? (ratio ?? 0) / BurnGauge.maxRatio : 1, 0), 1)
            let angle = Angle.degrees(150 + 240 * f)
            ZStack {
                if side > 30 { AccessoryBackdrop() }
                Path { p in p.addArc(center: c, radius: r, startAngle: .degrees(150), endAngle: .degrees(390), clockwise: false) }
                    .stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: side > 30 ? 4 : 2.5, lineCap: .round))
                Path { p in p.addArc(center: c, radius: r, startAngle: .degrees(150), endAngle: angle, clockwise: false) }
                    .stroke(tint == .color ? Palette(scheme).tone(BurnGauge.state(ratio ?? 0)).text : .primary,
                            style: StrokeStyle(lineWidth: side > 30 ? 4 : 2.5, lineCap: .round))
                    .widgetAccentableIfMono(tint)
                    .opacity(ratio == nil || dim ? 0.5 : 1)
                center
            }
        }
    }
}

/// Five cells in one tone, like the menu bar meter, sized for accessories.
struct AccessoryCells: View {
    var fraction: Double
    var tone: PacingState
    @Environment(\.accessoryTint) private var tint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lit = PacingEngine.cells(remaining: fraction)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < lit ? (tint == .color ? Palette(scheme).tone(tone).text : Color.primary) : Color.primary.opacity(0.2))
                    .widgetAccentableIfMono(tint, i < lit)
            }
        }
        .frame(height: 6)
    }
}

extension View {
    /// Marks the value layer for the system tint when the face or Lock Screen is monochrome.
    @ViewBuilder
    func widgetAccentableIfMono(_ tint: AccessoryTint, _ on: Bool = true) -> some View {
        #if os(iOS) || os(watchOS)
        widgetAccentable(tint == .mono && on)
        #else
        self
        #endif
    }

    /// A watch-face corner: the value inside, a gauge along the bezel.
    @ViewBuilder
    func cornerLabel(fraction: Double, text: String) -> some View {
        #if os(watchOS)
        widgetCurvesContent().widgetLabel {
            Gauge(value: min(max(fraction, 0), 1)) { Text(text) }
        }
        #else
        self
        #endif
    }
}

// MARK: - The numbers each complication draws, as of a moment

public enum AccessoryMath {
    struct Session {
        var left: Double
        var resetsAt: Date?
        var tone: PacingState
        var isIdle: Bool
        var runsOutAt: Date?
        var leftAtReset: Double?

        func line(_ copy: Copy) -> String {
            guard let resetsAt else { return "Starts with your next prompt" }
            if let runsOutAt, runsOutAt < resetsAt { return "Runs out \(copy.when(runsOutAt)) · resets \(copy.when(resetsAt))" }
            return "Resets \(copy.when(resetsAt))" + (leftAtReset.map { " · \(copy.percent($0)) left then" } ?? "")
        }
    }

    struct Week {
        var left: Double
        var state: PacingState
        var resetsAt: Date?

        var short: String { "WK" }

        func renews(_ copy: Copy) -> String { resetsAt.map { copy.renews($0) } ?? "renews soon" }
    }

    /// The session as of `now`: past its reset it's whole again, whatever the last sync said.
    static func session(_ p: WidgetProvider, now: Date) -> Session {
        guard let s = p.session, let resetsAt = s.resetsAt, resetsAt > now, !s.isIdle else {
            return Session(left: 1, resetsAt: nil, tone: .plenty, isIdle: true, runsOutAt: nil, leftAtReset: nil)
        }
        let tone: PacingState = switch s.level {
        case .normal: s.tone
        case .amber: .tight
        case .rose, .blocked: .veryTight
        }
        return Session(left: s.left, resetsAt: resetsAt, tone: tone, isIdle: false, runsOutAt: s.runsOutAt, leftAtReset: s.leftAtReset)
    }

    /// The week as of `now`: past its reset it's renewed.
    static func week(_ p: WidgetProvider, now: Date) -> Week {
        guard let w = p.week else { return Week(left: 1, state: .plenty, resetsAt: nil) }
        if w.resetsAt <= now { return Week(left: 1, state: .plenty, resetsAt: nil) }
        return Week(left: w.left, state: w.state, resetsAt: w.resetsAt)
    }

    struct Burn {
        var session: Double?
        var week: Double?
        var ratio: Double?
        var label: String { AccessoryMath.ratioText(ratio) }
        var sentence: String {
            guard let ratio else { return "Gathering history…" }
            if !ratio.isFinite { return "Used up" }
            return switch BurnGauge.state(ratio) {
            case .plenty: "Cruising"
            case .onPace: "Right on pace"
            case .tight: "Ease off a little"
            case .veryTight: "Slow down"
            }
        }
    }

    static func burn(_ p: WidgetProvider) -> Burn {
        let s = p.session.flatMap { $0.isIdle ? nil : $0.burn.ratio }
        let w = p.week?.burn.ratio
        return Burn(session: s, week: w, ratio: [s, w].compactMap { $0 }.max())
    }

    /// "1.4×", "Out", or "—" without a reading.
    public static func ratioText(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        guard ratio.isFinite else { return "Out" }
        return String(format: ratio < 10 ? "%.1f×" : "%.0f×", ratio)
    }
}
