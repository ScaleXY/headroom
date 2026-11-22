import HeadroomKit
import HeadroomPresent
import HeadroomWidgetUI
import SwiftUI

/// The Limits card's one chart (redesign §3): the week glide, and under it on the same time axis
/// the lane, either each 5-hour session this week or each day's share of the week. The glide's
/// chart is built from the card's own `GlideModel`, so the lane's hours (since the same window
/// start) land on the same x.
struct LimitsChartView: View {
    var glide: GlideModel
    var lane: LimitsLaneModel?
    var plotHeight: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), tone = p.tone(glide.state)
        let chart = WidgetFeedBuilder(now: Date()).chart(glide, limit: 400)
        let height = GlideChartView.height(plot: plotHeight, lane: lane != nil)
        ZStack(alignment: .topLeading) {
            GlideChartView(chart: chart, tone: tone, lane: lane != nil)
            if let lane {
                GeometryReader { g in
                    let bottom = GlideChartView.plotBottom(height: g.size.height, lane: true)
                    LaneView(lane: lane, nowT: chart.nowT, state: glide.state)
                        .frame(width: g.size.width, height: GlideChartView.laneGap + GlideChartView.laneHeight)
                        .offset(y: bottom)
                }
            }
        }
        .frame(height: height)
    }
}

/// The lane itself: `laneGap` of headroom for the × and ⚠ marks, then the 30 pt lane.
struct LaneView: View {
    var lane: LimitsLaneModel
    var nowT: Double
    var state: PacingState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        GeometryReader { g in
            let W = g.size.width, LT = GlideChartView.laneGap, LB = LT + GlideChartView.laneHeight
            let hours = max(lane.hours, 1)
            let X = { (h: Double) -> CGFloat in CGFloat(h / hours) * W }
            let nx = X(nowT)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: LB)); $0.addLine(to: CGPoint(x: W, y: LB)) }, with: .color(p.chartGrid), lineWidth: 1.2)
                    switch lane.kind {
                    case .sessions: drawSessions(ctx, p: p, X: X, nx: nx, LT: LT, LB: LB, W: W)
                    case .daily: drawDays(ctx, p: p, X: X, LT: LT, LB: LB)
                    }
                    // Now runs on through the lane.
                    ctx.stroke(Path { $0.move(to: CGPoint(x: nx, y: 0)); $0.addLine(to: CGPoint(x: nx, y: LB)) },
                               with: .color(p.chartDash), style: StrokeStyle(lineWidth: 0.8, dash: [1.5, 2.5]))
                }
                if lane.kind == .sessions, let out = lane.current?.runsOutAt {
                    ZStack {
                        Circle().fill(p.rose.opacity(0.18)).frame(width: 14, height: 14)
                        WarningGlyph(fill: p.rose, ink: p.cardSolid, size: 11)
                    }
                    .position(x: min(max(X(out), 7), W - 7), y: LT - 8)
                }
                if lane.kind == .daily {
                    ForEach(Array(lane.days.enumerated()), id: \.offset) { _, d in
                        let x1 = X(d.start) + 3, x2 = X(d.end) - 3
                        if let used = d.used, let label = d.label, x2 - x1 >= 18 {
                            Text(label)
                                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(d.isToday ? p.tone(state).text : d.isHeavy ? p.amber : p.chartLabel)
                                .fixedSize()
                                .position(x: (x1 + x2) / 2, y: dayY(used, LT: LT, LB: LB) - 7)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: Sessions

    private func drawSessions(_ ctx: GraphicsContext, p: Palette, X: (Double) -> CGFloat, nx: CGFloat, LT: CGFloat, LB: CGFloat, W: CGFloat) {
        func LY(_ v: Double) -> CGFloat { LB - CGFloat(min(max(v, 0), 1)) * (LB - LT) }
        func span(_ s: Double, _ e: Double) -> (CGFloat, CGFloat) {
            let x1 = X(s) + 0.6
            return (x1, max(x1 + 2.6, X(e) - 0.6))
        }
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: LY(lane.warnAt))); $0.addLine(to: CGPoint(x: W, y: LY(lane.warnAt))) },
                   with: .color(p.amber.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
        for s in lane.sessions {
            let (x1, x2) = span(s.start, s.end)
            ctx.fill(Self.topRounded(x1, LY(s.peak), x2 - x1, LB - LY(s.peak), 1.5),
                     with: .color(p.laneSession(peak: s.peak, hit: s.hitLimit, warnAt: lane.warnAt)))
            if s.hitLimit { Self.cross(ctx, at: CGPoint(x: (x1 + x2) / 2, y: LT - 6), color: p.rose) }
        }
        guard let c = lane.current else { return }
        let (x1, x2) = span(c.start, c.end)
        let color = c.level == .normal ? p.laneBarStrong : p.laneSession(peak: c.used, hit: c.hitLimit, warnAt: lane.warnAt)
        let track = Path(roundedRect: CGRect(x: x1, y: LT, width: x2 - x1, height: LB - LT), cornerRadius: 2)
        ctx.fill(track, with: .color(p.dark ? Color.white.opacity(0.045) : Color.black.opacity(0.04)))
        ctx.stroke(track, with: .color(color), style: StrokeStyle(lineWidth: 0.8, dash: [1.6, 1.4]))
        // Where the recent rate takes it by the reset.
        if let proj = c.projectedUsed, !c.hitLimit, x2 - 0.4 > nx {
            ctx.stroke(Path { $0.move(to: CGPoint(x: nx, y: LY(proj))); $0.addLine(to: CGPoint(x: x2 - 0.4, y: LY(proj))) },
                       with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [0.1, 2.4]))
        }
        let fillW = max(1.5, min(nx, x2) - x1)
        ctx.fill(Self.topRounded(x1, LY(c.used), fillW, LB - LY(c.used), 1.5), with: .color(color))
        if c.hitLimit { Self.cross(ctx, at: CGPoint(x: (x1 + x2) / 2, y: LT - 6), color: p.rose) }
    }

    // MARK: Days

    private func dayScale() -> Double {
        max(lane.days.compactMap(\.used).max() ?? 0, (lane.days.map(\.even).max() ?? 0) * 1.5, 0.01)
    }

    private func dayY(_ v: Double, LT: CGFloat, LB: CGFloat) -> CGFloat {
        LB - CGFloat(min(max(v / dayScale(), 0), 1)) * (LB - LT)
    }

    private func drawDays(_ ctx: GraphicsContext, p: Palette, X: (Double) -> CGFloat, LT: CGFloat, LB: CGFloat) {
        for d in lane.days {
            let x1 = X(d.start) + 3, x2 = X(d.end) - 3, w = x2 - x1
            guard w >= 3 else { continue }
            let ey = dayY(d.even, LT: LT, LB: LB)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x1 - 1, y: ey)); $0.addLine(to: CGPoint(x: x2 + 1, y: ey)) },
                       with: .color(p.chartDash), style: StrokeStyle(lineWidth: 0.9, dash: [2, 2]))
            guard let used = d.used else { continue }
            let color = d.isToday ? p.tone(state).text.opacity(0.85) : d.isHeavy ? p.amber : p.laneBar
            let y = dayY(used, LT: LT, LB: LB)
            ctx.fill(Self.topRounded(x1, y, w, LB - y, 2), with: .color(color))
        }
    }

    // MARK: Shapes

    /// A bar with rounded top corners standing on `y + h`.
    static func topRounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> Path {
        var p = Path()
        guard h > 0.2, w > 0 else { return p }
        let r = min(radius, w / 2, h)
        p.move(to: CGPoint(x: x, y: y + h))
        p.addLine(to: CGPoint(x: x, y: y + r))
        p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: x + w - r, y: y))
        p.addQuadCurve(to: CGPoint(x: x + w, y: y + r), control: CGPoint(x: x + w, y: y))
        p.addLine(to: CGPoint(x: x + w, y: y + h))
        p.closeSubpath()
        return p
    }

    /// The small rose × over a session that hit the limit.
    static func cross(_ ctx: GraphicsContext, at c: CGPoint, color: Color) {
        let p = Path {
            $0.move(to: CGPoint(x: c.x - 2.4, y: c.y - 2.4)); $0.addLine(to: CGPoint(x: c.x + 2.4, y: c.y + 2.4))
            $0.move(to: CGPoint(x: c.x + 2.4, y: c.y - 2.4)); $0.addLine(to: CGPoint(x: c.x - 2.4, y: c.y + 2.4))
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private var spoken: String {
        switch lane.kind {
        case .sessions:
            var parts = lane.sessions.map(\.tooltip)
            if let c = lane.current { parts.append(c.tooltip) }
            return "5-hour sessions this week. " + parts.joined(separator: ". ")
        case .daily:
            return "Use each day. " + lane.days.compactMap(\.tooltip).joined(separator: ". ")
        }
    }
}

// MARK: - Keys, caption and stat strip

/// "━ This week  ▮ 5-hour sessions  ┄ warns at 75%  × limit hit": the first at full strength, the rest dimmed.
struct LimitsKeysRow: View {
    var keys: [LimitsKey]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        FlowLayout(spacing: 12, lineSpacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                HStack(spacing: 6) {
                    mark(key, color: color(key.tone, p))
                    Text(key.text).font(.system(size: 11, weight: .semibold)).tracking(0.2).foregroundStyle(p.ink).lineLimit(1)
                }
                .opacity(i == 0 ? 1 : 0.62)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ tone: LimitsKey.Tone, _ p: Palette) -> Color {
        switch tone {
        case .state(let s): p.tone(s).text
        case .neutral: p.laneBarStrong
        case .faint: p.chartLabel
        case .amber: p.amber
        case .rose: p.rose
        }
    }

    @ViewBuilder
    private func mark(_ key: LimitsKey, color: Color) -> some View {
        switch key.mark {
        case .line:
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2)
        case .bar:
            UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5).fill(color).frame(width: 5, height: 9)
        case .dash:
            Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 12, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2.5, 1.8])).frame(width: 12, height: 2)
        case .cross:
            Path {
                $0.move(to: CGPoint(x: 0.6, y: 0.6)); $0.addLine(to: CGPoint(x: 5.4, y: 5.4))
                $0.move(to: CGPoint(x: 5.4, y: 0.6)); $0.addLine(to: CGPoint(x: 0.6, y: 5.4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).frame(width: 6, height: 6)
        }
    }
}

/// A rose dot and one sentence under the chart: the live session runs out before its reset, or is paused.
struct ChartCaption: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(p.rose).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(text).font(.footnote).foregroundStyle(p.ink.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Four cells on a recessed panel: a tiny label, a 17 pt value and a 10 pt sub-line.
struct StatStrip: View {
    var cells: [StatCell]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                if i > 0 { Rectangle().fill(Color.gray.opacity(0.22)).frame(width: 0.5).padding(.vertical, 9) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(cell.label.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.88).foregroundStyle(p.ink.opacity(0.5))
                        .lineLimit(1).frame(height: 10)
                    Text(cell.value).font(.system(size: 17, weight: .bold).monospacedDigit()).tracking(-0.34).foregroundStyle(color(cell.tone, p))
                        .lineLimit(1).minimumScaleFactor(0.7).frame(height: 19).padding(.top, 4)
                    Text(cell.sub).font(.system(size: 10, weight: .medium)).foregroundStyle(p.ink.opacity(0.5))
                        .lineLimit(1).minimumScaleFactor(0.8).frame(height: 12).padding(.top, 1)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 2)
        .background(shape.fill(p.dark ? Color.black.opacity(0.18) : Color.black.opacity(0.03)))
        .overlay(shape.strokeBorder(p.dark ? Color.white.opacity(0.06) : .clear, lineWidth: 0.5))
    }

    private func color(_ tone: StatCell.Tone, _ p: Palette) -> Color {
        switch tone {
        case .plain: p.ink
        case .state(let s): p.tone(s).text
        case .amber: p.amber
        case .rose: p.rose
        }
    }
}

/// Lays its children out in rows, wrapping when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        // Spelled out step by step: as one expression it times out the type checker on slower machines (CI).
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for (j, item) in row.enumerated() {
                if j > 0 { rowWidth += spacing }
                rowWidth += item.size.width
                rowHeight = max(rowHeight, item.size.height)
            }
            width = max(width, rowWidth)
            if i > 0 { height += lineSpacing }
            height += rowHeight
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            let h = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (h - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += h + lineSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, s))
            x += s.width + spacing
        }
        return rows
    }
}

// MARK: - Card surface

extension View {
    /// A card on the phone: the solid card fill with the provider's top-edge light, plus the state
    /// glow on Limits cards (redesign §2 rules 3 and 4).
    func signatureCard(_ provider: Provider?, state: PacingState? = nil, radius: CGFloat = 20) -> some View {
        modifier(SignatureCard(provider: provider, state: state, radius: radius))
    }
}

struct SignatureCard: ViewModifier {
    var provider: Provider?
    var state: PacingState?
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let p = Palette(scheme)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(p.cardSolid)
                    .overlay(SignatureLight(provider: provider, state: state))
                    .clipShape(shape)
            }
            .overlay(shape.strokeBorder(p.groupBorder, lineWidth: 0.5))
    }
}
