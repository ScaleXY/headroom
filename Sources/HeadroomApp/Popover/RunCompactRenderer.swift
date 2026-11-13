import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab's compact view: every run on one line, in the grammar of Activity's recent runs.
/// A live run shows its provider tile with a state dot, the title, a small task meter, the
/// percent (or agents finished) and the time left or spent; one that needs you is washed rose.
/// A finished run shows its outcome, the title, how long it took and what it cost. Clicking a
/// line opens that run's full card in its place.
@MainActor
enum RunCompactRenderer {
    static let rowHeight: CGFloat = 40
    static let listPad: CGFloat = 5
    static let meterWidth: CGFloat = 42
    static let figureWidth: CGFloat = 36
    static let sideWidth: CGFloat = 48

    /// Live runs, then the last day's finished ones under their own header. `open` holds the runs
    /// shown as full cards. Returns the height.
    @discardableResult
    static func drawPage(_ page: RunsPageModel, open: Set<String>, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?,
                         out: RenderOutput? = nil) -> CGFloat {
        if page.isEmpty { return RunCardRenderer.drawEmpty(origin: origin, width: width, theme: t, ctx: ctx, out: out) }
        var y = origin.y
        y += drawSection(page.live, open: open, origin: CGPoint(x: origin.x, y: y), width: width, theme: t, ctx: ctx, out: out)
        if !page.recent.isEmpty {
            if !page.live.isEmpty { y += 16 }
            let mid = y + 14
            if let ctx { Text(RunsPageModel.recentTitle, F.sf(15, 650), t.ink, kern: -0.15).draw(x: origin.x + 3, capCenter: mid, in: ctx) }
            let link = page.moreRecent > 0 ? "+ \(page.moreRecent) more" : page.allRecent ? "Show fewer" : nil
            if let link {
                let l = Text(link, F.sf(11.5, 550), t.muted)
                if let ctx { l.draw(x: origin.x + width - 3, capCenter: mid, align: .right, in: ctx) }
                out?.add(CGRect(x: origin.x + width - 3 - l.width - 8, y: mid - 11, width: l.width + 16, height: 22), action: .moreRecent)
            }
            y += RunCardRenderer.sectionHeaderHeight
            y += drawSection(page.recent, open: open, origin: CGPoint(x: origin.x, y: y), width: width, theme: t, ctx: ctx, out: out)
        }
        return y - origin.y
    }

    /// Consecutive closed runs share one list card; an open run breaks the list with its full card.
    static func drawSection(_ cards: [RunCardModel], open: Set<String>, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?,
                            out: RenderOutput?) -> CGFloat {
        var y = origin.y
        var run: [RunCardModel] = []
        var first = true
        func flush() {
            guard !run.isEmpty else { return }
            if !first { y += 8 }
            y += drawList(run, origin: CGPoint(x: origin.x, y: y), width: width, theme: t, ctx: ctx, out: out)
            run = []
            first = false
        }
        for card in cards {
            if open.contains(card.id) {
                flush()
                if !first { y += 8 }
                let h = RunCardRenderer.draw(card, origin: CGPoint(x: origin.x, y: y), width: width, theme: t, ctx: ctx, out: out)
                // The card's header closes it again.
                out?.add(CGRect(x: origin.x, y: y, width: width - RunCardRenderer.menuWidth - 22, height: 44), tooltip: "Back to one line",
                         action: .openCompact(card.id))
                y += h
                first = false
            } else {
                run.append(card)
            }
        }
        flush()
        return y - origin.y
    }

    /// One list card of runs, a line each. Returns its height.
    static func drawList(_ cards: [RunCardModel], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let h = listPad * 2 + CGFloat(cards.count) * rowHeight
        let x0 = origin.x + 12, w = width - 24
        var y = origin.y + listPad
        if let ctx { CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: nil, theme: t, ctx: ctx) }
        for (i, card) in cards.enumerated() {
            let row = CGRect(x: x0, y: y, width: w, height: rowHeight)
            if let ctx {
                if i > 0, !card.needsInput, !cards[i - 1].needsInput {
                    ctx.fill(CGPath(rect: CGRect(x: x0 + 30, y: y, width: w - 30, height: 0.5), transform: nil), t.separator)
                }
                if card.live { drawLive(card, row: row, theme: t, ctx: ctx) } else { drawFinished(card, row: row, theme: t, ctx: ctx) }
            }
            out?.add(CGRect(x: origin.x, y: y, width: width, height: rowHeight), tooltip: tooltip(card), action: .openCompact(card.id))
            y += rowHeight
        }
        return h
    }

    // MARK: Rows

    /// Tile and state dot · title · meter · figure · time.
    static func drawLive(_ c: RunCardModel, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let mid = r.midY
        let tone = RunCardRenderer.color(c.tone, t, glyph: c.glyph)
        if c.needsInput {
            // Washed rose, edge to edge of the line, as the question panel is.
            let wash = rounded(r.insetBy(dx: -6, dy: 2), 10)
            ctx.fill(wash, t.rose.fade(t.isDark ? 0.12 : 0.08))
            ctx.innerStroke(wash, t.rose.fade(t.isDark ? 0.28 : 0.22), width: 0.5)
        }
        drawTile(c, center: CGPoint(x: r.minX + 10, y: mid), tone: tone, theme: t, ctx: ctx)

        // Right to left: the time (or, when something's wrong, what), the figure, the meter.
        var right = r.maxX
        if let flag = c.compactFlag {
            Text(flag, F.sf(11.5, 650), tone).draw(x: right, capCenter: mid, align: .right, in: ctx)
        } else if let hero = c.hero, let side = hero.side {
            let s = Text(side, F.sf(11.5, 550, tabular: true), hero.hourglass ? t.muted : t.muted2)
            s.draw(x: right, capCenter: mid, align: .right, in: ctx)
            if hero.hourglass {
                Glyph.hourglass(in: CGRect(x: right - s.width - 4 - 6.3, y: mid - 4.5, width: 6.3, height: 9), color: t.pacing(.plenty).text.fade(0.85), ctx: ctx)
            }
        }
        right -= sideWidth + 6
        let figureColor: NSColor = c.tone == .alert || c.tone == .warn ? tone : t.ink
        var figure: CGFloat = figureWidth
        if let hero = c.hero {
            let n = Text(hero.number, F.sf(13.5, 700, tabular: true), figureColor, kern: -0.2)
            let u = Text(hero.unit, F.sf(hero.unit == "%" ? 10.5 : 10, 650, tabular: true), figureColor.fade(0.7))
            n.draw(x: right - u.width - 1, capCenter: mid, align: .right, in: ctx)
            u.draw(x: right, capCenter: mid, align: .right, in: ctx)
            // At least the column's width so figures line up; wider when a count needs it.
            figure = max(figureWidth, n.width + u.width + 1)
        }
        right -= figure + 8
        let meter = CGRect(x: right - meterWidth, y: mid - 5, width: meterWidth, height: 10)
        drawMiniMeter(c, rect: meter, theme: t, ctx: ctx)
        right = meter.minX - 8

        let tx = r.minX + 30
        RunCardRenderer.fit(c.title, F.sf(12.5, 600), t.ink, width: right - tx, kern: -0.05).draw(x: tx, capCenter: mid, in: ctx)
    }

    /// Outcome · title · how long · what it cost.
    static func drawFinished(_ c: RunCardModel, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let mid = r.midY
        let tone = RunCardRenderer.color(c.tone, t, glyph: c.glyph)
        let disc = CGRect(x: r.minX + 2, y: mid - 8, width: 16, height: 16)
        ctx.fill(CGPath(ellipseIn: disc, transform: nil), tone.fade(c.tone == .neutral || c.tone == .quiet ? 0.08 : 0.14))
        RunCardRenderer.drawGlyph(c.glyph, color: c.glyph == .done ? t.ink.fade(0.7) : tone, center: CGPoint(x: disc.midX, y: disc.midY), size: 9, ctx: ctx)
        var right = r.maxX
        let cost = c.receipt?.cost.map { Text($0.replacingOccurrences(of: "about ", with: "~"), F.sf(12, 650, tabular: true), t.ink) }
        if let cost { cost.draw(x: right, capCenter: mid, align: .right, in: ctx); right -= max(cost.width, 44) + 10 }
        let took = c.receipt?.duration ?? c.hero?.side
        if let took {
            let d = Text(took, F.sf(11.5, 550, tabular: true), t.muted)
            d.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= max(d.width, sideWidth) + 10
        }
        if let tasks = c.receipt?.tasks {
            let k = Text(tasks, F.sf(11.5, 550, tabular: true), t.muted2)
            k.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= k.width + 12
        }
        let tx = r.minX + 30
        RunCardRenderer.fit(c.title, F.sf(12.5, 600), t.ink.fade(0.88), width: right - tx, kern: -0.05).draw(x: tx, capCenter: mid, in: ctx)
    }

    // MARK: Pieces

    /// The provider's tile with the state as a dot on its corner, as an app badge sits.
    static func drawTile(_ c: RunCardModel, center: CGPoint, tone: NSColor, theme t: Theme, ctx: CGContext) {
        let rect = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
        if let p = c.provider {
            BrandMark.drawTile(p, in: rect, ctx: ctx)
        } else {
            ctx.fill(rounded(rect, 5.5), t.chipFill)
            RunCardRenderer.drawGlyph(c.glyph, color: tone, center: center, size: 10, ctx: ctx)
            return
        }
        let dot = CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 9, height: 9)
        ctx.fill(CGPath(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5), transform: nil), t.cardSolid)
        ctx.withState {
            if c.tone != .quiet && c.tone != .neutral { ctx.setShadow(offset: .zero, blur: 5, color: tone.fade(0.8).cgColor) }
            ctx.fill(CGPath(ellipseIn: dot, transform: nil), tone)
        }
    }

    /// The task map at line height: the meter's recessed track, a cell per task (lit, part-lit or
    /// empty in the map's colours); five cells when there's no map.
    static func drawMiniMeter(_ c: RunCardModel, rect: CGRect, theme t: Theme, ctx: CGContext) {
        let track = rounded(rect, rect.height / 2)
        ctx.fill(track, t.meterTrack)
        if t.isDark { ctx.innerStroke(track, t.meterTrackBorder, width: 0.5) }
        let inner = rect.insetBy(dx: 2, dy: 2)
        let cells: [(weight: Double, fill: Double, tone: RunTone, failed: Bool)]
        if !c.segments.isEmpty {
            cells = c.segments.map { ($0.weight, $0.fill, $0.tone, $0.failed) }
        } else {
            let f = min(max(c.hero?.fraction ?? 0, 0), 1)
            cells = (0..<5).map { i in (0.2, min(max(f * 5 - Double(i), 0), 1), c.tone == .warn ? .warn : .progress, false) }
        }
        let n = cells.count
        let gap: CGFloat = n > 12 ? 1 : 1.5, minW: CGFloat = 1.5
        let avail = inner.width - gap * CGFloat(n - 1)
        let spare = max(0, avail - minW * CGFloat(n))
        let total = max(cells.reduce(0) { $0 + $1.weight }, 1e-9)
        var x = inner.minX
        for (i, cell) in cells.enumerated() {
            let bw = avail > minW * CGFloat(n) ? minW + CGFloat(cell.weight / total) * spare : avail / CGFloat(n)
            let b = CGRect(x: x, y: inner.minY, width: bw, height: inner.height)
            let shape = rounded(b, left: i == 0 ? inner.height / 2 : 1, right: i == n - 1 ? inner.height / 2 : 1)
            ctx.fill(shape, t.meterEmpty)
            let colors: PacingColors = switch cell.tone {
            case .alert: t.pacing(.veryTight)
            case .warn: t.pacing(.tight)
            default: t.pacing(.plenty)
            }
            if cell.failed {
                ctx.fill(shape, RunCardRenderer.failure(t).fade(0.7))
            } else if cell.fill > 0, cell.tone != .quiet {
                ctx.withState {
                    ctx.addPath(shape); ctx.clip()
                    if cell.fill < 1 { ctx.fill(CGPath(rect: b, transform: nil), colors.bottom.fade(t.isDark ? 0.24 : 0.18)) }
                    ctx.fillVertical(CGPath(rect: CGRect(x: b.minX, y: b.minY, width: max(b.width * CGFloat(cell.fill), 1.5), height: b.height), transform: nil),
                                     colors.top, colors.bottom)
                }
            }
            x += bw + gap
        }
    }

    /// What the line leaves out, on hover.
    static func tooltip(_ c: RunCardModel) -> String {
        var parts = [c.title, c.stateText]
        if let label = c.hero?.label { parts.append(label) }
        if let caption = c.hero?.sideCaption, c.live { parts.append(caption) }
        parts.append(c.subtitle)
        return parts.joined(separator: " · ")
    }
}
