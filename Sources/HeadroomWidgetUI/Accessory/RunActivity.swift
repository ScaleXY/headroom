import HeadroomKit
import SwiftUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

// The pieces an agent run is drawn with on iPhone, iPad and Watch (the Mac's `RunCardRenderer`
// in SwiftUI), and the run Live Activity. Everything arrives as resolved words: the widget
// extension doesn't link the presenter.

/// A run's or row's state mark (`RunGlyph` on the presenter side).
public enum RunMark: String, Codable, Sendable, Hashable, CaseIterable {
    case planned, running, stale, needsInput, waiting, parked, stopped, done, partial, failed, skipped, more
}

/// What a mark or word means, for its color (`RunTone`): blue for work moving, ink for settled,
/// amber for something to look at, rose only for something that needs you. Something that broke
/// is `failed`: strong ink, told apart by its ✕ and its words rather than a color.
public enum RunHue: String, Codable, Sendable, Hashable {
    case progress, neutral, warn, alert, quiet, failed
}

extension Palette {
    public func run(_ hue: RunHue) -> Color {
        switch hue {
        case .progress: azure
        case .neutral: ink
        case .warn: amber
        case .alert: rose
        case .quiet: muted
        case .failed: ink.opacity(0.9)
        }
    }
}

/// The state mark in a `size` box, drawn as the Mac draws it.
public struct RunMarkView: View {
    public var mark: RunMark
    public var color: Color
    public var size: CGFloat

    public init(_ mark: RunMark, color: Color, size: CGFloat = 10) { self.mark = mark; self.color = color; self.size = size }

    public var body: some View {
        Canvas { ctx, box in
            let k = box.width / 10, c = CGPoint(x: box.width / 2, y: box.height / 2)
            func circle(_ r: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> Path {
                Path(ellipseIn: CGRect(x: c.x + dx - r, y: c.y + dy - r, width: r * 2, height: r * 2))
            }
            func line(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var p = Path()
                for (i, q) in pts.enumerated() {
                    let pt = CGPoint(x: c.x + q.0 * k, y: c.y + q.1 * k)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            let round = StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round)
            switch mark {
            case .planned:
                ctx.stroke(circle(3.9 * k), with: .color(color.opacity(0.8)), lineWidth: 1.3 * k)
            case .running:
                ctx.fill(circle(5 * k), with: .color(color.opacity(0.2)))
                ctx.fill(circle(3 * k), with: .color(color))
            case .stale:
                ctx.stroke(circle(3.9 * k), with: .color(color), lineWidth: 1.3 * k)
                ctx.fill(circle(1.5 * k), with: .color(color))
            case .needsInput:
                ctx.fill(circle(5 * k), with: .color(color))
                ctx.stroke(line([(0, -2.6), (0, 0.6)]), with: .color(.white), style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round))
                ctx.fill(circle(0.85 * k, dy: 2.6 * k), with: .color(.white))
            case .waiting:
                for dx in [-2.2, 2.2] as [CGFloat] {
                    ctx.fill(Path(roundedRect: CGRect(x: c.x + (dx - 1.1) * k, y: c.y - 4 * k, width: 2.2 * k, height: 8 * k), cornerRadius: 0.8 * k),
                             with: .color(color))
                }
            case .parked, .partial:
                ctx.stroke(circle(3.9 * k), with: .color(color), lineWidth: 1.3 * k)
                var half = Path()
                half.addArc(center: c, radius: 3.9 * k, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
                half.closeSubpath()
                ctx.fill(half, with: .color(color))
            case .stopped:
                ctx.fill(Path(roundedRect: CGRect(x: c.x - 3.5 * k, y: c.y - 3.5 * k, width: 7 * k, height: 7 * k), cornerRadius: 1.6 * k),
                         with: .color(color))
            case .done:
                ctx.stroke(line([(-3.6, 0.2), (-1.1, 2.7), (3.7, -2.6)]), with: .color(color), style: round)
            case .failed:
                ctx.stroke(line([(-3, -3), (3, 3)]), with: .color(color), style: round)
                ctx.stroke(line([(3, -3), (-3, 3)]), with: .color(color), style: round)
            case .skipped:
                ctx.stroke(circle(3.9 * k), with: .color(color.opacity(0.8)), lineWidth: 1.2 * k)
                ctx.stroke(line([(-2.6, 2.6), (2.6, -2.6)]), with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round))
            case .more:
                for dx in [-3.0, 0, 3.0] as [CGFloat] { ctx.fill(circle(0.95 * k, dx: dx * k), with: .color(color)) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Done solid, in flight a lighter wash of the same blue, not started the empty track.
public struct RunProgressBar: View {
    public var done: Double
    public var inFlight: Double
    public var height: CGFloat

    public init(done: Double, inFlight: Double, height: CGFloat = 7) { self.done = done; self.inFlight = inFlight; self.height = height }
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme), tone = p.tone(.plenty)
        let d = min(max(done, 0), 1), f = min(max(inFlight, 0), 1 - d)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(p.meterTrack)
                if p.dark { Capsule().strokeBorder(p.meterTrackBorder, lineWidth: 0.5) }
                Rectangle().fill(tone.bottom.opacity(p.dark ? 0.32 : 0.22)).frame(width: g.size.width * (d + f))
                if d > 0 { Capsule().fill(tone.fill).frame(width: max(g.size.width * d, height)) }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The run's state as a tinted capsule with a dot.
public struct RunStateCapsule: View {
    public var text: String
    public var hue: RunHue
    public var compact: Bool

    public init(_ text: String, hue: RunHue, compact: Bool = false) { self.text = text; self.hue = hue; self.compact = compact }
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme), c = p.run(hue), strong = hue != .neutral
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(text).font(compact ? .system(size: 11, weight: .semibold) : .caption.weight(.semibold)).foregroundStyle(c).lineLimit(1)
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 3)
        .background(Capsule().fill(c.opacity(strong ? 0.13 : 0.08)))
        .overlay(Capsule().strokeBorder(c.opacity(strong ? 0.32 : 0.18), lineWidth: 0.5))
    }
}

// MARK: - Live Activity

/// What the run Live Activity shows: the most pressing live run on any Mac. Small (well under
/// ActivityKit's 4 KB), and the finish is a fixed time, so it stays right between updates. Fields
/// added later are optional, so an activity started by an older build still decodes.
public struct RunActivityState: Codable, Hashable, Sendable {
    /// The run's title, or "Run on <Mac>" when the Mac doesn't share names.
    public var title: String
    /// "Needs your input", "Running", "Mac last seen 2h ago".
    public var stateText: String
    public var mark: RunMark
    public var hue: RunHue
    public var provider: Provider?
    /// "42%", or "7/9" agents for a run with nothing declared.
    public var figure: String
    /// Done and in-flight shares: the declared plan's, or finished and running agents over all
    /// agents seen for an observed run.
    public var done: Double?
    public var inFlight: Double?
    /// "5 of 11 tasks · 3 running", "7 of 9 agents finished", or the counts line.
    public var detail: String?
    /// When it should finish at the recent rate.
    public var finishAt: Date?
    /// Under the title: the Mac, or the harness when the title already names the Mac.
    public var subtitle: String
    public var updatedAt: Date
    /// Not finished, and its Mac still heard from.
    public var live: Bool
    /// The task map, when the run has a plan (at most 24 blocks).
    public var blocks: [RunMapBlock]?
    /// The forecast as a range of clock times.
    public var finishLow: Date?
    public var finishHigh: Date?
    /// The first line of the question it waits on, when the Mac shares the wording.
    public var question: String?

    public init(title: String, stateText: String, mark: RunMark, hue: RunHue, provider: Provider?, figure: String, done: Double?, inFlight: Double?,
                detail: String?, finishAt: Date?, subtitle: String, updatedAt: Date, live: Bool, blocks: [RunMapBlock]? = nil,
                finishLow: Date? = nil, finishHigh: Date? = nil, question: String? = nil) {
        self.title = title; self.stateText = stateText; self.mark = mark; self.hue = hue; self.provider = provider; self.figure = figure
        self.done = done; self.inFlight = inFlight; self.detail = detail; self.finishAt = finishAt; self.subtitle = subtitle; self.updatedAt = updatedAt
        self.live = live; self.blocks = blocks; self.finishLow = finishLow; self.finishHigh = finishHigh; self.question = question
    }

    /// The progress the ring and bar show: done for a plan, finished agents otherwise.
    public var fraction: Double? { done }

    /// "~2:10 PM", or "2:05–2:20 PM" while the forecast is a wide range; nil once it's passed.
    public func finishText(_ copy: Copy) -> String? {
        guard live else { return nil }
        if let lo = finishLow, let hi = finishHigh, hi > copy.now {
            let a = copy.when(max(lo, copy.now)), b = copy.when(hi)
            if a == b { return "~" + a }
            // "2:05 PM–2:20 PM" reads as "2:05–2:20 PM".
            let suffix = b.split(separator: " ").last.map(String.init) ?? ""
            if !suffix.isEmpty, a.hasSuffix(" " + suffix), !suffix.contains(":") { return String(a.dropLast(suffix.count + 1)) + "–" + b }
            return a + "–" + b
        }
        guard let f = finishAt, f > copy.now else { return nil }
        return "~" + copy.when(f)
    }
}

#if canImport(ActivityKit) && os(iOS)
/// The run Live Activity: one at a time, for the most pressing live run.
public struct RunActivityAttributes: ActivityAttributes {
    public typealias ContentState = RunActivityState
    /// `RunDigest.id`: the Mac's device ID and the run's hashed ID.
    public var runID: String

    public init(runID: String) { self.runID = runID }
}
#endif

/// "Updated 4 min ago", ticking on its own between updates (fixed in rendered previews).
struct RunUpdatedText: View {
    var updatedAt: Date
    var now: Date
    @Environment(\.staticTimers) private var staticTimers

    var body: some View {
        if staticTimers {
            Text("Updated \(Copy(now: now).ago(updatedAt))")
        } else {
            Text("Updated \(Text(.currentDate, format: .reference(to: updatedAt, allowedFields: [.minute, .hour, .day], maxFieldCount: 1)))")
        }
    }
}

/// The plan as a task map, or the bar when there is no map.
struct RunActivityProgress: View {
    var state: RunActivityState
    var height: CGFloat

    var body: some View {
        if let blocks = state.blocks, !blocks.isEmpty {
            RunTaskMap(blocks: blocks, height: height, gap: 2)
        } else if let done = state.done {
            RunProgressBar(done: done, inFlight: state.inFlight ?? 0, height: height)
        }
    }
}

/// The question's first line, in the needs-you rose.
struct RunActivityQuestion: View {
    var text: String
    var size: CGFloat

    var body: some View {
        let p = Palette(.dark)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "questionmark.bubble.fill").font(.system(size: size - 1, weight: .semibold)).foregroundStyle(p.rose)
            Text(text).font(.system(size: size, weight: .medium)).foregroundStyle(p.ink).lineLimit(1).privacySensitive()
        }
    }
}

/// The Lock Screen and banner presentation.
public struct RunActivityLockScreen: View {
    public var state: RunActivityState
    public var now: Date

    public init(state: RunActivityState, now: Date = Date()) { self.state = state; self.now = now }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    public var body: some View {
        let p = Palette(scheme), copy = Copy(now: now, calendar: calendar, locale: locale)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let provider = state.provider { BrandTile(provider: provider, size: 22) } else { RunMarkView(state.mark, color: p.run(state.hue), size: 16) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1).privacySensitive()
                    Text(state.subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(state.figure).font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(p.ink)
            }
            if let q = state.question { RunActivityQuestion(text: q, size: 12) }
            RunActivityProgress(state: state, height: 8)
            // The state always reads in full; the finish gives way to it.
            HStack(spacing: 8) {
                RunStateCapsule(state.stateText, hue: state.hue, compact: true).layoutPriority(1)
                Spacer(minLength: 4)
                if let finish = state.finishText(copy) {
                    Text("Done \(finish)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                if let detail = state.detail {
                    Text(detail).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                RunUpdatedText(updatedAt: state.updatedAt, now: now).font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted2)
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(14)
    }
}

/// The Dynamic Island's compact leading: the state mark.
public struct RunActivityCompactLeading: View {
    public var state: RunActivityState
    public init(state: RunActivityState) { self.state = state }

    public var body: some View { RunMarkView(state.mark, color: Palette(.dark).run(state.hue), size: 16) }
}

/// The Dynamic Island's compact trailing: the figure.
public struct RunActivityCompactTrailing: View {
    public var state: RunActivityState
    public init(state: RunActivityState) { self.state = state }

    public var body: some View {
        Text(state.figure).font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(state.hue == .alert || state.hue == .warn ? Palette(.dark).run(state.hue) : .white)
            .lineLimit(1).frame(maxWidth: 64)
    }
}

/// The minimal presentation and the Watch's ring: done so far (finished agents for a run with no
/// plan), tinted by the state.
public struct RunActivityRing: View {
    public var state: RunActivityState
    public var width: CGFloat
    public init(state: RunActivityState, width: CGFloat = 2.5) { self.state = state; self.width = width }

    public var body: some View {
        let p = Palette(.dark)
        let tone = Tone(top: p.run(state.hue), bottom: p.run(state.hue), glow: .clear, text: p.run(state.hue))
        ZStack {
            Ring(fraction: state.fraction ?? 0, tone: tone, width: width)
            RunMarkView(state.mark, color: p.run(state.hue), size: 9)
        }
    }
}

/// The Dynamic Island's expanded bottom region: the question's first line when there is one,
/// then the map or bar, the counts and the finish.
public struct RunActivityExpandedBottom: View {
    public var state: RunActivityState
    public var now: Date
    public init(state: RunActivityState, now: Date = Date()) { self.state = state; self.now = now }

    public var body: some View {
        let p = Palette(.dark), copy = Copy(now: now)
        VStack(alignment: .leading, spacing: 6) {
            if let q = state.question { RunActivityQuestion(text: q, size: 12) }
            RunActivityProgress(state: state, height: 7)
            HStack(spacing: 8) {
                Text(state.detail ?? state.subtitle).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                Spacer(minLength: 4)
                if let finish = state.finishText(copy) {
                    Text("Done \(finish)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The Apple Watch Smart Stack presentation (`.small` supplemental family).
public struct RunActivityWatch: View {
    public var state: RunActivityState
    public init(state: RunActivityState) { self.state = state }

    public var body: some View {
        let p = Palette(.dark)
        HStack(spacing: 8) {
            RunActivityRing(state: state, width: 4).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.figure).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                Text(state.stateText).font(.system(size: 11, weight: .medium)).foregroundStyle(p.run(state.hue == .neutral ? .quiet : state.hue))
                    .lineLimit(1)
            }
        }
    }
}
