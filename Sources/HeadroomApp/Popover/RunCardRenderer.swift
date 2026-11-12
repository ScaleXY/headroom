import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab: a card per agent run (title, state, the done / in-flight / not-started bar, the
/// figures, the warning and the rows), finished runs of the last day quieter below.
@MainActor
enum RunCardRenderer {
    static let padX: CGFloat = 14, padTop: CGFloat = 13, padBottom: CGFloat = 10
    static let rowHeight: CGFloat = 23, detailHeight: CGFloat = 14, indent: CGFloat = 16
    static let sectionHeaderHeight: CGFloat = 30

    static func color(_ tone: RunTone, _ t: Theme) -> NSColor {
        switch tone {
        case .progress: t.azure
        case .neutral: t.ink
        case .warn: t.amber
        case .alert: t.rose
        case .quiet: t.muted
        }
    }

    // MARK: Page

    /// Live cards, then the last day's finished ones under their own header. Returns the height.
    @discardableResult
    static func drawPage(_ page: RunsPageModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        var y = origin.y
        if page.isEmpty { return drawEmpty(origin: origin, width: width, theme: theme, ctx: ctx) }
        for (i, c) in page.live.enumerated() {
            if i > 0 { y += 10 }
            y += draw(c, origin: CGPoint(x: origin.x, y: y), width: width, theme: theme, ctx: ctx, out: out)
        }
        if !page.recent.isEmpty {
            if !page.live.isEmpty { y += 16 }
            if let ctx {
                let mid = y + 14
                Text(RunsPageModel.recentTitle, F.sf(15, 650), theme.ink, kern: -0.15).draw(x: origin.x + 3, capCenter: mid, in: ctx)
                if page.moreRecent > 0 {
                    Text("+ \(page.moreRecent) more", F.sf(11.5, 500), theme.muted).draw(x: origin.x + width - 3, capCenter: mid, align: .right, in: ctx)
                }
            }
            y += sectionHeaderHeight
            for (i, c) in page.recent.enumerated() {
                if i > 0 { y += 8 }
                y += draw(c, origin: CGPoint(x: origin.x, y: y), width: width, theme: theme, ctx: ctx, out: out)
            }
        }
        return y - origin.y
    }

    /// Nothing tracked yet: what makes a run appear, and how to get more out of it.
    static func drawEmpty(origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        // Commands in mono, as the terminal shows them.
        let text = NSMutableAttributedString(string: RunsPageModel.emptyBody, attributes: [.font: F.sf(12, 450), .foregroundColor: t.muted])
        let ns = RunsPageModel.emptyBody as NSString
        for cmd in ["headroom hooks install", "headroom task guide"] {
            let r = ns.range(of: cmd)
            if r.location != NSNotFound { text.addAttributes([.font: F.mono(11.5, 500), .foregroundColor: t.ink.fade(0.75)], range: r) }
        }
        let body = TextBlock(text, width: width - 28 - 34, lineHeight: 16)
        let h = 16 + 18 + 6 + body.height + 18
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: nil, theme: t, ctx: ctx)
        let x0 = origin.x + 14
        drawGlyph(.planned, color: t.muted, center: CGPoint(x: x0 + 9, y: origin.y + 16 + 9), size: 16, ctx: ctx)
        Text(RunsPageModel.emptyTitle, F.sf(14, 650), t.ink, kern: -0.07).draw(x: x0 + 34, capCenter: origin.y + 16 + 9, in: ctx)
        body.draw(x: x0 + 34, top: origin.y + 16 + 18 + 6, in: ctx)
        return h
    }

    // MARK: Card

    @discardableResult
    static func draw(_ m: RunCardModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let h = pass(m, origin: origin, width: width, theme: theme, ctx: nil, out: nil)
        guard let ctx else { return h }
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: h)
        if m.live {
            CardChrome.draw(rect, provider: m.provider, theme: theme, ctx: ctx)
        } else {
            // Finished: recessed and without the brand wash, so live work stands out above it.
            let shape = rounded(rect, 18)
            ctx.fill(shape, theme.groupFill)
            ctx.innerStroke(shape, theme.groupBorder, width: 0.5)
        }
        _ = pass(m, origin: origin, width: width, theme: theme, ctx: ctx, out: out)
        return h
    }

    private static func pass(_ m: RunCardModel, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        var y = origin.y + (m.live ? padTop : 11)
        let tone = color(m.tone, t)

        // Header: tile (or the state glyph on a finished card), title, chevron. The title gets the
        // whole width; the state sits on the headline line below.
        let headH: CGFloat = 20
        let tx = x0 + (m.live && m.provider != nil ? 28 : 20)
        if let ctx {
            if m.live, let p = m.provider {
                BrandMark.drawTile(p, in: CGRect(x: x0, y: y, width: 20, height: 20), ctx: ctx)
            } else {
                drawGlyph(m.glyph, color: tone, center: CGPoint(x: x0 + 6, y: y + 10), size: 11, ctx: ctx)
            }
            var right = x0 + w
            if m.expandable {
                drawChevron(up: m.expanded, center: CGPoint(x: right - 4, y: y + 10), color: t.muted, ctx: ctx)
                right -= 8 + 10
            }
            fit(m.title, F.sf(m.live ? 14 : 13, 650), m.live ? t.ink : t.ink.fade(0.85), width: right - tx, kern: -0.07)
                .draw(x: tx, capCenter: y + 10, in: ctx)
        }
        y += headH + 3
        if let ctx { fit(m.subtitle, F.sf(11.5, 500), t.muted, width: x0 + w - tx).draw(x: tx, capCenter: y + 6, in: ctx) }
        y += 13
        if m.expandable {
            out?.add(CGRect(x: origin.x, y: origin.y, width: width, height: y - origin.y + 4),
                     tooltip: m.expanded ? "Hide finished tasks" : "Show finished tasks", action: .toggleRun(m.id))
        }

        // Headline and state, bar and figures (a finished card puts them on one quiet line).
        let capsule = stateCapsule(m, theme: t)
        if m.live {
            y += 12
            if m.declared {
                if let ctx {
                    capsule.draw(right: x0 + w, mid: y + 11, ctx)
                    let big = Text(m.headline, F.sf(24, 700, tabular: true), t.ink, kern: -0.7)
                    let b = y + 19
                    big.draw(x: x0 - 0.5, baseline: b, in: ctx)
                    var ex = x0 + big.width + 5
                    let done = Text("done", F.sf(12.5, 600), t.muted)
                    done.draw(x: ex, baseline: b, in: ctx)
                    ex += done.width + 6
                    // The estimate gives way to the state: shortened first, then left out.
                    let room = x0 + w - capsule.width - 8 - ex
                    if let e = m.estimate, let est = [e + " by tokens", e].map({ Text($0, F.sf(11.5, 500), t.muted2) }).first(where: { $0.width <= room }) {
                        est.draw(x: ex, baseline: b, in: ctx)
                    }
                }
                y += 24 + 7
                if let bar = m.bar, let ctx { drawBar(bar, rect: CGRect(x: x0, y: y, width: w, height: 7), theme: t, ctx: ctx) }
                y += 7
            } else {
                if let ctx {
                    capsule.draw(right: x0 + w, mid: y + 9, ctx)
                    fit(m.headline, F.sf(15, 650), t.ink, width: w - capsule.width - 10, kern: -0.15).draw(x: x0, capCenter: y + 9, in: ctx)
                }
                y += 18
            }
            if !m.figures.isEmpty {
                y += 8
                if let ctx { fit(m.figures.joined(separator: " · "), F.sf(11.5, 500, tabular: true), t.muted, width: w).draw(x: x0, capCenter: y + 6, in: ctx) }
                y += 12
            }
        } else {
            y += 7
            if let ctx {
                capsule.draw(right: x0 + w, mid: y + 6, ctx)
                let line = ([m.declared ? m.headline + " done" : m.headline] + m.figures).joined(separator: " · ")
                fit(line, F.sf(11.5, 500, tabular: true), t.muted, width: x0 + w - capsule.width - 10 - tx).draw(x: tx, capCenter: y + 6, in: ctx)
            }
            y += 12
        }

        if let warning = m.warning {
            y += 10
            let block = TextBlock(warning, F.sf(11.5, 550), t.amber, width: w - 12 - 14 - 8 - 10, lineHeight: 15)
            let r = CGRect(x: x0, y: y, width: w, height: block.height + 12)
            if let ctx {
                let shape = rounded(r, 9)
                ctx.fill(shape, t.amber.fade(t.isDark ? 0.10 : 0.09))
                ctx.innerStroke(shape, t.amber.fade(0.28), width: 0.5)
                Glyph.warning(in: CGRect(x: r.minX + 10, y: r.minY + 6 + 7.5 - 6.5, width: 13, height: 13), fill: t.amber,
                              ink: t.isDark ? rgb(0x2A1E05) : .white, ctx: ctx)
                block.draw(x: r.minX + 10 + 14 + 8, top: r.minY + 6, in: ctx)
            }
            y += r.height
        }

        if !m.rows.isEmpty {
            y += m.live ? 11 : 8
            if let ctx { ctx.fill(CGPath(rect: CGRect(x: x0, y: y, width: w, height: 0.5), transform: nil), t.separator) }
            y += 4
            for row in m.rows {
                let h = rowHeight + (row.detail == nil ? 0 : detailHeight)
                if let ctx { drawRow(row, x: x0, y: y, w: w, theme: t, ctx: ctx) }
                if row.toggles { out?.add(CGRect(x: x0 - 6, y: y, width: w + 12, height: h), action: .toggleRun(m.id)) }
                y += h
            }
            y += 2
        } else {
            y += 4
        }
        return y + padBottom - origin.y
    }

    // MARK: Rows

    static func drawRow(_ row: RunRowModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext) {
        let mid = y + rowHeight / 2
        let ix = x + CGFloat(row.depth) * indent
        let tone = color(row.tone, t)
        let summary = row.kind != .task
        drawGlyph(row.glyph, color: summary ? t.muted2 : (row.glyph == .done ? t.muted : tone), center: CGPoint(x: ix + 5, y: mid), size: 10, ctx: ctx)
        let titleX = ix + 17
        // Right side: steps, then tokens.
        var right = x + w
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
        if let detail = row.detail {
            fit(detail, F.sf(11, 500), row.detailTone == .quiet ? t.muted : color(row.detailTone, t), width: x + w - titleX)
                .draw(x: titleX, capCenter: y + rowHeight + 1, in: ctx)
        }
    }

    // MARK: Pieces

    /// The run's state as a tinted capsule with a dot, drawn right-aligned.
    struct Capsule {
        var label: Text
        var tone: NSColor
        var strong: Bool
        var width: CGFloat { 7 + 6 + 5 + label.width + 8 }

        func draw(right: CGFloat, mid: CGFloat, _ ctx: CGContext) {
            let cap = CGRect(x: right - width, y: mid - 9.5, width: width, height: 19)
            let shape = rounded(cap, 9.5)
            ctx.fill(shape, tone.fade(strong ? 0.13 : 0.08))
            ctx.innerStroke(shape, tone.fade(strong ? 0.32 : 0.18), width: 0.5)
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: cap.minX + 7, y: cap.midY - 3, width: 6, height: 6))
            ctx.fill(dot, tone)
            label.draw(x: cap.minX + 7 + 6 + 5, capCenter: cap.midY, in: ctx)
        }
    }

    static func stateCapsule(_ m: RunCardModel, theme t: Theme) -> Capsule {
        let tone = color(m.tone, t)
        return Capsule(label: Text(m.stateText, F.sf(11, 650), tone), tone: tone, strong: m.tone != .neutral)
    }

    /// Done solid, in flight a lighter wash of the same blue, not started the empty track.
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

    static func drawChevron(up: Bool, center c: CGPoint, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        // Flipped: +y is down, so a chevron pointing up has its tips below its point.
        let dy: CGFloat = up ? -2 : 2
        p.move(to: CGPoint(x: c.x - 4, y: c.y - dy))
        p.addLine(to: CGPoint(x: c.x, y: c.y + dy))
        p.addLine(to: CGPoint(x: c.x + 4, y: c.y - dy))
        ctx.stroke(p, color, width: 1.5, cap: .round, join: .round)
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
        case .needsInput:
            ctx.fill(circle(5 * k), c)
            ctx.stroke(line([(0, -2.6), (0, 0.6)]), .white, width: 1.5 * k, cap: .round)
            ctx.fill(circle(0.85 * k, dy: 2.6 * k), .white)
        case .waiting:
            Glyph.pause(in: CGRect(x: center.x - 4 * k, y: center.y - 4.5 * k, width: 8 * k, height: 9 * k), color: c, ctx: ctx)
        case .parked, .partial:
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
