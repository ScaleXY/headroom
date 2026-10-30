import AppKit
import HeadroomKit

/// The weekly glide path (PLAN §3.4): remaining allowance over the window, drawn in the
/// mockup's 300×124 coordinate space and scaled to the card width.
@MainActor
enum GlideChartRenderer {
    static let vbW: CGFloat = 300, vbH: CGFloat = 124

    static func height(width: CGFloat) -> CGFloat { vbH * width / vbW }

    static func draw(_ g: GlideModel, rect: CGRect, theme: Theme, ctx: CGContext, calendar: Calendar = Display.calendar, locale: Locale = Display.locale) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / vbW, y: rect.width / vbW)
        render(g, theme: theme, ctx: ctx, calendar: calendar, locale: locale)
        ctx.restoreGState()
    }

    private static func render(_ g: GlideModel, theme: Theme, ctx: CGContext, calendar: Calendar, locale: Locale) {
        let W = vbW, H = vbH, top: CGFloat = 12, bot = H - 22
        let hours = max(g.hours, 1)
        func X(_ h: Double) -> CGFloat { CGFloat(h / hours) * W }
        func Y(_ r: Double) -> CGFloat { top + CGFloat(1 - r) * (bot - top) }
        let col: NSColor = g.brandLine.map { theme.isDark ? Brand.of($0).light : Brand.of($0).base } ?? theme.pacing(g.state).text
        let warnCol = theme.rose

        // The 5-hour session: hour lines, labelled at the line (every 4 hours across a day).
        let hourly = hours <= 30
        let hourStep: Double = hours <= 12 ? 1 : 4
        // Day boundaries at local midnight; weekly boundaries for long (monthly) windows.
        let weekly = hours > 240
        var bounds: [Double] = [0]
        if hourly {
            // From the first full hour after the start.
            var h = (calendar.dateInterval(of: .hour, for: g.windowStart)?.end ?? g.windowStart).timeIntervalSince(g.windowStart) / 3600
            if hourStep > 1 {
                // Land on local hours that divide evenly: 12, 4, 8…
                let hour = Double(calendar.component(.hour, from: g.windowStart.addingTimeInterval(h * 3600)))
                h += (hourStep - hour.truncatingRemainder(dividingBy: hourStep)).truncatingRemainder(dividingBy: hourStep)
            }
            while h < hours - 0.01 {
                if h > 0.01 { bounds.append(h) }
                h += hourStep
            }
        } else if let firstMidnight = calendar.nextDate(after: g.windowStart, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            var d = firstMidnight
            while true {
                let h = d.timeIntervalSince(g.windowStart) / 3600
                if h >= hours { break }
                if h > 0.01 { bounds.append(h) }
                guard let next = calendar.date(byAdding: .day, value: weekly ? 7 : 1, to: d) else { break }
                d = next
            }
        }
        bounds.append(hours)

        // Grid.
        ctx.stroke(line(0, Y(1), W, Y(1)), theme.chartGrid, width: 1)
        ctx.stroke(line(0, Y(0), W, Y(0)), theme.chartGrid, width: 1.2)
        for b in bounds.dropFirst().dropLast() { ctx.stroke(line(X(b), top, X(b), bot), theme.chartGrid, width: 1) }

        // Projection end and the run-out day.
        let endT = min(max(g.projectionEnd.t, g.nowT), hours)
        let endR = max(0, g.projectionEnd.remaining)
        var warnDay: Int? = nil
        if g.runsOut {
            warnDay = bounds.indices.dropLast().first { endT >= bounds[$0] && endT < bounds[$0 + 1] }
        }

        // Day labels; today in a pill. Hour labels sit on their line; the hour it runs out in turns rose.
        let dayFont = F.sf(8.5, 600), dayFontBold = F.sf(8.5, 750)
        for (i, b) in bounds.enumerated() where hourly && i > 0 && i < bounds.count - 1 {
            let x = X(b)
            let warn = warnDay == i
            let label = Text(hourLabel(g.windowStart.addingTimeInterval(b * 3600), calendar: calendar, locale: locale),
                             warn ? dayFontBold : dayFont, warn ? warnCol : theme.chartLabel, kern: 0.5)
            guard x - label.width / 2 > 0, x + label.width / 2 < W else { continue }
            label.draw(x: x + 0.25, baseline: H - 5, align: .center, in: ctx)
        }
        for i in 0..<(bounds.count - 1) where !hourly && bounds[i + 1] - bounds[i] >= (weekly ? 72 : 12) {
            let cx = X((bounds[i] + bounds[i + 1]) / 2)
            let current = g.nowT >= bounds[i] && g.nowT < bounds[i + 1]
            let warn = warnDay == i
            if current && !weekly { ctx.fill(rounded(CGRect(x: cx - 15, y: H - 15, width: 30, height: 14), 7), theme.chartPill) }
            let date = g.windowStart.addingTimeInterval((bounds[i] + 0.5) * 3600)
            let name = weekly ? monthDayLabel(g.windowStart.addingTimeInterval(bounds[i] * 3600), calendar: calendar, locale: locale)
                : weekdayAbbrev(date, calendar: calendar, locale: locale)
            let color = warn ? warnCol : current ? theme.ink : theme.chartLabel
            let label = Text(name, current || warn ? dayFontBold : dayFont, color, kern: 0.7)
            if current && weekly {
                // Widen today's pill to fit a date.
                ctx.fill(rounded(CGRect(x: cx - label.width / 2 - 7, y: H - 15, width: label.width + 14, height: 14), 7), theme.chartPill)
            }
            label.draw(x: cx + 0.35, baseline: H - 5, align: .center, in: ctx)
        }

        // Even pace diagonal (the week's glide; the session trail goes without).
        if let from = g.evenPaceFrom { ctx.stroke(line(X(from), Y(1), W, Y(0)), theme.chartDash, width: 1, dash: [3, 4]) }

        // History → runs, split at resets and at gaps > 2 h.
        let pts = g.points.enumerated().filter { $0.element.t >= 0 && $0.element.t <= g.nowT + 0.01 }
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        // A gap (Mac asleep or off) is only dotted when usage moved across it; flat, nothing happened.
        var rawRuns: [[GlideModel.Point]] = []
        var refills: Set<Int> = [] // runs that step up from the one before
        for p in pts {
            if let last = rawRuns.last?.last, !p.refill, p.t - last.t <= min(2.0, hours / 6) || abs(p.used - last.used) < 0.005 {
                rawRuns[rawRuns.count - 1].append(p)
            } else {
                if p.refill, !rawRuns.isEmpty { refills.insert(rawRuns.count) }
                rawRuns.append([p])
            }
        }
        var runs: [[CGPoint]] = rawRuns.map { run in decimate(run, step: hours / 56).map { CGPoint(x: X($0.t), y: Y(1 - $0.used)) } }
        let nowUsed = pts.last?.used ?? (1 - endR)
        let nx = X(g.nowT), ny = Y(1 - nowUsed)
        if runs.isEmpty { runs = [[CGPoint(x: 0, y: Y(1)), CGPoint(x: nx, y: ny)]] }
        if let l = runs.last?.last, abs(l.x - nx) > 0.5 { runs[runs.count - 1].append(CGPoint(x: nx, y: ny)) }

        var gapSegments: [(CGPoint, CGPoint)] = []
        var steps: [(CGPoint, CGPoint)] = []
        for i in runs.indices.dropFirst() {
            guard let prev = runs[i - 1].last, let first = runs[i].first else { continue }
            if refills.contains(i) { steps.append((prev, first)) } else { gapSegments.append((prev, first)) }
        }
        // Area fill under the whole history: one outline, the runs joined by their gaps and steps.
        let area = CGMutablePath()
        for run in runs { appendSmooth(run, to: area) }
        area.addLine(to: CGPoint(x: nx, y: Y(0)))
        area.addLine(to: CGPoint(x: runs.first?.first?.x ?? 0, y: Y(0)))
        area.closeSubpath()
        ctx.fillLinear(area, [col.fade(0.30), col.fade(0.06), col.fade(0)], from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bot), locations: [0, 0.75, 1])

        // Now drop line.
        ctx.stroke(line(nx, ny, nx, Y(0)), col.fade(0.45), width: 1, dash: [2, 3])

        // Line with glow; gaps dotted.
        // A run that never moves (a reset straight into a gap) would draw as a lone dot.
        for run in runs where run.contains(where: { $0 != run[0] }) {
            let s = smoothPath(run)
            ctx.withState {
                ctx.setAlpha(0.55)
                ctx.glowStroke(s, color: col, width: 4, blur: 5.2)
            }
            ctx.stroke(s, col, width: 2.1, cap: .round, join: .round)
        }
        // A reset refills the headroom: a straight step up.
        for (a, b) in steps {
            ctx.withState { ctx.setAlpha(0.7); ctx.stroke(line(a.x, a.y, b.x, b.y), col, width: 1.4, cap: .round) }
        }
        for (a, b) in gapSegments {
            ctx.withState { ctx.setAlpha(0.85); ctx.stroke(line(a.x, a.y, b.x, b.y), col, width: 2, dash: [0.1, 4.4], cap: .round) }
        }

        // Projection.
        let ex = X(endT), ey = Y(endR)
        ctx.withState { ctx.setAlpha(0.85); ctx.stroke(line(nx, ny, ex, ey), col, width: 2, dash: [0.1, 4.4], cap: .round) }
        var endRect = CGRect.null
        if g.runsOut {
            let halo = CGMutablePath(); halo.addEllipse(in: CGRect(x: ex - 9, y: ey - 9, width: 18, height: 18))
            ctx.fill(halo, warnCol.fade(0.18))
            Glyph.warning(in: CGRect(x: ex - 7, y: ey - 12, width: 14, height: 14), fill: warnCol, ink: theme.cardSolid, ctx: ctx)
        } else {
            let end = CGMutablePath(); end.addEllipse(in: CGRect(x: ex - 1.5 - 3, y: ey - 3, width: 6, height: 6))
            ctx.fill(end, theme.cardSolid)
            ctx.stroke(end, col, width: 1.6)
            if let label = g.endLabel {
                // Under the end point, unless that runs into the axis labels.
                let text = Text(label, F.sf(9.5, 650), col)
                let baseline = ey + 16 > bot + 4 ? ey - 9 : ey + 16
                let str = NSAttributedString(string: label, attributes: [.font: F.sf(9.5, 650), .foregroundColor: col])
                drawOutlined(str, center: CGPoint(x: W - text.width / 2, y: baseline), outline: theme.cardSolid, ctx: ctx)
                endRect = CGRect(x: W - text.width, y: baseline - 12, width: text.width, height: 16)
            }
        }

        // Now dot and chip.
        let haloNow = CGMutablePath(); haloNow.addEllipse(in: CGRect(x: nx - 8, y: ny - 8, width: 16, height: 16))
        ctx.fill(haloNow, col.fade(0.22))
        let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: nx - 3.8, y: ny - 3.8, width: 7.6, height: 7.6))
        ctx.fill(dot, col)
        ctx.stroke(dot, theme.cardSolid, width: 2)
        // The chip sits above the dot unless the line runs through there (a steep dive into now):
        // then it takes the first clear spot around the dot, or the least crowded one.
        let cw: CGFloat = 28, ch: CGFloat = 13
        let near = (runs.last ?? []).filter { $0.x >= nx - 2 * cw } + [CGPoint(x: nx, y: ny), CGPoint(x: ex, y: ey)]
        func crossings(_ r: CGRect) -> Int {
            let box = r.insetBy(dx: -2, dy: -2)
            return zip(near, near.dropFirst()).reduce(0) { n, seg in
                let (a, b) = seg
                let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y)))
                return n + (0...steps).filter { i in
                    let f = CGFloat(i) / CGFloat(steps)
                    return box.contains(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                }.count
            }
        }
        let spots = [(0, -23), (1, -21), (-1, 8), (0, 10), (-1, -21), (1, 8)].map { side, dy -> CGRect in
            let x = side == 0 ? nx - cw / 2 : side > 0 ? nx + 6 : nx - 6 - cw
            return CGRect(x: min(max(x, 1), W - cw - 1), y: min(max(ny + CGFloat(dy), 0), bot - ch - 2), width: cw, height: ch)
        }
        let chipRect = spots.first { crossings($0) == 0 } ?? spots.min { crossings($0) < crossings($1) }!
        let chip = rounded(chipRect, 6.5)
        ctx.fill(chip, theme.cardSolid.fade(0.85))
        ctx.fill(chip, col.fade(0.16))
        ctx.stroke(chip, col.fade(0.4), width: 0.6)
        Text("NOW", F.sf(7.8, 800), col, kern: 0.8).draw(x: chipRect.midX + 0.4, baseline: chipRect.maxY - 3.6, align: .center, in: ctx)

        // EVEN PACE label in the emptier half, outlined in the card color.
        guard let from = g.evenPaceFrom, X(hours) - X(from) > 120 else { return }
        let span = hours - from, nowIn = g.nowT - from
        let evenAt = from + (nowIn > span * 0.6 ? nowIn * 0.75 : nowIn + (span - nowIn) * 0.6)
        let evenY = Y(1 - (evenAt - from) / span)
        // Leave it out when it would sit on the end label; the dashed line reads on its own.
        guard !CGRect(x: X(evenAt) - 30, y: evenY - 14, width: 60, height: 16).intersects(endRect) else { return }
        let ly = evenY - 6
        let label = NSMutableAttributedString(string: "EVEN PACE", attributes: [.font: F.sf(8.5, 650), .kern: 0.6, .foregroundColor: theme.chartLabel])
        drawOutlined(label, center: CGPoint(x: X(evenAt), y: ly), outline: theme.cardSolid, ctx: ctx)
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
        let p = CGMutablePath(); p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)); return p
    }

    /// Appends `smoothPath(pts)` to the current subpath of `p`, joined to it by a straight line.
    private static func appendSmooth(_ pts: [CGPoint], to p: CGMutablePath) {
        guard let first = pts.first else { return }
        if p.isEmpty { p.move(to: first) } else { p.addLine(to: first) }
        smoothPath(pts).applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .addLineToPoint: p.addLine(to: e.points[0])
            case .addCurveToPoint: p.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .addQuadCurveToPoint: p.addQuadCurve(to: e.points[1], control: e.points[0])
            default: break
            }
        }
    }

    /// Keeps at most one point per `step` hours (plus the last), so the curve stays smooth.
    private static func decimate(_ pts: [GlideModel.Point], step: Double) -> [GlideModel.Point] {
        guard pts.count > 2 else { return pts }
        var out: [GlideModel.Point] = [pts[0]]
        for p in pts.dropFirst().dropLast() where p.t - out[out.count - 1].t >= step {
            out.append(p)
        }
        out.append(pts[pts.count - 1])
        return out
    }

    private static func weekdayAbbrev(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        Formatters.template("EEE", calendar: calendar, locale: locale).string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
    }

    /// "9 AM", or "09" on a 24-hour clock.
    private static func hourLabel(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        Formatters.template("j", calendar: calendar, locale: locale).string(from: date).uppercased()
    }

    private static func monthDayLabel(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        Formatters.template("MMMd", calendar: calendar, locale: locale).string(from: date).uppercased()
    }

    private static func drawOutlined(_ s: NSAttributedString, center: CGPoint, outline: NSColor, ctx: CGContext) {
        let outlined = NSMutableAttributedString(attributedString: s)
        let range = NSRange(location: 0, length: outlined.length)
        let size = (s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 8.5
        outlined.addAttributes([.strokeColor: outline, .strokeWidth: 3 / size * 100, .foregroundColor: outline], range: range)
        let w = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil)
        for str in [outlined as NSAttributedString, s] {
            let line = CTLineCreateWithAttributedString(str)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: center.x - w / 2, y: center.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
