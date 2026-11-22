import AppKit
import HeadroomKit
import HeadroomPresent

/// Past weeks (redesign §5): each renewal week as a little level meter of 8 cells, lit for the
/// share used, in the provider's tone. A week that ran out is rose; this week is dimmer with a
/// dashed outline, and its projection is outlined above it.
@MainActor
enum PastWeeksRenderer {
    static let sectionHeaderHeight: CGFloat = 30
    static let cells = 8

    static func drawSectionHeader(x: CGFloat, y: CGFloat, width: CGFloat, theme: Theme, ctx: CGContext) {
        let mid = y + 14
        Text("Past weeks", F.sf(15, 650), theme.ink, kern: -0.15).draw(x: x + 3, capCenter: mid, in: ctx)
        Text("used by each renewal", F.sf(11.5, 500), theme.muted).draw(x: x + width - 3, capCenter: mid, align: .right, in: ctx)
    }

    /// Lit cells for a share used: rounded, at least one for any real use, all of them when it ran out.
    static func litCells(used: Double, ranOut: Bool, cells n: Int = cells) -> Int {
        if ranOut { return n }
        let u = min(max(used, 0), 1)
        return min(n, max(Int((u * Double(n)).rounded()), u >= 0.03 ? 1 : 0))
    }

    static func chipColor(_ dot: PastWeeksModel.ChipDot, theme: Theme) -> NSColor {
        switch dot {
        case .rose: theme.rose
        case .azure: theme.azure
        case .spark: rgb(0x8CC2FF)
        case .amber: theme.amber
        case .muted: theme.ink.fade(0.4)
        }
    }

    @discardableResult
    static func draw(_ m: PastWeeksModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let h: CGFloat = m.collecting ? 13 + 20 + 12 + 40 + 12 : 13 + 20 + 12 + 84 + 6 + 12 + 12
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: m.provider, theme: theme, ctx: ctx)
        let x0 = origin.x + 14, w = width - 28
        var y = origin.y + 13
        BrandMark.drawTile(m.provider, in: CGRect(x: x0, y: y, width: 20, height: 20), theme: theme, ctx: ctx)
        let name = Text(m.provider.displayName, F.sf(14, 650), theme.ink, kern: -0.07)
        name.draw(x: x0 + 20 + 8, capCenter: y + 10, in: ctx)
        // Chips, right-aligned; the leftmost ones give way when they don't fit beside the name.
        var cx = x0 + w
        let minX = x0 + 20 + 8 + name.width + 10
        for chip in m.chips.reversed() {
            let t = Text(chip.text, F.sf(10.5, 600, tabular: true), theme.ink)
            let cw = 7 + 5 + 5 + t.width + 7
            guard cx - cw >= minX else { break }
            let r = CGRect(x: cx - cw, y: y + 10 - 9, width: cw, height: 18)
            ctx.fill(rounded(r, 7), theme.chipFill)
            let dot = CGRect(x: r.minX + 7, y: r.midY - 2.5, width: 5, height: 5)
            if chip.color == .spark {
                Glyph.spark(in: dot.insetBy(dx: -1.5, dy: -1.5), color: chipColor(.spark, theme: theme), ctx: ctx)
            } else {
                let p = CGMutablePath(); p.addEllipse(in: dot); ctx.fill(p, chipColor(chip.color, theme: theme))
            }
            t.draw(x: dot.maxX + 5, capCenter: r.midY, in: ctx)
            cx = r.minX - 5
        }
        y += 20 + 12

        if m.collecting {
            let r = CGRect(x: x0, y: y, width: w, height: 40)
            ctx.fill(rounded(r, 10), theme.tileFill)
            Glyph.hourglass(in: CGRect(x: r.minX + 12, y: r.midY - 7, width: 9.8, height: 14), color: theme.muted, ctx: ctx)
            Text("Collecting history", F.sf(12.5, 600), theme.ink).draw(x: r.minX + 32, baseline: r.minY + 17, in: ctx)
            Text("Past weeks fill in from install. Two renewals needed.", F.sf(11, 400), theme.muted).draw(x: r.minX + 32, baseline: r.minY + 31, in: ctx)
            return h
        }

        let n = max(m.weeks.count, 1)
        let dividers = m.planChange == nil ? 0 : 1
        let gap: CGFloat = 10
        let colW = (w - gap * CGFloat(n - 1 + dividers) - CGFloat(dividers)) / CGFloat(n)
        let colsTop = y, colTop = y + 20, colH: CGFloat = 64
        let cellGap: CGFloat = 2
        let cellH = (colH - cellGap * CGFloat(cells - 1)) / CGFloat(cells)
        let unlit = theme.ink.fade(0.06)
        var x = x0
        var centers: [CGFloat] = []
        for (i, week) in m.weeks.enumerated() {
            let r = CGRect(x: x, y: colTop, width: colW, height: colH)
            let ranOut = week.used >= 1 || week.ranOutHoursEarly != nil
            let lit = litCells(used: week.used, ranOut: ranOut)
            let projected = week.isCurrent ? max(lit, litCells(used: week.projected ?? week.used, ranOut: false)) : lit
            let litColor = ranOut ? theme.rose : theme.providerTone(m.provider, CGFloat(week.isCurrent ? ProviderTone.pastWeekCurrent : ProviderTone.pastWeek))
            for c in 0..<cells {
                let cell = CGRect(x: r.minX, y: r.maxY - CGFloat(c + 1) * cellH - CGFloat(c) * cellGap, width: r.width, height: cellH)
                let shape = rounded(cell, 2)
                if c < lit {
                    ctx.fill(shape, litColor)
                    if week.isCurrent { ctx.stroke(rounded(cell.insetBy(dx: 0.4, dy: 0.4), 1.8), theme.ink.fade(0.6), width: 0.8, dash: [2, 1.5]) }
                } else if c < projected {
                    ctx.fill(shape, unlit)
                    ctx.stroke(rounded(cell.insetBy(dx: 0.4, dy: 0.4), 1.8), theme.ink.fade(0.32), width: 0.8, dash: [2, 1.5])
                } else {
                    ctx.fill(shape, unlit)
                }
            }
            if week.isCurrent {
                Text("NOW", F.sf(9, 700), theme.muted, kern: 0.54).draw(x: r.midX + 0.27, baseline: colTop - 7, align: .center, in: ctx)
            } else if let early = week.ranOutHoursEarly {
                Text("−\(early)H", F.sf(9, 750), theme.rose, kern: 0.54).draw(x: r.midX + 0.27, baseline: colTop - 7, align: .center, in: ctx)
            }
            out?.add(CGRect(x: r.minX, y: colsTop, width: r.width, height: 84 + 18), tooltip: week.caption, action: .openWeek(m.provider, i))
            centers.append(r.midX)
            x += colW + gap
            if let change = m.planChange, change.after == i {
                let lx = x - gap / 2 - 0.5 + 2
                ctx.fillLinear(CGPath(rect: CGRect(x: lx - 3, y: colsTop, width: 1, height: 84), transform: nil),
                               [theme.isDark ? white(0.4) : black(0.3), theme.isDark ? white(0.05) : black(0.03)],
                               from: CGPoint(x: lx, y: colsTop), to: CGPoint(x: lx, y: colsTop + 84))
                Text(change.pill, F.sf(8.5, 700), theme.ink.fade(0.6), kern: 0.68).draw(x: lx + 2, baseline: colsTop + 7, in: ctx)
                x += 1
            }
        }

        // Markers under each week: ‖ 5-hour hits, ✦ early resets.
        let my = colTop + colH + 6 + 6
        for (i, week) in m.weeks.enumerated() {
            var parts: [(CGFloat, (CGFloat) -> Void)] = []
            if week.sessionHits > 0 {
                let count = week.sessionHits > 1 ? Text("\(week.sessionHits)", F.sf(9, 650), theme.muted) : nil
                parts.append((6.8 + (count.map { $0.width + 2 } ?? 0), { px in
                    Glyph.pause(in: CGRect(x: px, y: my - 4, width: 6.8, height: 8), color: theme.muted, ctx: ctx)
                    count?.draw(x: px + 6.8 + 2, capCenter: my, in: ctx)
                }))
            }
            if week.earlyResets > 0 {
                parts.append((9, { px in Glyph.spark(in: CGRect(x: px, y: my - 4.5, width: 9, height: 9), color: rgb(0x8CC2FF), ctx: ctx) }))
            }
            let total = parts.reduce(0) { $0 + $1.0 } + CGFloat(max(parts.count - 1, 0)) * 2
            var px = centers[i] - total / 2
            for part in parts { part.1(px); px += part.0 + 2 }
        }
        return h
    }

    static let legendHeight: CGFloat = 48

    static func drawLegend(x: CGFloat, y: CGFloat, width: CGFloat, theme: Theme, ctx: CGContext) {
        let color = theme.isDark ? rgb(0xF4F4F6, 0.48) : rgb(0x1C1C1E, 0.5)
        let font = F.sf(11, 500)
        var cx = x + 3, cy = y + 14 + 7
        func item(_ iconW: CGFloat, _ label: String, _ icon: (CGFloat, CGFloat) -> Void) {
            let t = Text(label, font, color)
            if cx + iconW + 5 + t.width > x + width - 3 { cx = x + 3; cy += 18 }
            icon(cx, cy)
            t.draw(x: cx + iconW + 5, capCenter: cy, in: ctx)
            cx += iconW + 5 + t.width + 12
        }
        item(6.8, "hit 5-hour limit") { px, py in Glyph.pause(in: CGRect(x: px, y: py - 4, width: 6.8, height: 8), color: color, ctx: ctx) }
        item(9, "early reset") { px, py in Glyph.spark(in: CGRect(x: px, y: py - 4.5, width: 9, height: 9), color: rgb(0x8CC2FF), ctx: ctx) }
        item(12, "ran out (hours early)") { px, py in
            ctx.fill(rounded(CGRect(x: px, y: py - 3, width: 12, height: 6), 2), theme.rose)
        }
        item(12, "projected") { px, py in
            ctx.stroke(rounded(CGRect(x: px + 0.4, y: py - 2.6, width: 11.2, height: 5.2), 1.8), theme.ink.fade(0.4), width: 0.8, dash: [2, 1.5])
        }
    }
}
