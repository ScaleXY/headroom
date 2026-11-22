import AppKit
import HeadroomKit
import HeadroomPresent

/// Activity card (redesign §5): the provider's cost leads the header with its tokens under the
/// name, the chart in the provider's tone ramp, one composition bar with a three-column key, and
/// the breakdown by model.
@MainActor
enum ActivityCardRenderer {
    static let padTop: CGFloat = 13, padX: CGFloat = 14, padBottom: CGFloat = 12
    static let chartVB = CGSize(width: 300, height: 118)
    static let headerHeight: CGFloat = 34

    struct Layout {
        var chartRect: CGRect = .zero
        var barWidth: CGFloat = 0
        var barCount: Int = 0
        var breakdownHeader: CGRect = .zero
    }

    @discardableResult
    static func draw(_ m: ActivityCardModel, mode: ActivityMode, breakdown: BreakdownKind, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil, layout: UnsafeMutablePointer<Layout>? = nil) -> CGFloat {
        let h = pass(m, mode: mode, breakdown: breakdown, origin: origin, width: width, theme: theme, ctx: nil, out: nil, layout: layout)
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: m.provider, theme: theme, ctx: ctx)
        _ = pass(m, mode: mode, breakdown: breakdown, origin: origin, width: width, theme: theme, ctx: ctx, out: out, layout: layout)
        return h
    }

    /// The provider's tone for a token class (26 / 62 / 100%).
    static func color(_ kind: TokenPart.Kind, _ p: Provider, _ theme: Theme) -> NSColor {
        theme.providerTone(p, CGFloat(kind.toneStrength))
    }

    private static func pass(_ m: ActivityCardModel, mode: ActivityMode, breakdown: BreakdownKind, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput?, layout: UnsafeMutablePointer<Layout>?) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        var y = origin.y + padTop

        // Header: tile, name over its tokens (and the selection chip), cost on the right.
        if let ctx { drawHeader(m, mode: mode, x0: x0, y: y, w: w, theme: theme, ctx: ctx, out: out) }
        y += headerHeight

        // Chart.
        y += 10
        let ch = chartVB.height * w / chartVB.width
        let chart = CGRect(x: x0, y: y, width: w, height: ch)
        if let ctx { drawBars(m, mode: mode, rect: chart, theme: theme, ctx: ctx) }
        if let layout {
            let s = w / chartVB.width
            layout.pointee.chartRect = CGRect(x: x0, y: y, width: (chartVB.width - 30) * s, height: (chartVB.height - 18) * s)
            layout.pointee.barCount = m.bars.count
            layout.pointee.barWidth = m.bars.isEmpty ? 0 : (chartVB.width - 30) * s / CGFloat(m.bars.count)
        }
        y += ch

        // One composition bar, then its key in three columns.
        let parts = m.composition(mode)
        y += 10
        if let ctx { drawComposition(parts, provider: m.provider, rect: CGRect(x: x0, y: y, width: w, height: 6), theme: theme, ctx: ctx) }
        y += 6 + 8
        if let ctx { drawKey(parts, provider: m.provider, x0: x0, y: y, w: w, theme: theme, ctx: ctx) }
        y += keyHeight

        // Breakdown, under a hairline.
        y += 10
        if let ctx {
            ctx.fill(CGPath(rect: CGRect(x: x0, y: y - 0.5, width: w, height: 0.5), transform: nil), theme.isDark ? white(0.08) : black(0.07))
        }
        y += 9
        let rows = m.breakdown[breakdown] ?? []
        let headFont = F.sf(11, 600)
        if let ctx {
            let head = Text(breakdown.title + " ▾", headFont, theme.muted)
            head.draw(x: x0, baseline: baseline(top: y, font: headFont, lineHeight: 13), in: ctx)
            out?.add(CGRect(x: x0 - 4, y: y - 4, width: head.width + 8, height: 21), tooltip: "Break down by model, project or token class",
                     action: .breakdownMenu(m.provider), hover: 6)
            Text("incl. cached reads", F.sf(11, 500), theme.muted2).draw(x: x0 + w, baseline: baseline(top: y, font: F.sf(11, 500), lineHeight: 13), align: .right, in: ctx)
        }
        if let layout { layout.pointee.breakdownHeader = CGRect(x: x0 - 4, y: y - 4, width: 120, height: 21) }
        y += 13 + 3
        let rowH: CGFloat = 22.8
        for row in rows {
            if let ctx {
                let font = F.sf(12, 500, tabular: true)
                let b = baseline(top: y, font: font, lineHeight: rowH)
                let nameW: CGFloat = 82, costW: CGFloat = 58, pctW: CGFloat = 30, gap: CGFloat = 8
                Text(truncate(row.name, width: nameW + 6), F.sf(12, 500), theme.ink).draw(x: x0, baseline: b, in: ctx)
                let barX = x0 + nameW + gap, barW = w - nameW - costW - pctW - gap * 3
                let track = CGRect(x: barX, y: y + rowH / 2 - 2.5, width: barW, height: 5)
                ctx.fill(rounded(track, 2.5), theme.isDark ? white(0.06) : black(0.05))
                let fillW = max(2, barW * CGFloat(min(max(row.share, 0), 1)))
                ctx.fill(rounded(CGRect(x: barX, y: track.minY, width: fillW, height: 5), 2.5), theme.providerTone(m.provider, CGFloat(ProviderTone.modelBar)))
                Text(NumberFormat.dollars(micros: row.micros, style: .precise), F.sf(12, 650, tabular: true), theme.ink)
                    .draw(x: x0 + w - pctW - gap, baseline: b, align: .right, in: ctx)
                Text("\(Int((row.share * 100).rounded()))%", F.sf(11, 500, tabular: true), theme.ink.fade(0.5)).draw(x: x0 + w, baseline: b, align: .right, in: ctx)
            }
            y += rowH
        }
        if let note = m.footnote {
            y += 7
            let block = TextBlock(note, F.sf(10.5, 500), theme.muted2, width: w, lineHeight: 13)
            if let ctx { block.draw(x: x0, top: y, in: ctx) }
            y += block.height
        }
        y += padBottom - 2
        return y - origin.y
    }

    // MARK: Header

    private static func drawHeader(_ m: ActivityCardModel, mode: ActivityMode, x0: CGFloat, y: CGFloat, w: CGFloat, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        let mid = y + headerHeight / 2
        BrandMark.drawTile(m.provider, in: CGRect(x: x0, y: mid - 13, width: 26, height: 26), theme: theme, ctx: ctx)
        // Cost (19 pt) over "at API rates", right-aligned.
        let cost = Text(NumberFormat.dollars(micros: m.micros, style: .precise), F.sf(19, 700, tabular: true), theme.ink, kern: -0.475)
        cost.draw(x: x0 + w, capCenter: y + 10, align: .right, in: ctx)
        let rates = Text("at API rates", F.sf(10.5, 500), theme.muted)
        rates.draw(x: x0 + w, capCenter: y + 27, align: .right, in: ctx)
        let costW = max(cost.width, rates.width)

        let tx = x0 + 26 + 9
        Text(m.provider.displayName, F.sf(15, 650), theme.ink, kern: -0.075).draw(x: tx, capCenter: y + 9, in: ctx)
        let sub = Text(NumberFormat.tokens(m.shownTokens(mode)) + (mode.includesCachedReads ? " tokens" : " new tokens"), F.sf(11.5, 500, tabular: true), theme.muted)
        sub.draw(x: tx, capCenter: y + 27, in: ctx)
        guard m.isSubRange else { return }
        // The selection's span, with an × that clears it: after the tokens, or after the name when
        // it only fits there; without its duration before it's cut short.
        let font = F.sf(10.5, 600, tabular: true)
        let x = Text("×", F.sf(12, 500), theme.ink.fade(0.6))
        let chrome = 7 + 5 + x.width + 4
        let right = x0 + w - costW - 10
        let name = Text(m.provider.displayName, F.sf(15, 650), theme.ink, kern: -0.075)
        let short = m.spanLabel.components(separatedBy: " · ").first ?? m.spanLabel
        let rows: [(x: CGFloat, mid: CGFloat)] = [(tx + sub.width + 6, y + 27), (tx + name.width + 8, y + 9)]
        var place = (x: rows[0].x, mid: rows[0].mid, text: fit(m.spanLabel, font: font, width: right - rows[0].x - chrome))
        search: for text in [m.spanLabel, short] {
            for row in rows where Text(text, font, .black).width + chrome <= right - row.x {
                place = (row.x, row.mid, text)
                break search
            }
        }
        let label = Text(place.text, font, theme.ink)
        let chip = CGRect(x: place.x, y: place.mid - 8, width: chrome + label.width, height: 16)
        ctx.fill(rounded(chip, 6), theme.isDark ? white(0.08) : black(0.05))
        label.draw(x: chip.minX + 7, capCenter: chip.midY, in: ctx)
        x.draw(x: chip.maxX - 4 - x.width, capCenter: chip.midY - 0.5, in: ctx)
        out?.add(chip, tooltip: m.spanLong + " · click to show the whole range", action: .clearSelection, hover: 6)
    }

    /// Shortens `s` with an ellipsis until it fits `width`.
    static func fit(_ s: String, font: NSFont, width: CGFloat) -> String {
        var t = s
        while Text(t, font, .black).width > width, t.count > 4 { t = String(t.dropLast(2)) + "…" }
        return t
    }

    private static func truncate(_ s: String, width: CGFloat) -> String { fit(s, font: F.sf(12, 500), width: width) }

    // MARK: Composition

    /// Widths for parts sharing `avail` points: each part with tokens gets at least `minimum`,
    /// taken from the widest.
    static func widths(_ shares: [Double], avail: CGFloat, minimum: CGFloat = 4) -> [CGFloat] {
        var widths = shares.map { $0 > 0 ? max(minimum, CGFloat($0) * avail) : 0 }
        let excess = widths.reduce(0, +) - avail
        if excess > 0, let big = widths.indices.max(by: { widths[$0] < widths[$1] }) { widths[big] = max(0, widths[big] - excess) }
        return widths
    }

    static func drawComposition(_ parts: [TokenPart], provider: Provider, rect: CGRect, theme: Theme, ctx: CGContext) {
        let shown = parts.filter { $0.tokens > 0 }
        guard !shown.isEmpty else {
            ctx.fill(rounded(rect, rect.height / 2), theme.isDark ? white(0.06) : black(0.05))
            return
        }
        let gaps = CGFloat(shown.count - 1) * 2
        let ws = widths(shown.map(\.share), avail: rect.width - gaps)
        ctx.withState {
            ctx.addPath(rounded(rect, rect.height / 2)); ctx.clip()
            var x = rect.minX
            for (i, part) in shown.enumerated() where ws[i] > 0 {
                ctx.fill(CGPath(rect: CGRect(x: x, y: rect.minY, width: ws[i], height: rect.height), transform: nil), color(part.kind, provider, theme))
                x += ws[i] + 2
            }
        }
    }

    static let keyHeight: CGFloat = 13 + 2 + 17

    /// Three columns: a swatch and the class's name, then its tokens and share.
    static func drawKey(_ parts: [TokenPart], provider: Provider, x0: CGFloat, y: CGFloat, w: CGFloat, theme: Theme, ctx: CGContext) {
        let colW = (w - 12) / 3
        for (i, part) in parts.prefix(3).enumerated() {
            let x = x0 + CGFloat(i) * (colW + 6)
            ctx.fill(rounded(CGRect(x: x, y: y + 3, width: 7, height: 7), 2), color(part.kind, provider, theme))
            Text(part.label, F.sf(10.5, 500), theme.muted).draw(x: x + 12, capCenter: y + 6.5, in: ctx)
            let valueFont = F.sf(14, 700, tabular: true)
            let b = baseline(top: y + 13 + 2, font: valueFont, lineHeight: 17)
            let v = Text(NumberFormat.tokens(part.tokens), valueFont, theme.ink, kern: -0.14)
            v.draw(x: x, baseline: b, in: ctx)
            Text(NumberFormat.percent(part.share), F.sf(10, 500, tabular: true), theme.ink.fade(0.5)).draw(x: x + v.width + 3, baseline: b, in: ctx)
        }
    }

    // MARK: Bars

    static func niceMax(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(v)))
        for m in [1.0, 2, 2.5, 4, 5, 8, 10] where m * e >= v * 1.04 { return m * e }
        return 10 * e
    }

    /// Heights of a bar's stacked parts (bottom first) that add up to `h`: a part with tokens
    /// shows at least `minimum` while the bar has room, and the top part takes what's left.
    static func stack(_ values: [Double], height h: CGFloat, minimum: CGFloat = 1.6) -> [CGFloat] {
        let total = values.reduce(0, +)
        guard total > 0, h > 0 else { return values.map { _ in 0 } }
        var hs = values.map { CGFloat($0 / total) * h }
        let lastIndex = values.lastIndex { $0 > 0 } ?? 0
        for i in hs.indices where i != lastIndex && values[i] > 0 { hs[i] = max(hs[i], minimum) }
        let below = hs.indices.filter { $0 != lastIndex }.reduce(CGFloat(0)) { $0 + hs[$1] }
        hs[lastIndex] = max(0, h - below)
        if below > h { let k = h / below; for i in hs.indices where i != lastIndex { hs[i] *= k } }
        return hs
    }

    static func drawBars(_ m: ActivityCardModel, mode: ActivityMode, rect: CGRect, theme: Theme, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        let s = rect.width / chartVB.width
        ctx.scaleBy(x: s, y: s)
        let W = chartVB.width, H = chartVB.height, R: CGFloat = 30, ch = H - 18
        let n = max(m.bars.count, 1)
        let cw = (W - R) / CGFloat(n)
        let values = m.bars.map { Double(mode.includesCachedReads ? $0.tokens.total : $0.tokens.fresh) }
        let maxV = niceMax(values.max() ?? 0)
        func Y(_ v: Double) -> CGFloat { ch - CGFloat(v / maxV) * (ch - 10) }
        let tone = theme.providerTone(m.provider)
        let labelColor = theme.chartLabel

        for g in [maxV, maxV / 2, 0] {
            let y = Y(g)
            let line = CGMutablePath(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: W - R + 2, y: y))
            ctx.stroke(line, g > 0 ? theme.chartGrid : theme.chartBaseline, width: 1)
            Text(g > 0 ? NumberFormat.tokens(Int64(g)) : "0", F.sf(9.5, 550, tabular: true), labelColor).draw(x: W, baseline: y + 3.5, align: .right, in: ctx)
        }

        let sel = m.selection.clamped(to: 0..<n)
        let sx = CGFloat(sel.lowerBound) * cw, sw = CGFloat(sel.count) * cw
        let lens = rounded(CGRect(x: sx, y: 2, width: sw, height: ch - 2), 8)
        if m.isSubRange {
            ctx.fill(lens, tone.fade(theme.isDark ? 0.10 : 0.08))
            ctx.stroke(lens, tone.fade(0.5), width: 0.8)
        }

        for (i, bar) in m.bars.enumerated() {
            let v = values[i]
            guard v > 0 else { continue }
            let inset = min(2.2, cw * 0.18)
            let x = CGFloat(i) * cw + inset, bw = cw - 2 * inset
            let y = Y(v), h = ch - y
            // Bottom up: output, then new input, then cached reads (or cache writes) on top.
            let parts = Array(TokenPart.parts(bar.tokens, mode: mode).reversed())
            let hs = stack(parts.map { Double($0.tokens) }, height: h)
            ctx.withState {
                ctx.setAlpha(sel.contains(i) ? 1 : 0.42)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.addPath(roundedTop(CGRect(x: x, y: y, width: bw, height: h), min(2.5, bw / 2))); ctx.clip()
                var top = ch
                for (j, part) in parts.enumerated() where hs[j] > 0 {
                    top -= hs[j]
                    ctx.fill(CGPath(rect: CGRect(x: x, y: top, width: bw, height: hs[j]), transform: nil), color(part.kind, m.provider, theme))
                }
                ctx.endTransparencyLayer()
            }
        }

        // Lens handles.
        for gx in [sx, sx + sw] {
            let handle = rounded(CGRect(x: gx - 2.5, y: ch / 2 - 11, width: 5, height: 22), 2.5)
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: black(0.18).cgColor)
                ctx.fill(handle, theme.isDark ? rgb(0xF4F4F6) : .white)
            }
            ctx.stroke(handle, m.isSubRange ? tone : theme.chartDash, width: 1)
            let l = CGMutablePath(); l.move(to: CGPoint(x: gx, y: ch / 2 - 5)); l.addLine(to: CGPoint(x: gx, y: ch / 2 + 5))
            ctx.stroke(l, (m.isSubRange ? tone : theme.chartDash).fade(0.6), width: 1)
        }

        for label in m.axisLabels {
            Text(label.text, F.sf(9.5, 550), labelColor).draw(x: CGFloat(label.index) * cw + 1, baseline: H - 3, in: ctx)
        }
        ctx.restoreGState()
    }
}
