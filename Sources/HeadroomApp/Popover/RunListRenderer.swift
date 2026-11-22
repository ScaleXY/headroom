import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab's list, in the style Settings picks (Ledger, Two-line, Fill rows). Every line
/// opens the run's own page (`.openRun`). Runs that need you come first under their own header,
/// then the other live runs, then the last day's finished ones.
@MainActor
enum RunListRenderer {
    /// Live runs (what needs you first), then the last day's finished ones. `showFinished` opens
    /// Two-line's folded finished line. Returns the height; the measuring pass (`ctx == nil`)
    /// returns the same height as the drawing one.
    @discardableResult
    static func drawPage(_ page: RunsPageModel, style: RunsListStyle, showFinished: Bool = false, origin: CGPoint, width: CGFloat, theme t: Theme,
                         ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        if page.isEmpty { return RunCardRenderer.drawEmpty(origin: origin, width: width, theme: t, ctx: ctx, out: out) }
        let asking = page.live.filter(\.needsInput), others = page.live.filter { !$0.needsInput }
        var y = origin.y
        var first = true
        func section(_ label: String, color: NSColor, right: (String, HitRegion.Action)? = nil, _ body: (CGFloat) -> CGFloat) {
            y += header(label, color: color, right: right, x: origin.x, y: y, width: width, top: first, theme: t, ctx: ctx, out: out)
            y += body(y)
            first = false
        }
        func live(_ cards: [RunCardModel], _ top: CGFloat) -> CGFloat {
            let o = CGPoint(x: origin.x, y: top)
            switch style {
            case .ledger: return drawLedger(cards, origin: o, width: width, theme: t, ctx: ctx, out: out)
            case .twoLine: return drawTwoLine(cards, origin: o, width: width, theme: t, ctx: ctx, out: out)
            case .fill: return drawFill(cards, origin: o, width: width, theme: t, ctx: ctx, out: out)
            }
        }
        if !asking.isEmpty { section("NEEDS YOU · \(asking.count)", color: t.rose) { live(asking, $0) } }
        if !others.isEmpty { section("LIVE · \(others.count)", color: t.muted2) { live(others, $0) } }
        if !page.recent.isEmpty {
            let link: (String, HitRegion.Action)? = page.moreRecent > 0 ? ("+ \(page.moreRecent) more", .moreRecent)
                : page.allRecent ? ("Show fewer", .moreRecent) : nil
            section("FINISHED TODAY · \(page.recent.count + page.moreRecent)", color: t.muted2, right: link) { top in
                let o = CGPoint(x: origin.x, y: top)
                switch style {
                case .ledger: return drawLedger(page.recent, origin: o, width: width, theme: t, ctx: ctx, out: out)
                case .twoLine: return drawFolded(page.recent, open: showFinished, origin: o, width: width, theme: t, ctx: ctx, out: out)
                case .fill: return drawTally(page.recent, origin: o, width: width, theme: t, ctx: ctx, out: out)
                }
            }
        }
        return y - origin.y
    }

    // MARK: Sections

    static let headerHeight: CGFloat = 32
    static let groupPad: CGFloat = 4
    static let chevronW: CGFloat = 8

    /// "NEEDS YOU · 1" in the charts' caps, and a link on the right. Returns its height.
    static func header(_ label: String, color: NSColor, right: (String, HitRegion.Action)?, x: CGFloat, y: CGFloat, width: CGFloat, top: Bool,
                       theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let h: CGFloat = top ? 22 : headerHeight
        let mid = y + h - 11
        if let ctx { Text(label, F.sf(9.5, 700, tabular: true), color, kern: 0.95).draw(x: x + 6, capCenter: mid, in: ctx) }
        if let (text, action) = right {
            let l = Text(text, F.sf(11.5, 550), t.muted)
            if let ctx { l.draw(x: x + width - 6, capCenter: mid, align: .right, in: ctx) }
            out?.add(CGRect(x: x + width - 6 - l.width - 7, y: mid - 10, width: l.width + 14, height: 20), action: action, hover: 7)
        }
        return h
    }

    /// The colour a run's state reads in.
    static func tone(_ c: RunCardModel, _ t: Theme) -> NSColor { RunCardRenderer.color(c.tone, t, glyph: c.glyph) }

    /// A settled state (done, abandoned) draws quietly.
    static func settled(_ c: RunCardModel) -> Bool { c.tone == .neutral || c.tone == .quiet }

    /// One list card holding lines of the given heights. Returns their rects and the card's height.
    static func group(rows: [CGFloat], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?) -> (rects: [CGRect], height: CGFloat) {
        let h = groupPad * 2 + rows.reduce(0, +)
        if let ctx { CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: nil, theme: t, ctx: ctx) }
        var y = origin.y + groupPad
        var rects: [CGRect] = []
        for rh in rows {
            rects.append(CGRect(x: origin.x + groupPad, y: y, width: width - groupPad * 2, height: rh))
            y += rh
        }
        return (rects, h)
    }

    /// The hairline between two lines, from `inset` to near the line's end.
    static func separator(_ r: CGRect, inset: CGFloat, theme t: Theme, ctx: CGContext) {
        ctx.fill(CGPath(rect: CGRect(x: r.minX + inset, y: r.minY, width: r.width - inset - 8, height: 0.5), transform: nil), t.separator)
    }

    /// The "›" that says a line opens.
    static func drawOpens(_ r: CGRect, mid: CGFloat, theme t: Theme, ctx: CGContext) {
        RunCardRenderer.drawDisclosure(open: false, center: CGPoint(x: r.maxX - 12, y: mid), color: t.muted2, ctx: ctx)
    }

    /// A run's name. One synced from another Mac carries a small computer after it, unless the name
    /// already says where it is ("Run on Mac Studio"): its tooltip and its page name the Mac.
    static func drawTitle(_ c: RunCardModel, _ font: NSFont, _ color: NSColor, x: CGFloat, capCenter: CGFloat, width: CGFloat, theme t: Theme,
                          ctx: CGContext) {
        let marked = c.mac.map { !c.title.contains($0) } ?? false
        let name = RunCardRenderer.fit(c.title, font, color, width: width - (marked ? 20 : 0), kern: -0.05)
        name.draw(x: x, capCenter: capCenter, in: ctx)
        if marked {
            CanvasControlView.drawSymbol("desktopcomputer", in: CGRect(x: x + name.width + 6, y: capCenter - 5.5, width: 14, height: 11),
                                         color: t.muted, weight: .medium, ctx: ctx)
        }
    }

    // MARK: Ledger

    static let ledgerRow: CGFloat = 36
    static let meterW: CGFloat = 30, figureW: CGFloat = 34, timeW: CGFloat = 62

    /// One line per run in columns: state · name · meter · figure · time · ›. Finished runs: state ·
    /// name · n of m · took · cost · ›. Returns the height.
    static func drawLedger(_ cards: [RunCardModel], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let g = group(rows: cards.map { _ in ledgerRow }, origin: origin, width: width, theme: t, ctx: ctx)
        for (i, (c, r)) in zip(cards, g.rects).enumerated() {
            if let ctx {
                if i > 0 { separator(r, inset: 34, theme: t, ctx: ctx) }
                if c.live { drawLedgerLive(c, row: r, theme: t, ctx: ctx) } else { drawLedgerFinished(c, row: r, theme: t, ctx: ctx) }
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 10)
        }
        return g.height
    }

    static func drawLedgerLive(_ c: RunCardModel, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let mid = r.midY
        drawStateIcon(c, center: CGPoint(x: r.minX + 17, y: mid), theme: t, ctx: ctx)
        drawOpens(r, mid: mid, theme: t, ctx: ctx)
        var right = r.maxX - 10 - chevronW - 8
        drawTime(c, right: right, mid: mid, theme: t, ctx: ctx)
        right -= timeW + 6
        // The column's width so figures line up; wider when a big count needs it.
        right -= max(figureW, drawFigure(c, right: right, mid: mid, size: 13, theme: t, ctx: ctx)) + 8
        let meter = CGRect(x: right - meterW, y: mid - 4, width: meterW, height: 8)
        drawMiniMeter(c, rect: meter, theme: t, ctx: ctx)
        right = meter.minX - 10
        let tx = r.minX + 34
        drawTitle(c, F.sf(13, 600), t.ink, x: tx, capCenter: mid, width: right - tx, theme: t, ctx: ctx)
    }

    static func drawLedgerFinished(_ c: RunCardModel, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let mid = r.midY
        drawStateIcon(c, center: CGPoint(x: r.minX + 17, y: mid), theme: t, ctx: ctx)
        drawOpens(r, mid: mid, theme: t, ctx: ctx)
        var right = r.maxX - 10 - chevronW - 8
        // Columns line up whether or not a run is priced; a cost past $99 takes the room it needs.
        var costW: CGFloat = 0
        if let cost = c.receipt?.cost.map({ $0.replacingOccurrences(of: "about ", with: "~") }) {
            let k = Text(cost, F.sf(12, 600, tabular: true), t.ink.fade(0.85))
            k.draw(x: right, capCenter: mid, align: .right, in: ctx)
            costW = k.width
        }
        right -= max(44, costW) + 10
        if let took = c.receipt?.duration ?? c.hero?.side {
            let d = Text(took, F.sf(11.5, 550, tabular: true), t.muted)
            d.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= max(d.width, 44) + 10
        }
        if let tasks = c.receipt?.tasks {
            let k = Text(tasks, F.sf(11.5, 550, tabular: true), t.muted2)
            k.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= k.width + 12
        }
        let tx = r.minX + 34
        drawTitle(c, F.sf(13, 550), t.ink.fade(0.85), x: tx, capCenter: mid, width: right - tx, theme: t, ctx: ctx)
    }

    /// The time column: what needs you or holds the run up when something does, else the time
    /// left (or spent).
    static func drawTime(_ c: RunCardModel, right: CGFloat, mid: CGFloat, theme t: Theme, ctx: CGContext) {
        guard let w = stateWord(c, theme: t) else { return }
        w.text.draw(x: right, capCenter: mid, align: .right, in: ctx)
        if w.pause { Glyph.pause(in: CGRect(x: right - w.text.width - 4 - 7, y: mid - 4.5, width: 7, height: 9), color: t.amber, ctx: ctx) }
    }

    /// "asks" in rose, "quiet 18m" or the pause's clock in amber, "stopped", else the time left or spent.
    static func stateWord(_ c: RunCardModel, theme t: Theme) -> (text: Text, pause: Bool)? {
        let font = F.sf(11.5, 650, tabular: true)
        if c.needsInput { return (Text("asks", font, t.rose), false) }
        if c.glyph == .stale { return (Text(c.page?.status.key.lowercased() ?? "quiet", font, t.amber), false) }
        if let limit = c.page?.limit { return (Text(shortClock(limit.pause), font, t.amber), true) }
        if let flag = c.compactFlag { return (Text(flag, font, flag == "waiting" ? t.muted : tone(c, t)), false) }
        if let side = c.hero?.side {
            return (Text(side, F.sf(11.5, 550, tabular: true), c.hero?.hourglass == true ? t.ink.fade(0.75) : t.muted), false)
        }
        return nil
    }

    /// "62%" or "7/9", right-aligned, in the state's colour when something's wrong.
    @discardableResult
    static func drawFigure(_ c: RunCardModel, right: CGFloat, mid: CGFloat, size: CGFloat, theme t: Theme, ctx: CGContext) -> CGFloat {
        guard let hero = c.hero else { return 0 }
        let color: NSColor = c.tone == .alert || c.tone == .warn ? tone(c, t) : t.ink
        let n = Text(hero.number, F.sf(size, 700, tabular: true), color, kern: -0.2)
        let u = Text(hero.unit, F.sf((size * 0.76).rounded(), 650, tabular: true), color.fade(0.7))
        n.draw(x: right - u.width - 1, capCenter: mid, align: .right, in: ctx)
        u.draw(x: right, capCenter: mid, align: .right, in: ctx)
        return n.width + u.width + 1
    }

    /// "10:30 AM" → "10:30": the column has no room for the meridiem.
    static func shortClock(_ s: String) -> String { s.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") }

    // MARK: Two-line

    static let twoLineRow: CGFloat = 54

    /// The name and figure, then the state's key and what's happening, over a hairline of progress.
    static func drawTwoLine(_ cards: [RunCardModel], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let g = group(rows: cards.map { _ in twoLineRow }, origin: origin, width: width, theme: t, ctx: ctx)
        for (i, (c, r)) in zip(cards, g.rects).enumerated() {
            if let ctx {
                if i > 0 { separator(r, inset: 40, theme: t, ctx: ctx) }
                drawTwoLineRow(c, row: r, theme: t, ctx: ctx)
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 11)
        }
        return g.height
    }

    static func drawTwoLineRow(_ c: RunCardModel, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let tc = tone(c, t)
        let top = r.minY + 16, second = r.minY + 33
        drawTile(c, center: CGPoint(x: r.minX + 19, y: top + 1), tone: tc, theme: t, ctx: ctx)
        drawOpens(r, mid: (top + second) / 2, theme: t, ctx: ctx)
        let right = r.maxX - 10 - chevronW - 8
        let figW = max(40, drawFigure(c, right: right, mid: top, size: 15, theme: t, ctx: ctx))
        let tx = r.minX + 40
        drawTitle(c, F.sf(13, 600), t.ink, x: tx, capCenter: top, width: right - figW - 8 - tx, theme: t, ctx: ctx)
        // The state's key, then what's going on.
        let key = c.needsInput ? "Asks" : c.page?.status.key ?? c.stateText
        let k = Text(key, F.sf(11.5, 650, tabular: true), settled(c) ? t.ink.fade(0.75) : tc)
        k.draw(x: tx, capCenter: second, in: ctx)
        if let line = c.page?.line, !line.isEmpty {
            RunCardRenderer.fit(line, F.sf(11.5, 500, tabular: true), t.muted, width: right - tx - k.width - 7)
                .draw(x: tx + k.width + 7, capCenter: second, in: ctx)
        }
        // The hairline of progress.
        let bar = CGRect(x: tx, y: r.maxY - 8, width: right - tx, height: 2.5)
        ctx.fill(rounded(bar, 1.25), t.meterTrack)
        let f = CGFloat(min(max(c.hero?.fraction ?? 0, 0), 1))
        if f > 0 {
            let lit = rounded(CGRect(x: bar.minX, y: bar.minY, width: max(bar.width * f, 2.5), height: bar.height), 1.25)
            let lc = settled(c) ? t.azure : tc
            ctx.withState {
                ctx.setShadow(offset: .zero, blur: 5, color: lc.fade(0.7).cgColor)
                ctx.fill(lit, lc)
            }
        }
    }

    static let foldedRow: CGFloat = 40

    /// The finished runs folded into one line that opens them, as ledger lines, under it.
    static func drawFolded(_ cards: [RunCardModel], open: Bool, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let rows = [foldedRow] + (open ? cards.map { _ in ledgerRow } : [])
        let g = group(rows: rows, origin: origin, width: width, theme: t, ctx: ctx)
        let head = g.rects[0]
        if let ctx {
            let mid = head.midY
            let disc = CGRect(x: head.minX + 8, y: mid - 9, width: 18, height: 18)
            ctx.fill(CGPath(ellipseIn: disc, transform: nil), t.ink.fade(0.08))
            RunCardRenderer.drawGlyph(.done, color: t.ink.fade(0.75), center: CGPoint(x: disc.midX, y: disc.midY), size: 10, ctx: ctx)
            let lead = Text(cards.count == 1 ? "1 run" : "\(cards.count) runs", F.sf(13, 650), t.ink)
            lead.draw(x: head.minX + 34, capCenter: mid, in: ctx)
            var tail = outcomes(cards)
            if let cost = Outcomes(cards).cost { tail.append("~" + NumberFormat.dollars(cost, style: .precise)) }
            RunCardRenderer.fit(tail.map { " · " + $0 }.joined(), F.sf(12, 500, tabular: true), t.muted, width: head.width - 34 - lead.width - 34)
                .draw(x: head.minX + 34 + lead.width, capCenter: mid, in: ctx)
            RunCardRenderer.drawChevron(up: open, center: CGPoint(x: head.maxX - 13, y: mid), color: t.muted2, ctx: ctx)
        }
        out?.add(head, tooltip: open ? "Fold the finished runs" : "Show the finished runs", action: .toggleFinished, hover: 11)
        for (c, r) in zip(cards, g.rects.dropFirst()) {
            if let ctx {
                separator(r, inset: 34, theme: t, ctx: ctx)
                drawLedgerFinished(c, row: r, theme: t, ctx: ctx)
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 10)
        }
        return g.height
    }

    /// "3 done", "1 with failures", "1 abandoned".
    static func outcomes(_ cards: [RunCardModel]) -> [String] { RunOutcomes(cards).words }

    typealias Outcomes = RunOutcomes

    // MARK: Fill rows

    static let fillRow: CGFloat = 34, fillGap: CGFloat = 4

    /// Each run a line that fills as it gets along, tinted by its state.
    static func drawFill(_ cards: [RunCardModel], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        var y = origin.y
        for (i, c) in cards.enumerated() {
            if i > 0 { y += fillGap }
            let r = CGRect(x: origin.x, y: y, width: width, height: fillRow)
            if let ctx { drawFillRow(c, row: r, theme: t, ctx: ctx) }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 10)
            // The answer button wins over the line it sits on.
            if c.needsInput, c.actions.openSession {
                out?.add(answerRect(r), tooltip: "Open the session to answer", action: .runButton(c.id, .openSession), hover: 11)
            }
            y += fillRow
        }
        return y - origin.y
    }

    static func answerRect(_ r: CGRect) -> CGRect {
        let w = Text("Answer", F.sf(11, 650), .black).width + 10 + 6 + 16
        return CGRect(x: r.maxX - 10 - chevronW - 8 - w, y: r.midY - 11, width: w, height: 22)
    }

    static func drawFillRow(_ c: RunCardModel, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let tc = settled(c) ? t.azure : tone(c, t)
        let shape = rounded(r, 10)
        ctx.fill(shape, t.isDark ? white(0.04) : white(0.75))
        let f = CGFloat(min(max(c.hero?.fraction ?? 0, 0), 1))
        if f > 0 {
            let fw = max(r.width * f, 10)
            ctx.withState {
                ctx.addPath(shape); ctx.clip()
                let fill = CGRect(x: r.minX, y: r.minY, width: fw, height: r.height)
                ctx.fillLinear(CGPath(rect: fill, transform: nil), [tc.fade(t.isDark ? 0.07 : 0.05), tc.fade(t.isDark ? 0.26 : 0.18)],
                               from: CGPoint(x: fill.minX, y: fill.midY), to: CGPoint(x: fill.maxX, y: fill.midY))
                // Where it has got to: a tick at the top and bottom edges, clear of the text.
                if f < 1 {
                    for y in [fill.minY, fill.maxY - 5] {
                        ctx.fill(CGPath(rect: CGRect(x: fill.maxX - 1.5, y: y, width: 1.5, height: 5), transform: nil), tc.fade(0.9))
                    }
                }
            }
        }
        ctx.innerStroke(shape, t.isDark ? white(0.07) : black(0.06), width: 0.5)
        let mid = r.midY
        drawTile(c, center: CGPoint(x: r.minX + 18, y: mid), tone: tone(c, t), theme: t, ctx: ctx, size: 16)
        drawOpens(r, mid: mid, theme: t, ctx: ctx)
        var right = r.maxX - 10 - chevronW - 8
        // The state word, or a button for an answer.
        if c.needsInput, c.actions.openSession {
            let b = answerRect(r)
            drawAnswer(b, theme: t, ctx: ctx)
            right = b.minX - 8
        } else if let w = stateWord(c, theme: t) {
            w.text.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= w.text.width
            if w.pause {
                Glyph.pause(in: CGRect(x: right - 4 - 7, y: mid - 4.5, width: 7, height: 9), color: t.amber, ctx: ctx)
                right -= 11
            }
            right -= 9
        }
        // The percent beside it, for a plan; "7/9" agents stands in for the word otherwise.
        if let hero = c.hero {
            let fig = Text(hero.number + hero.unit, F.sf(11.5, 600, tabular: true), t.muted)
            fig.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= fig.width + 10
        }
        let tx = r.minX + 34
        drawTitle(c, F.sf(12.5, 600), t.ink, x: tx, capCenter: mid, width: right - tx, theme: t, ctx: ctx)
    }

    /// The rose "Answer ↗": opens the session where the question is answered.
    static func drawAnswer(_ b: CGRect, theme t: Theme, ctx: CGContext) {
        let shape = rounded(b, b.height / 2)
        let top = t.isDark ? rgb(0xFF7F95) : rgb(0xE23A5C), bottom = t.isDark ? rgb(0xE8445F) : rgb(0xC81C40)
        ctx.withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: t.rose.fade(0.45).cgColor)
            ctx.fill(shape, bottom)
        }
        ctx.fillVertical(shape, top, bottom)
        Text("Answer", F.sf(11, 650), .white).draw(x: b.minX + 10, capCenter: b.midY, in: ctx)
        drawOut(center: CGPoint(x: b.maxX - 12, y: b.midY), color: .white, ctx: ctx)
    }

    /// "↗": leaves for the agent's session.
    static func drawOut(center c: CGPoint, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x - 3, y: c.y + 3)); p.addLine(to: CGPoint(x: c.x + 3, y: c.y - 3))
        p.move(to: CGPoint(x: c.x - 1, y: c.y - 3)); p.addLine(to: CGPoint(x: c.x + 3, y: c.y - 3)); p.addLine(to: CGPoint(x: c.x + 3, y: c.y + 1))
        ctx.stroke(p, color, width: 1.5, cap: .round, join: .round)
    }

    static let tallyHeight: CGFloat = 46, chipHeight: CGFloat = 26

    /// Finished runs as a tally (done, with failures, abandoned, cost) and a chip per run.
    static func drawTally(_ cards: [RunCardModel], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let o = Outcomes(cards)
        var tiles: [(String, String, NSColor)] = [("\(o.done)", "DONE", t.ink),
                                                  ("\(o.failed)", "FAILURES", o.failed > 0 ? RunCardRenderer.failure(t) : t.ink),
                                                  ("\(o.abandoned)", "ABANDONED", t.ink)]
        if let cost = o.cost { tiles.append(("~" + NumberFormat.dollars(cost, style: .precise), "COST", t.ink)) }
        else { tiles.append(("\(cards.count)", "RUNS", t.ink)) }
        let gap: CGFloat = 4
        let tw = (width - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        if let ctx {
            for (i, (value, label, color)) in tiles.enumerated() {
                let r = CGRect(x: origin.x + CGFloat(i) * (tw + gap), y: origin.y, width: tw, height: tallyHeight)
                let shape = rounded(r, 10)
                ctx.fill(shape, t.isDark ? white(0.04) : white(0.75))
                ctx.innerStroke(shape, t.isDark ? white(0.07) : black(0.06), width: 0.5)
                RunCardRenderer.fit(value, F.sf(15, 700, tabular: true), color, width: tw - 18, kern: -0.2).draw(x: r.minX + 10, capCenter: r.minY + 17, in: ctx)
                Text(label, F.sf(8.5, 700), t.muted2, kern: 0.8).draw(x: r.minX + 10, capCenter: r.minY + 34, in: ctx)
            }
        }
        // A chip per run, wrapped.
        var x = origin.x, y = origin.y + tallyHeight + 6
        for c in cards {
            let label = RunCardRenderer.fit(c.title, F.sf(11.5, 550), t.ink.fade(0.85), width: width - 30)
            let w = label.width + 30
            if x > origin.x, x + w > origin.x + width { x = origin.x; y += chipHeight + 4 }
            let r = CGRect(x: x, y: y, width: w, height: chipHeight)
            if let ctx {
                let shape = rounded(r, 8)
                ctx.fill(shape, t.chipFill)
                ctx.innerStroke(shape, t.chipBorder, width: 0.5)
                let gc = c.glyph == .done ? t.ink.fade(0.7) : tone(c, t)
                RunCardRenderer.drawGlyph(c.glyph, color: gc, center: CGPoint(x: r.minX + 13, y: r.midY), size: 9, ctx: ctx)
                label.draw(x: r.minX + 23, capCenter: r.midY, in: ctx)
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 8)
            x += w + 4
        }
        return y + chipHeight - origin.y
    }

    // MARK: Pieces

    /// The state as a glyph in a tinted disc; a quiet run's is a moon.
    static func drawStateIcon(_ c: RunCardModel, center: CGPoint, theme t: Theme, ctx: CGContext) {
        let tc = tone(c, t)
        let disc = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
        ctx.fill(CGPath(ellipseIn: disc, transform: nil), (c.glyph == .done ? t.ink : tc).fade(settled(c) ? 0.08 : 0.15))
        if c.glyph == .stale {
            drawMoon(center: center, color: tc, ctx: ctx)
        } else {
            RunCardRenderer.drawGlyph(c.glyph, color: c.glyph == .done ? t.ink.fade(0.75) : tc, center: center, size: 10, ctx: ctx)
        }
    }

    static func drawMoon(center c: CGPoint, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        p.addEllipse(in: CGRect(x: c.x - 1, y: c.y - 7, width: 8.5, height: 8.5))
        ctx.withState {
            ctx.addPath(p); ctx.setFillColor(color.cgColor); ctx.fillPath(using: .evenOdd)
        }
    }

    /// The provider's tile with the state as a dot on its corner, as an app badge sits.
    static func drawTile(_ c: RunCardModel, center: CGPoint, tone: NSColor, theme t: Theme, ctx: CGContext, size: CGFloat = 20) {
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if let p = c.provider {
            BrandMark.drawTile(p, in: rect, theme: t, ctx: ctx)
        } else {
            ctx.fill(rounded(rect, size * 0.27), t.chipFill)
            RunCardRenderer.drawGlyph(c.glyph, color: tone, center: center, size: size / 2, ctx: ctx)
            return
        }
        let d = (size * 0.45).rounded()
        let dot = CGRect(x: rect.maxX - d * 0.67, y: rect.maxY - d * 0.67, width: d, height: d)
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
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        let cells: [(weight: Double, fill: Double, tone: RunTone, failed: Bool)]
        if !c.segments.isEmpty {
            cells = c.segments.map { ($0.weight, $0.fill, $0.tone, $0.failed) }
        } else {
            let f = min(max(c.hero?.fraction ?? 0, 0), 1)
            cells = (0..<5).map { i in (0.2, min(max(f * 5 - Double(i), 0), 1), c.tone == .warn ? .warn : .progress, false) }
        }
        let n = cells.count
        // Narrower gaps until a cell is a point wide, and none past that: at 1pt gaps the cells of a
        // run with twenty-odd tasks are slivers, and at 28 there is no room left for any.
        var gap: CGFloat = 1.5
        while gap > 0, inner.width - gap * CGFloat(n - 1) < CGFloat(n) { gap -= 0.5 }
        let minW: CGFloat = 1.5
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
        if let limit = c.page?.limit { parts.append("pauses \(limit.pause) at the 5-hour limit") }
        parts.append(c.subtitle)
        return parts.joined(separator: " · ")
    }
}
