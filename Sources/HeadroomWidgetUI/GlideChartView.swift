import HeadroomKit
import SwiftUI

/// The Pace card's glide graph: headroom over time, the dotted projection from now, the even-pace
/// diagonal and the time axis. For the 5-hour session it is the last day's trail of dips and refills.
struct GlideChartView: View {
    var chart: WidgetChart
    var tone: Tone
    /// Draws the NOW chip next to the dot.
    var nowChip = true
    var labels = true
    @Environment(\.colorScheme) private var scheme

    private static let labelBand: CGFloat = 14

    var body: some View {
        GeometryReader { g in
            content(size: g.size)
        }
    }

    private struct Frame {
        var W: CGFloat, top: CGFloat, bot: CGFloat, hours: Double
        func X(_ h: Double) -> CGFloat { CGFloat(h / hours) * W }
        func Y(_ remaining: Double) -> CGFloat { top + CGFloat(1 - remaining) * (bot - top) }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let p = Palette(scheme)
        let f = Frame(W: size.width, top: 6, bot: size.height - (labels ? Self.labelBand : 2), hours: max(chart.hours, 1))
        let axis = Self.axis(chart)
        let runs = self.runs(f)
        let nowPt = runs.last?.last ?? CGPoint(x: f.X(chart.nowT), y: f.Y(1))
        let endPt = CGPoint(x: f.X(min(max(chart.endT, chart.nowT), chart.hours)), y: f.Y(max(0, chart.endRemaining)))

        ZStack(alignment: .topLeading) {
            // Grid: a baseline and the axis lines.
            Path { path in
                path.move(to: CGPoint(x: 0, y: f.Y(0))); path.addLine(to: CGPoint(x: f.W, y: f.Y(0)))
                for b in axis.lines { path.move(to: CGPoint(x: f.X(b), y: f.top)); path.addLine(to: CGPoint(x: f.X(b), y: f.bot)) }
            }
            .stroke(p.chartGrid, lineWidth: 1)

            if labels { axisLabels(axis, f, p) }

            if let from = chart.evenFrom {
                Path { path in path.move(to: CGPoint(x: f.X(from), y: f.Y(1))); path.addLine(to: CGPoint(x: f.W, y: f.Y(0))) }
                    .stroke(p.chartDash, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }

            // Area under the whole history, then the line.
            Path { path in
                for run in runs { Self.appendSmooth(run, to: &path) }
                path.addLine(to: CGPoint(x: nowPt.x, y: f.Y(0)))
                path.addLine(to: CGPoint(x: runs.first?.first?.x ?? 0, y: f.Y(0)))
                path.closeSubpath()
            }
            .fill(LinearGradient(stops: [.init(color: tone.text.opacity(0.30), location: 0), .init(color: tone.text.opacity(0.07), location: 0.75),
                                         .init(color: tone.text.opacity(0), location: 1)], startPoint: UnitPoint(x: 0, y: f.top / size.height),
                                 endPoint: UnitPoint(x: 0, y: f.bot / size.height)))

            Path { path in path.move(to: CGPoint(x: nowPt.x, y: nowPt.y)); path.addLine(to: CGPoint(x: nowPt.x, y: f.Y(0))) }
                .stroke(tone.text.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            Path { path in for run in runs { var sub = Path(); Self.appendSmooth(run, to: &sub); path.addPath(sub) } }
                .stroke(tone.text, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: tone.glow, radius: 3)
                .widgetAccentable()

            // Resets step straight up; sleep gaps where usage moved are dotted.
            Path { path in
                for (a, b, refill) in joins(runs) where refill { path.move(to: a); path.addLine(to: b) }
            }
            .stroke(tone.text.opacity(0.7), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            Path { path in
                for (a, b, refill) in joins(runs) where !refill { path.move(to: a); path.addLine(to: b) }
            }
            .stroke(tone.text.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4.4]))

            // Projection.
            Path { path in path.move(to: nowPt); path.addLine(to: endPt) }
                .stroke(tone.text.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4.4]))
            if chart.runsOut {
                Circle().fill(p.rose.opacity(0.18)).frame(width: 18, height: 18).position(x: min(endPt.x, f.W - 7), y: endPt.y - 3)
                WarningGlyph(fill: p.rose, ink: p.cardSolid, size: 13).position(x: min(endPt.x, f.W - 7), y: endPt.y - 5)
            } else {
                Circle().fill(p.cardSolid).overlay(Circle().stroke(tone.text, lineWidth: 1.6)).frame(width: 6, height: 6)
                    .position(x: min(endPt.x, f.W - 3.5), y: endPt.y)
            }

            // Now.
            Circle().fill(tone.text.opacity(0.22)).frame(width: 16, height: 16).position(nowPt)
            Circle().fill(tone.text).overlay(Circle().stroke(p.cardSolid, lineWidth: 2)).frame(width: 8, height: 8).position(nowPt)
            if nowChip { chip(nowPt: nowPt, runs: runs, f: f, p: p) }
        }
    }

    // MARK: Runs

    /// History split into runs at resets and at sleep gaps, in view coordinates.
    private func runs(_ f: Frame) -> [[CGPoint]] {
        let pts = chart.points.filter { $0.t >= 0 && $0.t <= chart.nowT + 0.01 }
        var out: [[WidgetPoint]] = []
        for pt in pts {
            if let last = out.last?.last, pt.refill != true,
               pt.t - last.t <= min(2.0, chart.hours / 6) || abs(pt.u - last.u) < 0.005 {
                out[out.count - 1].append(pt)
            } else {
                out.append([pt])
            }
        }
        var runs = out.map { run in Self.decimate(run, step: chart.hours / 56).map { CGPoint(x: f.X($0.t), y: f.Y(1 - $0.u)) } }
        let nowUsed = pts.last?.u ?? (1 - chart.endRemaining)
        let now = CGPoint(x: f.X(chart.nowT), y: f.Y(1 - nowUsed))
        if runs.isEmpty { runs = [[CGPoint(x: 0, y: f.Y(1)), now]] }
        if let l = runs.last?.last, abs(l.x - now.x) > 0.5 { runs[runs.count - 1].append(now) }
        return runs
    }

    private func joins(_ runs: [[CGPoint]]) -> [(CGPoint, CGPoint, Bool)] {
        runs.indices.dropFirst().compactMap { i in
            guard let a = runs[i - 1].last, let b = runs[i].first else { return nil }
            return (a, b, b.y < a.y - 1)
        }
    }

    private static func decimate(_ pts: [WidgetPoint], step: Double) -> [WidgetPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() where p.t - out[out.count - 1].t >= step { out.append(p) }
        out.append(pts[pts.count - 1])
        return out
    }

    /// Catmull-Rom smoothing to cubic Béziers, joined to the current subpath by a straight line.
    static func appendSmooth(_ pts: [CGPoint], to p: inout Path) {
        guard let first = pts.first else { return }
        if p.isEmpty { p.move(to: first) } else { p.addLine(to: first) }
        guard pts.count > 1 else { return }
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i], p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            p.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
    }

    // MARK: Chip

    /// Above the dot unless the line dives in from above; then down and to the left.
    @ViewBuilder
    private func chip(nowPt: CGPoint, runs: [[CGPoint]], f: Frame, p: Palette) -> some View {
        let w: CGFloat = 26, h: CGFloat = 12
        let before = runs.last?.last(where: { $0.x < nowPt.x - 10 })
        let diving = before.map { $0.y < nowPt.y - 6 } ?? false
        let above = nowPt.y - 20 > 0 && !diving
        let x = above ? min(max(nowPt.x, w / 2 + 1), f.W - w / 2 - 1) : max(nowPt.x - w / 2 - 7, w / 2 + 1)
        let y = above ? nowPt.y - 16 : min(nowPt.y + 14, f.bot - h / 2 - 1)
        Text("NOW")
            .font(.system(size: 7, weight: .heavy)).tracking(0.7)
            .foregroundStyle(tone.text)
            .frame(width: w, height: h)
            .background(Capsule().fill(p.cardSolid.opacity(0.85)))
            .background(Capsule().fill(tone.text.opacity(0.16)))
            .overlay(Capsule().strokeBorder(tone.text.opacity(0.4), lineWidth: 0.6))
            .position(x: x, y: y)
    }

    // MARK: Axis

    struct Axis {
        var lines: [Double]
        var labels: [(t: Double, text: String, current: Bool)]
    }

    @ViewBuilder
    private func axisLabels(_ axis: Axis, _ f: Frame, _ p: Palette) -> some View {
        // A label that would touch the one before it is dropped (the current one wins), so a short
        // first day doesn't run into the next.
        let placed = axis.labels.reduce(into: [(t: Double, text: String, current: Bool, x: CGFloat)]()) { out, l in
            let x = min(max(f.X(l.t), 14), f.W - 14)
            let width = CGFloat(l.text.count) * 5.6 + (l.current ? 10 : 0)
            if let last = out.last, x - last.x < (width + CGFloat(last.text.count) * 5.6) / 2 + 4 {
                if l.current { out[out.count - 1] = (l.t, l.text, l.current, x) }
                return
            }
            out.append((l.t, l.text, l.current, x))
        }
        ForEach(placed.indices, id: \.self) { i in
            let l = placed[i]
            let x = l.x
            Text(l.text)
                .font(.system(size: 7.5, weight: l.current ? .heavy : .semibold)).tracking(0.5)
                .foregroundStyle(l.current ? p.ink : p.chartLabel)
                .fixedSize()
                .padding(.horizontal, l.current ? 5 : 0).padding(.vertical, l.current ? 1.5 : 0)
                .background(Capsule().fill(l.current ? p.chartPill : .clear))
                .position(x: min(max(x, 14), f.W - 14), y: f.bot + Self.labelBand / 2 + 1)
        }
    }

    /// Hour lines every 4 hours for a day-long trail (every hour for 5), day lines for a week.
    static func axis(_ c: WidgetChart, calendar: Calendar = .current) -> Axis {
        let hours = max(c.hours, 1)
        var lines: [Double] = []
        var labels: [(Double, String, Bool)] = []
        if hours <= 30 {
            let step: Double = hours <= 12 ? 1 : 4
            var h = (calendar.dateInterval(of: .hour, for: c.start)?.end ?? c.start).timeIntervalSince(c.start) / 3600
            if step > 1 {
                let hour = Double(calendar.component(.hour, from: c.start.addingTimeInterval(h * 3600)))
                h += (step - hour.truncatingRemainder(dividingBy: step)).truncatingRemainder(dividingBy: step)
            }
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("j")
            while h < hours - 0.01 {
                if h > 0.4, h < hours - 0.4 {
                    lines.append(h)
                    labels.append((h, f.string(from: c.start.addingTimeInterval(h * 3600)).uppercased(), false))
                }
                h += step
            }
        } else {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate(hours > 240 ? "MMMd" : "EEE")
            var bounds: [Double] = [0]
            if var d = calendar.nextDate(after: c.start, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
                while true {
                    let h = d.timeIntervalSince(c.start) / 3600
                    if h >= hours { break }
                    if h > 0.01 { bounds.append(h); lines.append(h) }
                    guard let next = calendar.date(byAdding: .day, value: hours > 240 ? 7 : 1, to: d) else { break }
                    d = next
                }
            }
            bounds.append(hours)
            for i in 0..<(bounds.count - 1) where bounds[i + 1] - bounds[i] >= (hours > 240 ? 72 : 12) {
                let mid = (bounds[i] + bounds[i + 1]) / 2
                let current = c.nowT >= bounds[i] && c.nowT < bounds[i + 1]
                let text = f.string(from: c.start.addingTimeInterval((bounds[i] + 0.5) * 3600)).uppercased().replacingOccurrences(of: ".", with: "")
                labels.append((mid, text, current))
            }
        }
        return Axis(lines: lines, labels: labels.map { (t: $0.0, text: $0.1, current: $0.2) })
    }
}
