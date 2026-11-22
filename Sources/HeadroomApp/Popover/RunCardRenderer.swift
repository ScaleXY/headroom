import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab's shared pieces: tones and their colours, the empty state, the task map, buttons,
/// task rows and state glyphs. The list (`RunListRenderer`) and a run's page (`RunPageRenderer`)
/// are drawn from these.
@MainActor
enum RunCardRenderer {
    /// A task row, the note line under it, and the indent per level.
    static let rowHeight: CGFloat = 23, detailHeight: CGFloat = 14, indent: CGFloat = 16

    /// Vermilion: serious, and plainly not the rose that means "needs you".
    static func failure(_ t: Theme) -> NSColor { t.isDark ? rgb(0xFF6B4A) : rgb(0xC22E14) }

    /// The tone's colour; `.alert` on a failure (`.failed`, `.partial`) is the failure colour, not
    /// rose: rose is only ever a question.
    static func color(_ tone: RunTone, _ t: Theme, glyph: RunGlyph? = nil) -> NSColor {
        switch tone {
        case .progress: t.azure
        case .neutral: t.ink
        case .warn: t.amber
        case .alert: glyph == .failed || glyph == .partial ? failure(t) : t.rose
        case .quiet: t.muted
        }
    }

    // MARK: Empty

    /// Nothing tracked yet: what makes a run appear, and one button to set it up.
    static func drawEmpty(origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let x0 = origin.x + 14, tx = x0 + 34
        let body = TextBlock(RunsPageModel.emptyBody, F.sf(12, 450), t.muted, width: width - 28 - 34, lineHeight: 16)
        let buttonTop = origin.y + 16 + 18 + 6 + body.height + 12
        let h = buttonTop - origin.y + 28 + 16
        let button = pillRect(RunsPageModel.emptyAction, x: tx, top: buttonTop)
        out?.add(button, action: .connectAgents)
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: nil, theme: t, ctx: ctx)
        drawGlyph(.planned, color: t.muted, center: CGPoint(x: x0 + 9, y: origin.y + 16 + 9), size: 16, ctx: ctx)
        Text(RunsPageModel.emptyTitle, F.sf(14, 650), t.ink, kern: -0.07).draw(x: tx, capCenter: origin.y + 16 + 9, in: ctx)
        body.draw(x: tx, top: origin.y + 16 + 18 + 6, in: ctx)
        drawPill(RunsPageModel.emptyAction, rect: button, theme: t, ctx: ctx)
        return h
    }

    // MARK: Header pieces

    /// The provider's tile; a run with no known provider gets its state glyph on a plain tile.
    static func drawTile(_ m: RunCardModel, rect: CGRect, tone: NSColor, theme t: Theme, ctx: CGContext) {
        if let p = m.provider {
            BrandMark.drawTile(p, in: rect, theme: t, ctx: ctx)
        } else {
            ctx.fill(rounded(rect, rect.width * 0.27), t.chipFill)
            drawGlyph(m.glyph, color: tone, center: CGPoint(x: rect.midX, y: rect.midY), size: rect.width * 0.5, ctx: ctx)
        }
    }

    // MARK: Callout

    /// A warning in Pace's callout grammar: an amber tile with the warning glyph and the sentence.
    static func drawCallout(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let block = TextBlock(text, F.sf(12.5, 500), t.ink.fade(0.92), width: w - 22 - 22 - 10, lineHeight: 16)
        let h = max(38, block.height + 16)
        guard let ctx else { return h }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let shape = rounded(rect, 12)
        ctx.fill(shape, t.amber.fade(t.isDark ? 0.10 : 0.08))
        ctx.innerStroke(shape, t.amber.fade(t.isDark ? 0.26 : 0.30), width: 0.5)
        let icon = CGRect(x: rect.minX + 10, y: rect.midY - 11, width: 22, height: 22)
        ctx.fill(rounded(icon, 6.5), t.amber.fade(0.18))
        Glyph.warning(in: icon.insetBy(dx: 4.5, dy: 4.5), fill: t.amber, ink: t.cardSolid, ctx: ctx)
        block.draw(x: icon.maxX + 10, top: rect.midY - block.height / 2, in: ctx)
        return h
    }

    // MARK: Buttons

    /// `pearl`: ink filled, the primary way forward on a calm run (your turn, left).
    enum PillStyle { case azure, rose, plain, pearl }

    static func pillRect(_ label: String, x: CGFloat, top: CGFloat) -> CGRect {
        CGRect(x: x, y: top, width: Text(label, F.sf(12, 650), .black).width + 26, height: 26)
    }

    /// A compact button: azure (the popover's primary, as in the update banner), rose (act on a
    /// question), or plain.
    static func drawPill(_ label: String, rect r: CGRect, theme t: Theme, ctx: CGContext, style: PillStyle = .azure) {
        let shape = rounded(r, r.height / 2)
        switch style {
        case .azure, .rose:
            let (top, bottom, glow): (NSColor, NSColor, NSColor) = style == .azure
                ? { let c = t.pacing(.plenty); return (c.top, c.bottom, c.glow) }()
                : (t.isDark ? rgb(0xFF7F95) : rgb(0xE23A5C), t.isDark ? rgb(0xE8445F) : rgb(0xC81C40), t.rose)
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: glow.fade(0.45).cgColor)
                ctx.fill(shape, bottom)
            }
            ctx.fillVertical(shape, top, bottom)
            ctx.withState {
                ctx.addPath(shape); ctx.clip()
                ctx.fill(CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: 0.75), transform: nil), white(0.35))
            }
            Text(label, F.sf(12, 650), .white).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
        case .pearl:
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: black(t.isDark ? 0.4 : 0.12).cgColor)
                ctx.fill(shape, t.isDark ? rgb(0xF4F4F6) : rgb(0x1C1C1E))
            }
            Text(label, F.sf(12, 650), t.isDark ? rgb(0x1C1C1E) : .white).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
        case .plain:
            ctx.fill(shape, t.isDark ? white(0.08) : white(0.85))
            ctx.innerStroke(shape, t.isDark ? white(0.10) : black(0.08), width: 0.75)
            Text(label, F.sf(12, 650), t.ink).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
        }
    }

    // MARK: Map

    /// The task map in the meter's own grammar: the recessed track, 16pt cells, closed work lit
    /// with the azure glow, work under way filled as far as it has got, untouched cells empty; a
    /// cell that needs you in rose, one that's stuck in amber, a failure hatched in vermilion. One
    /// cell per counted task, as wide as its share.
    static func drawMap(_ segs: [RunSegment], rect: CGRect, theme t: Theme, ctx: CGContext) {
        let track = rounded(rect, 12)
        ctx.fill(track, t.meterTrack)
        if t.isDark {
            ctx.innerShadow(track, color: black(0.45), blur: 2, dy: 1)
            ctx.innerStroke(track, t.meterTrackBorder, width: 0.5)
        } else {
            ctx.innerShadow(track, color: black(0.08), blur: 2, dy: 1)
        }
        let n = segs.count
        let inner = rect.insetBy(dx: 3, dy: 3)
        let gap: CGFloat = n > 20 ? 2 : 3, minW: CGFloat = 5
        let avail = inner.width - gap * CGFloat(n - 1)
        let spare = max(0, avail - minW * CGFloat(n))
        let endR: CGFloat = 9, innerR: CGFloat = n > 12 ? 2.5 : 4
        var x = inner.minX
        for (i, s) in segs.enumerated() {
            let bw = avail > minW * CGFloat(n) ? minW + CGFloat(s.weight) * spare : avail / CGFloat(n)
            let r = CGRect(x: x, y: inner.minY, width: bw, height: 16)
            let left = i == 0 ? endR : innerR, right = i == n - 1 ? endR : innerR
            let shape = rounded(r, left: left, right: right)
            ctx.fill(shape, t.meterEmpty)
            let f = CGFloat(min(max(s.fill, 0), 1))
            if s.failed {
                let c = failure(t)
                ctx.fill(shape, c.fade(0.35))
                hatch(shape, color: c.fade(0.85), ctx: ctx)
            } else if f > 0 {
                let pc: PacingColors = switch s.tone {
                case .alert: t.pacing(.veryTight)
                case .warn: t.pacing(.tight)
                default: t.pacing(.plenty)
                }
                let colors: (top: NSColor, bottom: NSColor, glow: NSColor) = s.tone == .quiet
                    ? (t.muted.fade(0.7), t.muted.fade(0.5), .clear) : (pc.top, pc.bottom, pc.glow)
                if f >= 1 {
                    if s.tone != .quiet { ctx.glow(shape, color: colors.glow, blur: 12, base: colors.bottom) }
                    ctx.fillVertical(shape, colors.top, colors.bottom)
                    // The lit cell's edges, as the meter's: a light line on top, a dark one under.
                    ctx.withState {
                        ctx.addPath(shape); ctx.clip()
                        let hi = CGMutablePath(); hi.addPath(shape); hi.addPath(rounded(r.offsetBy(dx: 0, dy: 1), left: left, right: right))
                        ctx.addPath(hi); ctx.setFillColor(white(0.62).cgColor); ctx.fillPath(using: .evenOdd)
                        let lo = CGMutablePath(); lo.addPath(shape); lo.addPath(rounded(r.offsetBy(dx: 0, dy: -1), left: left, right: right))
                        ctx.addPath(lo); ctx.setFillColor(black(0.12).cgColor); ctx.fillPath(using: .evenOdd)
                    }
                } else {
                    // Under way: the cell's colour as a wash, lit as far as it has got.
                    ctx.withState {
                        ctx.addPath(shape); ctx.clip()
                        ctx.fill(CGPath(rect: r, transform: nil), colors.bottom.fade(t.isDark ? 0.22 : 0.16))
                        let lit = CGRect(x: r.minX, y: r.minY, width: max(r.width * f, 3), height: r.height)
                        ctx.fillVertical(CGPath(rect: lit, transform: nil), colors.top, colors.bottom)
                    }
                }
            }
            x += bw + gap
        }
    }

    /// The x of each segment's middle on `track`, as `drawMap` lays them out.
    static func centers(_ segs: [RunSegment], track: CGRect) -> [CGFloat] {
        let n = segs.count
        let inner = track.insetBy(dx: 3, dy: 3)
        let gap: CGFloat = n > 20 ? 2 : 3, minW: CGFloat = 5
        let avail = inner.width - gap * CGFloat(n - 1)
        let spare = max(0, avail - minW * CGFloat(n))
        var x = inner.minX
        return segs.map { s in
            let bw = avail > minW * CGFloat(n) ? minW + CGFloat(s.weight) * spare : avail / CGFloat(n)
            defer { x += bw + gap }
            return x + bw / 2
        }
    }

    /// Diagonal hatching inside `path`: the failure texture, and the paused stretch of a timeline.
    static func hatch(_ path: CGPath, color: NSColor, spacing: CGFloat = 3.5, lineWidth: CGFloat = 1.1, ctx: CGContext) {
        let b = path.boundingBox
        ctx.withState {
            ctx.addPath(path); ctx.clip()
            let p = CGMutablePath()
            var x = b.minX - b.height
            while x < b.maxX {
                p.move(to: CGPoint(x: x, y: b.maxY)); p.addLine(to: CGPoint(x: x + b.height, y: b.minY))
                x += spacing
            }
            ctx.stroke(p, color, width: lineWidth)
        }
    }

    /// Done solid, in flight a lighter wash of the same blue, not started the empty track. The
    /// stand-in for the map when the run has no task shares.
    static func drawBar(_ p: TaskProgress, rect r: CGRect, theme t: Theme, ctx: CGContext) {
        let track = rounded(r, r.height / 2)
        ctx.fill(track, t.meterTrack)
        if t.isDark { ctx.innerStroke(track, t.meterTrackBorder, width: 0.5) }
        let colors = t.pacing(.plenty)
        let done = r.width * CGFloat(min(max(p.done, 0), 1))
        let flight = r.width * CGFloat(min(max(p.inFlight, 0), 1 - min(max(p.done, 0), 1)))
        ctx.withState {
            ctx.addPath(track); ctx.clip()
            if flight > 0 {
                let f = CGRect(x: r.minX + done, y: r.minY, width: flight, height: r.height)
                ctx.fill(CGPath(rect: f, transform: nil), colors.bottom.fade(t.isDark ? 0.32 : 0.22))
            }
            if done > 0 {
                let d = rounded(CGRect(x: r.minX, y: r.minY, width: max(done, r.height), height: r.height), r.height / 2)
                ctx.fillVertical(d, colors.top, colors.bottom)
            }
        }
    }

    // MARK: Receipt

    /// The parts of the run's time worth a mark: working in the pacing azure's quiet cousin
    /// (graphite, since a finished run isn't progress), waiting on you in rose, on a limit in
    /// amber, idle faint.
    static func splitParts(_ s: TaskTimeSplit, theme t: Theme) -> [(label: String, seconds: Double, color: NSColor)] {
        guard s.total >= 60 else { return [] }
        let all: [(String, Double, NSColor)] = [("working", s.working, t.ink.fade(t.isDark ? 0.62 : 0.55)), ("waiting on you", s.waitingInput, t.rose),
                                                ("on a limit", s.waitingLimit, t.amber), ("idle", s.idle, t.faint)]
        return all.filter { $0.1 >= 30 }.map { (label: $0.0, seconds: $0.1, color: $0.2) }
    }

    // MARK: Rows

    /// An opened row's labelled lines, laid out once per pass.
    struct DetailPanel {
        static let labelWidth: CGFloat = 86
        var lines: [(Text, TextBlock)]
        var height: CGFloat

        init(_ details: [RunDetailLine], width: CGFloat, theme t: Theme) {
            lines = details.map {
                (Text($0.label, F.sf(10.5, 650), t.muted),
                 TextBlock($0.value, F.sf(11.5, 500), t.ink.fade(0.86), width: width - 20 - Self.labelWidth, lineHeight: 15))
            }
            height = 8 + lines.reduce(0) { $0 + $1.1.height } + CGFloat(max(lines.count - 1, 0)) * 4 + 8
        }
    }

    static func drawRow(_ row: RunRowModel, panel: DetailPanel? = nil, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext) {
        let mid = y + rowHeight / 2
        let ix = x + CGFloat(row.depth) * indent
        let tone = color(row.tone, t, glyph: row.glyph)
        let summary = row.kind != .task
        drawGlyph(row.glyph, color: summary ? t.muted2 : (row.glyph == .done ? t.muted : tone), center: CGPoint(x: ix + 5, y: mid), size: 10, ctx: ctx)
        let titleX = ix + 17
        // Right side: the disclosure, then tokens, then steps.
        var right = x + w
        if row.opens {
            drawDisclosure(open: panel != nil, center: CGPoint(x: right - 3.5, y: mid), color: t.muted2, ctx: ctx)
            right -= 7 + 8
        }
        if let tokens = row.tokens {
            let tt = Text(tokens, F.sf(11, 500, tabular: true), t.muted2)
            tt.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= tt.width + 8
        }
        if let steps = row.steps {
            let st = Text(steps, F.sf(11.5, 600, tabular: true), t.ink.fade(row.quiet ? 0.45 : 0.7))
            st.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= st.width + 8
        }
        var marker: (Text, CGFloat, NSColor)?
        if let m = row.marker {
            let c = m == "critical" ? t.ink.fade(0.8) : t.muted
            let mt = Text(m.uppercased(), F.sf(8, 700), c, kern: 0.5)
            marker = (mt, mt.width + 10, c)
        }
        let titleFont = summary ? F.sf(12, 500) : F.sf(12.5, 550)
        let titleColor = summary ? t.muted : row.quiet ? t.muted : t.ink
        let title = fit(row.title, titleFont, titleColor, width: right - titleX - (marker.map { $0.1 + 6 } ?? 0))
        title.draw(x: titleX, capCenter: mid, in: ctx)
        if let (mt, mw, c) = marker {
            let r = CGRect(x: titleX + title.width + 6, y: mid - 6.5, width: mw, height: 13)
            ctx.fill(rounded(r, 4), c.fade(0.12))
            mt.draw(x: r.midX + 0.25, capCenter: r.midY, align: .center, in: ctx)
        }
        if let panel {
            // Opened: the details in full stand in for the one-line note.
            let px = titleX - 8, pw = x + w - px
            let box = CGRect(x: px, y: y + rowHeight - 1, width: pw, height: panel.height)
            ctx.fill(rounded(box, 9), t.isDark ? white(0.045) : black(0.035))
            var ly = box.minY + 8
            for (label, value) in panel.lines {
                label.draw(x: px + 10, capCenter: ly + 7.5, in: ctx)
                value.draw(x: px + 10 + DetailPanel.labelWidth, top: ly, in: ctx)
                ly += value.height + 4
            }
        } else if let detail = row.detail {
            fit(detail, F.sf(11, 500), row.detailTone == .quiet ? t.muted : color(row.detailTone, t, glyph: row.glyph), width: x + w - titleX)
                .draw(x: titleX, capCenter: y + rowHeight + 1, in: ctx)
        }
    }

    // MARK: Pieces

    static func drawChevron(up: Bool, center c: CGPoint, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        // Flipped: +y is down, so a chevron pointing up has its tips below its point.
        let dy: CGFloat = up ? -2 : 2
        p.move(to: CGPoint(x: c.x - 4, y: c.y - dy))
        p.addLine(to: CGPoint(x: c.x, y: c.y + dy))
        p.addLine(to: CGPoint(x: c.x + 4, y: c.y - dy))
        ctx.stroke(p, color, width: 1.5, cap: .round, join: .round)
    }

    /// A row that opens: a small chevron, pointing right while closed and down while open.
    static func drawDisclosure(open: Bool, center c: CGPoint, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        if open {
            p.move(to: CGPoint(x: c.x - 3, y: c.y - 1.5)); p.addLine(to: CGPoint(x: c.x, y: c.y + 1.5)); p.addLine(to: CGPoint(x: c.x + 3, y: c.y - 1.5))
        } else {
            p.move(to: CGPoint(x: c.x - 1.5, y: c.y - 3)); p.addLine(to: CGPoint(x: c.x + 1.5, y: c.y)); p.addLine(to: CGPoint(x: c.x - 1.5, y: c.y + 3))
        }
        ctx.stroke(p, color, width: 1.4, cap: .round, join: .round)
    }

    /// A state mark drawn in a `size` box around `center`.
    static func drawGlyph(_ g: RunGlyph, color c: NSColor, center: CGPoint, size s: CGFloat, ctx: CGContext) {
        let k = s / 10
        func circle(_ r: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CGMutablePath {
            let p = CGMutablePath(); p.addEllipse(in: CGRect(x: center.x + dx - r, y: center.y + dy - r, width: r * 2, height: r * 2)); return p
        }
        func line(_ pts: [(CGFloat, CGFloat)]) -> CGMutablePath {
            let p = CGMutablePath()
            for (i, q) in pts.enumerated() {
                let pt = CGPoint(x: center.x + q.0 * k, y: center.y + q.1 * k)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
        switch g {
        case .planned:
            ctx.stroke(circle(3.9 * k), c.fade(0.8), width: 1.3 * k)
        case .running:
            ctx.fill(circle(5 * k), c.fade(0.2))
            ctx.fill(circle(3 * k), c)
        case .stale:
            ctx.stroke(circle(3.9 * k), c, width: 1.3 * k)
            ctx.fill(circle(1.5 * k), c)
        case .yourTurn:
            // A ring around a dot: the ball is with you.
            ctx.stroke(circle(4.4 * k), c.fade(0.85), width: 1.1 * k)
            ctx.fill(circle(2.3 * k), c)
        case .needsInput:
            ctx.fill(circle(5 * k), c)
            ctx.stroke(line([(0, -2.6), (0, 0.6)]), .white, width: 1.5 * k, cap: .round)
            ctx.fill(circle(0.85 * k, dy: 2.6 * k), .white)
        case .waiting:
            Glyph.pause(in: CGRect(x: center.x - 4 * k, y: center.y - 4.5 * k, width: 8 * k, height: 9 * k), color: c, ctx: ctx)
        case .parked, .partial, .left:
            ctx.stroke(circle(3.9 * k), c, width: 1.3 * k)
            let half = CGMutablePath()
            half.addArc(center: center, radius: 3.9 * k, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
            half.closeSubpath()
            ctx.fill(half, c)
        case .stopped:
            ctx.fill(rounded(CGRect(x: center.x - 3.5 * k, y: center.y - 3.5 * k, width: 7 * k, height: 7 * k), 1.6 * k), c)
        case .done:
            ctx.stroke(line([(-3.6, 0.2), (-1.1, 2.7), (3.7, -2.6)]), c, width: 1.6 * k, cap: .round, join: .round)
        case .failed:
            ctx.stroke(line([(-3, -3), (3, 3)]), c, width: 1.6 * k, cap: .round)
            ctx.stroke(line([(3, -3), (-3, 3)]), c, width: 1.6 * k, cap: .round)
        case .skipped:
            ctx.stroke(circle(3.9 * k), c.fade(0.8), width: 1.2 * k)
            ctx.stroke(line([(-2.6, 2.6), (2.6, -2.6)]), c.fade(0.8), width: 1.2 * k, cap: .round)
        case .more:
            for dx in [-3.0, 0, 3.0] as [CGFloat] {
                ctx.fill(circle(0.95 * k, dx: dx * k), c)
            }
        }
    }

    /// A " · " line in one row: parts drop off the end until it fits (so "updated 8m ago" goes
    /// whole rather than as "upda…"), and a single part too long is cut.
    static func fitParts(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat) -> Text {
        var parts = s.components(separatedBy: " · ")
        while parts.count > 1, Text(parts.joined(separator: " · "), font, color).width > width { parts.removeLast() }
        return fit(parts.joined(separator: " · "), font, color, width: width)
    }

    /// `s` in one line, cut with an ellipsis to fit `width`.
    static func fit(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat, kern: CGFloat = 0) -> Text {
        let full = Text(s, font, color, kern: kern)
        guard full.width > width else { return full }
        let chars = Array(s)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Text(String(chars[..<mid]).trimmingCharacters(in: .whitespaces) + "…", font, color, kern: kern).width <= width { lo = mid } else { hi = mid - 1 }
        }
        return Text(String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…", font, color, kern: kern)
    }
}
