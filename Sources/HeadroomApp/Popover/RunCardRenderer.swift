import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab: a card per agent run. A live card leads with what it's asking when it needs you,
/// then the percent beside its task counts, the task map, the figures and, when the run will hit
/// its provider's 5-hour window, a timeline; then its rows. Finished cards are recessed and show a
/// receipt: how long, how much, how it went, where the time went.
@MainActor
enum RunCardRenderer {
    static let padX: CGFloat = 14, padTop: CGFloat = 13, padBottom: CGFloat = 10
    static let rowHeight: CGFloat = 23, detailHeight: CGFloat = 14, indent: CGFloat = 16
    static let sectionHeaderHeight: CGFloat = 30
    /// The "···" control in a card's header.
    static let menuSize: CGFloat = 22

    /// Vermilion: serious, and plainly not the rose that means "needs you".
    static func failure(_ t: Theme) -> NSColor { t.isDark ? rgb(0xFF6B4A) : rgb(0xC22E14) }

    /// The tone's colour; `.alert` on a failure (`.failed` glyph) is the failure colour, not rose.
    static func color(_ tone: RunTone, _ t: Theme, glyph: RunGlyph? = nil) -> NSColor {
        switch tone {
        case .progress: t.azure
        case .neutral: t.ink
        case .warn: t.amber
        case .alert: glyph == .failed ? failure(t) : t.rose
        case .quiet: t.muted
        }
    }

    // MARK: Page

    /// Live cards, then the last day's finished ones under their own header. Returns the height.
    @discardableResult
    static func drawPage(_ page: RunsPageModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        var y = origin.y
        if page.isEmpty { return drawEmpty(origin: origin, width: width, theme: theme, ctx: ctx, out: out) }
        for (i, c) in page.live.enumerated() {
            if i > 0 { y += 10 }
            y += draw(c, origin: CGPoint(x: origin.x, y: y), width: width, theme: theme, ctx: ctx, out: out)
        }
        if !page.recent.isEmpty {
            if !page.live.isEmpty { y += 16 }
            let mid = y + 14
            if let ctx {
                Text(RunsPageModel.recentTitle, F.sf(15, 650), theme.ink, kern: -0.15).draw(x: origin.x + 3, capCenter: mid, in: ctx)
            }
            // "+ N more" lists them all; "Show fewer" goes back.
            let link = page.moreRecent > 0 ? "+ \(page.moreRecent) more" : page.allRecent ? "Show fewer" : nil
            if let link {
                let l = Text(link, F.sf(11.5, 550), theme.muted)
                if let ctx { l.draw(x: origin.x + width - 3, capCenter: mid, align: .right, in: ctx) }
                out?.add(CGRect(x: origin.x + width - 3 - l.width - 8, y: mid - 11, width: l.width + 16, height: 22), action: .moreRecent)
            }
            y += sectionHeaderHeight
            for (i, c) in page.recent.enumerated() {
                if i > 0 { y += 8 }
                y += draw(c, origin: CGPoint(x: origin.x, y: y), width: width, theme: theme, ctx: ctx, out: out)
            }
        }
        return y - origin.y
    }

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

    // MARK: Card

    @discardableResult
    static func draw(_ m: RunCardModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let h = pass(m, origin: origin, width: width, theme: theme, ctx: nil, out: nil)
        guard let ctx else {
            // Measuring with regions wanted (tests, hit-testing without drawing).
            if out != nil { _ = pass(m, origin: origin, width: width, theme: theme, ctx: nil, out: out) }
            return h
        }
        // Every card wears the app's chrome and its provider's wash, as Pace and Past weeks do. A
        // finished run is told apart by its smaller header, not by a different surface.
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: m.provider, theme: theme, ctx: ctx)
        _ = pass(m, origin: origin, width: width, theme: theme, ctx: ctx, out: out)
        return h
    }

    private static func pass(_ m: RunCardModel, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        var y = origin.y + padTop
        let tone = color(m.tone, t, glyph: m.glyph)

        // 1. Header. Live: Pace's 28pt tile and 15pt title, the subtitle beside the tile. Finished:
        //    Past weeks' 20pt tile and 14pt title with the state as a chip, the subtitle beneath.
        let tileSize: CGFloat = m.live ? 28 : 20
        let headMid = y + tileSize / 2
        var right = x0 + w
        var menu: CGRect?
        if m.actions.any {
            let r = CGRect(x: right - menuWidth, y: headMid - 11, width: menuWidth, height: 22)
            menu = r
            right = r.minX - 8
        }
        let tx = x0 + tileSize + (m.live ? 9 : 8)
        if m.live {
            if let ctx {
                drawTile(m, rect: CGRect(x: x0, y: y, width: tileSize, height: tileSize), tone: tone, theme: t, ctx: ctx)
                fit(m.title, F.sf(15, 650), t.ink, width: right - tx, kern: -0.075).draw(x: tx, capCenter: y + 7.5, in: ctx)
                fit(m.subtitle, F.sf(11.5, 500), t.muted, width: right - tx).draw(x: tx, capCenter: y + 22, in: ctx)
            }
            y += tileSize
        } else {
            let chip = Chip(m.stateText, tone: tone, theme: t)
            let chipRight = right
            right -= chip.width + 8
            if let ctx {
                drawTile(m, rect: CGRect(x: x0, y: y, width: tileSize, height: tileSize), tone: tone, theme: t, ctx: ctx)
                fit(m.title, F.sf(14, 650), t.ink, width: right - tx, kern: -0.07).draw(x: tx, capCenter: headMid, in: ctx)
                chip.draw(right: chipRight, mid: headMid, ctx: ctx)
            }
            y += tileSize + 5
            if let ctx { fit(m.subtitle, F.sf(11.5, 500), t.muted, width: x0 + w - tx).draw(x: tx, capCenter: y + 6, in: ctx) }
            y += 12
        }
        if let menu, let ctx { drawMenuChip(menu, theme: t, ctx: ctx) }
        if m.expandable {
            out?.add(CGRect(x: origin.x, y: origin.y, width: (menu?.minX ?? origin.x + width) - origin.x - 4, height: y - origin.y + 6),
                     tooltip: m.expanded ? "Show fewer tasks" : "Show every task", action: .toggleRun(m.id))
        }
        if let menu { out?.add(menu.insetBy(dx: -3, dy: -3), tooltip: "More", action: .runMenu(m.id)) }

        if m.live {
            // 2. What it's asking leads the card.
            if let q = m.question {
                y += 12
                y += drawQuestion(q, id: m.id, actions: m.actions, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
            }
            // 3. Hero: the percent (or agents finished) and the time left or spent.
            if let hero = m.hero {
                y += 15
                if let ctx { drawHero(hero, x: x0, y: y, w: w, theme: t, ctx: ctx) }
                y += heroHeight
            }
            // 4. The meter: one cell per task when there's a map, Pace's five cells otherwise.
            y += 14
            let track = CGRect(x: x0, y: y, width: w, height: MeterRenderer.height)
            if !m.segments.isEmpty {
                if let ctx { drawMap(m.segments, rect: track, theme: t, ctx: ctx) }
                y += MeterRenderer.height
                if m.segments.contains(where: \.critical) {
                    if let ctx { drawMustHaves(m.segments, track: track, top: y + 4, theme: t, ctx: ctx) }
                    y += 4 + 15
                }
            } else if let hero = m.hero {
                let cells = Int((min(max(hero.fraction, 0), 1) * 5).rounded())
                if let ctx { MeterRenderer.draw(MeterModel(state: m.tone == .warn ? .tight : .plenty, cells: cells, opacity: 1), rect: track, theme: t, ctx: ctx) }
                y += MeterRenderer.height
            }
            // 5. Verdict: the state, its figure, and what's going on in a sentence.
            y += 12
            y += drawVerdict(m, tone: tone, x: x0, y: y, w: w, theme: t, ctx: ctx)
            // 6. Against the 5-hour window, when it will pause the run.
            if let tl = m.timeline {
                y += 12
                y += drawTimeline(tl, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
        } else {
            if let primary = m.verdict?.primary {
                y += 10
                let block = TextBlock(primary, F.sf(14), t.ink, width: w, lineHeight: 19.3, kern: -0.07)
                if let ctx { block.draw(x: x0, top: y, in: ctx) }
                y += block.height
                if let secondary = m.verdict?.secondary {
                    let s = TextBlock(secondary, F.sf(12.5), t.muted, width: w, lineHeight: 17.25)
                    if let ctx { s.draw(x: x0, top: y + 3, in: ctx) }
                    y += 3 + s.height
                }
            }
            if let rc = m.receipt {
                y += 12
                y += drawReceipt(rc, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
        }

        // A limit warning with no timeline to say it, as Pace's callout.
        if let warning = m.warning, m.verdict?.primary != warning, m.timeline == nil {
            y += 10
            y += drawCallout(warning, x: x0, y: y, w: w, theme: t, ctx: ctx)
        }

        // The tasks, under a quiet header like Activity's breakdown (none over summary lines alone).
        if !m.rows.isEmpty {
            let headed = m.rows.contains { $0.kind == .task }
            y += headed ? (m.live ? 16 : 14) : 8
            if headed, let ctx {
                let b = baseline(top: y, font: F.sf(11.5, 600), lineHeight: 14)
                Text(m.rowsTitle, F.sf(11.5, 600), t.muted).draw(x: x0, baseline: b, in: ctx)
                if m.rows.contains(where: { $0.tokens != nil }) {
                    Text("tokens", F.sf(11.5, 500), t.ink.fade(0.4)).draw(x: x0 + w, baseline: b, align: .right, in: ctx)
                }
            }
            if headed { y += 14 + 3 }
            for row in m.rows {
                let panel = row.details.map { DetailPanel($0, width: w - (CGFloat(row.depth) * indent + 17) + 8, theme: t) }
                let h = rowHeight + (panel == nil ? (row.detail == nil ? 0 : detailHeight) : panel!.height + 4)
                if let ctx { drawRow(row, panel: panel, x: x0, y: y, w: w, theme: t, ctx: ctx) }
                let hit = CGRect(x: x0 - 6, y: y, width: w + 12, height: h)
                switch row.kind {
                case .finished, .more: out?.add(hit, action: .toggleRun(m.id))
                case .task where row.opens: out?.add(hit, action: .toggleRow(m.id, row.id))
                default: break
                }
                y += h
            }
        }
        return y + padBottom - origin.y
    }

    // MARK: Header pieces

    static let menuWidth: CGFloat = 30
    static let heroHeight: CGFloat = 47 + 8 + 15

    /// The provider's tile; a run with no known provider gets its state glyph on a plain tile.
    static func drawTile(_ m: RunCardModel, rect: CGRect, tone: NSColor, theme t: Theme, ctx: CGContext) {
        if let p = m.provider {
            BrandMark.drawTile(p, in: rect, ctx: ctx)
        } else {
            ctx.fill(rounded(rect, rect.width * 0.27), t.chipFill)
            drawGlyph(m.glyph, color: tone, center: CGPoint(x: rect.midX, y: rect.midY), size: rect.width * 0.5, ctx: ctx)
        }
    }

    /// The card's menu, as Activity's span chip: a soft rounded chip with "···".
    static func drawMenuChip(_ r: CGRect, theme t: Theme, ctx: CGContext) {
        ctx.fill(rounded(r, 8), t.chipFill)
        for dx in [-5.0, 0, 5.0] as [CGFloat] {
            ctx.fill(CGPath(ellipseIn: CGRect(x: r.midX + dx - 1.4, y: r.midY - 1.4, width: 2.8, height: 2.8), transform: nil), t.muted)
        }
    }

    /// A state chip, as Past weeks' header chips: a dot of the state's colour and its words.
    struct Chip {
        var text: Text
        var dot: NSColor
        var theme: Theme
        init(_ s: String, tone: NSColor, theme: Theme) {
            text = Text(s, F.sf(10.5, 600, tabular: true), theme.ink); dot = tone; self.theme = theme
        }
        var width: CGFloat { 7 + 6 + 5 + text.width + 7 }
        func draw(right: CGFloat, mid: CGFloat, ctx: CGContext) {
            let r = CGRect(x: right - width, y: mid - 9, width: width, height: 18)
            ctx.fill(rounded(r, 7), theme.chipFill)
            ctx.innerStroke(rounded(r, 7), theme.chipBorder, width: 0.5)
            ctx.fill(CGPath(ellipseIn: CGRect(x: r.minX + 7, y: r.midY - 3, width: 6, height: 6), transform: nil), dot)
            text.draw(x: r.minX + 7 + 6 + 5, capCenter: r.midY, in: ctx)
        }
    }

    // MARK: Hero

    /// Pace's hero: the number at 56pt with its unit raised, the label under it; the side figure
    /// at 32pt on the right (with the hourglass for time left) and its caption.
    static func drawHero(_ h: RunHeroModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext) {
        let numFont = F.sf(56, 700, tabular: true)
        let num = Text(h.number, numFont, t.ink, kern: -2.8)
        let numBase = baseline(top: y, font: numFont, lineHeight: 47)
        num.draw(x: x - 1, baseline: numBase, in: ctx)
        let unitFont = F.sf(23, 650)
        let capTop = numBase - numFont.capHeight
        Text(h.unit, unitFont, t.ink.fade(0.88)).draw(x: x - 1 + num.width + 3 + 2.8, baseline: capTop + 4 + unitFont.capHeight, in: ctx)
        let labelTop = y + 47 + 8
        let labelBase = baseline(top: labelTop, font: F.sf(12, 500), lineHeight: 15)
        var captionWidth: CGFloat = 0
        if let side = h.side {
            let right = x + w
            let vFont = F.sf(32, 700, tabular: true)
            let v = Text(side, vFont, t.ink, kern: -1.12)
            let vBase = labelTop - 8 - 27.5 + baseline(top: 0, font: vFont, lineHeight: 27.5)
            v.draw(x: right + 1.12, baseline: vBase, align: .right, in: ctx)
            if h.hourglass {
                let hgH: CGFloat = 19
                let hx = right - v.width - 7 - hgH * 0.7
                Glyph.hourglass(in: CGRect(x: hx, y: vBase - vFont.capHeight / 2 - hgH / 2, width: hgH * 0.7, height: hgH), color: t.pacing(.plenty).text, ctx: ctx)
            }
            if let c = h.sideCaption {
                let caption = Text(c, F.sf(12, 500, tabular: true), t.muted)
                caption.draw(x: right, baseline: labelBase, align: .right, in: ctx)
                captionWidth = caption.width + 12
            }
        }
        fit(h.label, F.sf(12, 500, tabular: true), t.muted, width: w - captionWidth).draw(x: x, baseline: labelBase, in: ctx)
    }

    // MARK: Verdict

    /// Pace's verdict: the state badge with its figure on the right, then a sentence and a quieter
    /// one. Returns its height.
    static func drawVerdict(_ m: RunCardModel, tone: NSColor, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let v = m.verdict
        let primary = v?.primary.map { TextBlock($0, F.sf(14), t.ink, width: w, lineHeight: 19.3, kern: -0.07) }
        let secondary = v?.secondary.map { TextBlock($0, F.sf(12.5), t.muted, width: w, lineHeight: 17.25) }
        var h: CGFloat = 23
        if let primary { h += 8 + primary.height }
        if let secondary { h += (primary == nil ? 8 : 3) + secondary.height }
        guard let ctx else { return h }
        drawBadge(m.stateText, color: tone, glow: m.tone != .quiet && m.tone != .neutral, origin: CGPoint(x: x, y: y), theme: t, ctx: ctx)
        if let figure = v?.figure { Text(figure, F.mono(11, 600), t.muted).draw(x: x + w, capCenter: y + 11.5, align: .right, in: ctx) }
        var yy = y + 23
        if let primary { primary.draw(x: x, top: yy + 8, in: ctx); yy += 8 + primary.height }
        if let secondary { secondary.draw(x: x, top: yy + (primary == nil ? 8 : 3), in: ctx) }
        return h
    }

    /// Pace's state badge: a tinted capsule, a glowing dot and the state's name.
    static func drawBadge(_ title: String, color c: NSColor, glow: Bool, origin: CGPoint, theme t: Theme, ctx: CGContext) {
        let label = Text(title, F.sf(12.5, 650), c)
        let r = CGRect(x: origin.x, y: origin.y, width: 8 + 7 + 7 + label.width + 11, height: 23)
        let capsule = rounded(r, r.height / 2)
        ctx.fill(capsule, c.fade(0.13))
        ctx.innerStroke(capsule, c.fade(0.38), width: 0.5)
        let dot = CGMutablePath()
        dot.addEllipse(in: CGRect(x: r.minX + 8, y: r.midY - 3.5, width: 7, height: 7))
        ctx.withState {
            if glow { ctx.setShadow(offset: .zero, blur: 8, color: c.cgColor) }
            ctx.fill(dot, c)
        }
        label.draw(x: r.minX + 8 + 7 + 7, capCenter: r.midY, in: ctx)
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

    // MARK: Question

    /// The question, in the grammar of Pace's 5-hour warning panel: a rose wash, an icon tile, who
    /// is asking; then the question at the verdict's size, the answers offered as chips, and the
    /// buttons that take you to the session. Returns its height.
    static func drawQuestion(_ q: RunQuestionModel, id: String, actions: RunActionSet, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme,
                             ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let pad: CGFloat = 12, inner = w - pad * 2
        let text = TextBlock(q.text, F.sf(14, 500), t.ink, width: inner, lineHeight: 19.3, kern: -0.07)
        // Answer chips, wrapped.
        let chipFont = F.sf(11.5, 600), chipH: CGFloat = 22, gap: CGFloat = 6
        var chips: [(Text, CGRect)] = []
        var cx: CGFloat = 0, cy: CGFloat = 0
        for o in q.options {
            let label = fit(o, chipFont, t.ink, width: inner - 20)
            let cw = label.width + 20
            if cx > 0, cx + cw > inner { cx = 0; cy += chipH + gap }
            chips.append((label, CGRect(x: cx, y: cy, width: cw, height: chipH)))
            cx += cw + gap
        }
        let chipsH = chips.isEmpty ? 0 : cy + chipH
        var buttons: [(String, HitRegion.RunButton)] = []
        if actions.openSession { buttons.append(("Open session", .openSession)) }
        if actions.copyResume { buttons.append(("Copy resume command", .copyResume)) }
        let headTop = y + 11, textTop = headTop + 22 + 9
        let chipsTop = textTop + text.height + 10
        let afterText = chips.isEmpty ? textTop + text.height : chipsTop + chipsH
        let buttonsTop = afterText + 12
        let h = (buttons.isEmpty ? afterText : buttonsTop + 26) + pad - y
        var bx = x + pad
        var rects: [CGRect] = []
        for (label, kind) in buttons {
            let r = pillRect(label, x: bx, top: buttonsTop)
            rects.append(r)
            out?.add(r, action: .runButton(id, kind))
            bx = r.maxX + 8
        }
        guard let ctx else { return h }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let shape = rounded(rect, 14)
        ctx.fillLinear(shape, [rgb(0xEE3459).fade(t.isDark ? 0.17 : 0.12), rgb(0xEE3459).fade(t.isDark ? 0.06 : 0.035)],
                       from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.innerStroke(shape, rgb(0xFF6982).fade(t.isDark ? 0.30 : 0.42), width: 1)
        let icon = CGRect(x: x + 11, y: headTop, width: 22, height: 22)
        ctx.fill(rounded(icon, 6.5), t.rose.fade(0.18))
        drawGlyph(.needsInput, color: t.rose, center: CGPoint(x: icon.midX, y: icon.midY), size: 12, ctx: ctx)
        fit(q.asker, F.sf(12.5, 650), t.rose, width: inner - 32).draw(x: icon.maxX + 10, capCenter: icon.midY, in: ctx)
        text.draw(x: x + pad, top: textTop, in: ctx)
        for (label, r) in chips {
            let chip = rounded(r.offsetBy(dx: x + pad, dy: chipsTop), 7)
            ctx.fill(chip, t.chipFill)
            ctx.innerStroke(chip, t.chipBorder, width: 0.5)
            label.draw(x: chip.boundingBox.midX, capCenter: chip.boundingBox.midY, align: .center, in: ctx)
        }
        for (i, (label, _)) in buttons.enumerated() {
            drawPill(label, rect: rects[i], theme: t, ctx: ctx, style: i == 0 ? .rose : .plain)
        }
        return h
    }

    enum PillStyle { case azure, rose, plain }

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

    /// The meter's caret row for the must-haves: a ▲ under each, labelled once, as EVEN PACE is.
    static func drawMustHaves(_ segs: [RunSegment], track: CGRect, top: CGFloat, theme t: Theme, ctx: CGContext) {
        let color = t.isDark ? rgb(0xF4F4F6, 0.45) : rgb(0x1C1C1E, 0.45)
        let xs = zip(segs, centers(segs, track: track)).filter { $0.0.critical }.map(\.1)
        guard let first = xs.first else { return }
        for cx in xs { Glyph.caret(in: CGRect(x: cx - 3.5, y: top + 3.5, width: 7, height: 5), color: color, ctx: ctx) }
        let label = Text(xs.count == 1 ? "MUST-HAVE" : "MUST-HAVES", F.sf(8.5, 650), color, kern: 0.765)
        let need = 3.5 + 4 + label.width
        // Beside a caret with clear room: after the last, else in the first wide gap, else before the first.
        if let last = xs.last, last + need <= track.maxX {
            label.draw(x: last + 3.5 + 4, capCenter: top + 6, in: ctx)
        } else if let gap = zip(xs, xs.dropFirst()).first(where: { $0.1 - $0.0 > need + 10 }) {
            label.draw(x: gap.0 + 3.5 + 4, capCenter: top + 6, in: ctx)
        } else if first - need >= track.minX {
            label.draw(x: first - 3.5 - 4, capCenter: top + 6, align: .right, in: ctx)
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

    // MARK: Timeline

    /// The run against its provider's 5-hour window, in the grammar of Pace's 5-hour panel: an
    /// amber wash because it will pause, an icon tile, what happens and when, the countdown on the
    /// right; then the track (working, paused, working again) with its ticks in the charts'
    /// uppercase labels, and the forecast as a toned dot and one sentence. Returns its height.
    static func drawTimeline(_ tl: RunTimelineModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let inner = w - 24
        let note = tl.note.map { TextBlock($0, F.sf(12.5), t.ink.fade(0.86), width: inner - 13, lineHeight: 16.5) }
        let trackTop: CGFloat = 48 + 4, trackH: CGFloat = 6
        let labelsH: CGFloat = 6 + 11
        let h = trackTop + trackH + labelsH + (note.map { 10 + $0.height } ?? 0) + 12
        guard let ctx else { return h }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let shape = rounded(rect, 14)
        ctx.fillLinear(shape, [rgb(0xF4A51F).fade(t.isDark ? 0.17 : 0.14), rgb(0xF4A51F).fade(t.isDark ? 0.06 : 0.04)],
                       from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.innerStroke(shape, rgb(0xFFC248).fade(t.isDark ? 0.30 : 0.45), width: 1)
        let amber = t.session(.amber)

        func tick(_ label: String) -> RunTimelineModel.Tick? { tl.ticks.first { $0.label == label } }
        let icon = CGRect(x: rect.minX + 11, y: rect.minY + 13, width: 22, height: 22)
        ctx.fill(rounded(icon, 6.5), amber.fade(0.18))
        Glyph.pause(in: CGRect(x: icon.midX - 3.4, y: icon.midY - 4, width: 6.8, height: 8), color: amber, ctx: ctx)
        let tx = icon.maxX + 10, right = rect.maxX - 12
        let done = tick("done")
        let count = Text(done?.time ?? "", F.sf(17, 700, tabular: true), amber, kern: -0.2)
        count.draw(x: right, baseline: rect.minY + 9 + 15, align: .right, in: ctx)
        let caption = Text("DONE", F.sf(8.5, 650), amber.fade(0.8), kern: 0.765)
        caption.draw(x: right + 0.765, baseline: rect.minY + 9 + 15 + 3 + 9.5, align: .right, in: ctx)
        let title = PaceCardRenderer.fit(["Pauses at the 5-hour limit", "Pauses at the limit"], font: F.sf(12.5, 650), width: right - count.width - 10 - tx)
        Text(title, F.sf(12.5, 650), amber).draw(x: tx, baseline: baseline(top: rect.minY + 9, font: F.sf(12.5, 650), lineHeight: 15), in: ctx)
        var sub: [String] = []
        if let p = tick("window empty") { sub.append("empties \(p.time)") }
        if let r = tick("resets") { sub.append("resets \(r.time)") }
        let subtitle = PaceCardRenderer.fit([sub.joined(separator: " · "), sub.first ?? ""], font: F.sf(12, 400, tabular: true), width: right - caption.width - 10 - tx)
        Text(subtitle, F.sf(12, 400, tabular: true), t.muted).draw(x: tx, baseline: baseline(top: rect.minY + 9 + 15 + 1, font: F.sf(12), lineHeight: 14.4), in: ctx)

        // The track, as the 5-hour panel's: dark, 6pt, working in azure, the pause hatched amber.
        let tr = CGRect(x: rect.minX + 12, y: rect.minY + trackTop, width: inner, height: trackH)
        let trackShape = rounded(tr, 3)
        ctx.fill(trackShape, t.isDark ? black(0.32) : black(0.07))
        if t.isDark { ctx.innerStroke(trackShape, white(0.05), width: 0.5) }
        let azure = t.pacing(.plenty)
        ctx.withState {
            ctx.addPath(trackShape); ctx.clip()
            for s in tl.spans where s.end > s.start {
                let r = CGRect(x: tr.minX + tr.width * CGFloat(s.start), y: tr.minY, width: tr.width * CGFloat(s.end - s.start), height: trackH)
                switch s.kind {
                case .working: ctx.fillVertical(CGPath(rect: r.insetBy(dx: 0.75, dy: 0), transform: nil), azure.top, azure.bottom)
                case .paused:
                    let p = CGPath(rect: r.insetBy(dx: 0.75, dy: 0), transform: nil)
                    ctx.fill(p, amber.fade(0.18))
                    hatch(p, color: amber.fade(0.7), spacing: 3.2, lineWidth: 1, ctx: ctx)
                }
            }
        }
        // Ticks: the charts' uppercase labels, one row. The strong ticks (window empty, done) are
        // placed first; the others only where there's room left.
        let labelFont = F.sf(8.5, 650)
        struct Placed { var left: CGFloat; var right: CGFloat }
        var placed: [Placed] = []
        let order = tl.ticks.enumerated().sorted { ($0.element.strong ? 0 : 1, $0.offset) < ($1.element.strong ? 0 : 1, $1.offset) }.map(\.element)
        for tk in order {
            let cx = min(max(tr.minX + tr.width * CGFloat(tk.at), tr.minX + 1), tr.maxX - 1)
            let mark = CGMutablePath(); mark.move(to: CGPoint(x: cx, y: tr.maxY + 1.5)); mark.addLine(to: CGPoint(x: cx, y: tr.maxY + 4.5))
            ctx.stroke(mark, tk.strong ? amber.fade(0.8) : t.muted2, width: 1, cap: .round)
            let l = Text(tk.label.uppercased(), labelFont, tk.strong ? amber.fade(0.9) : t.muted, kern: 0.765)
            let left = min(max(cx - l.width / 2, tr.minX), tr.maxX - l.width)
            guard !placed.contains(where: { left < $0.right + 8 && left + l.width + 8 > $0.left }) else { continue }
            l.draw(x: left, capCenter: tr.maxY + 6 + 5.5, in: ctx)
            placed.append(Placed(left: left, right: left + l.width))
        }
        if let note {
            let top = tr.maxY + labelsH + 10
            let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: rect.minX + 12, y: top + 8.25 - 3, width: 6, height: 6))
            ctx.withState { ctx.setShadow(offset: .zero, blur: 6, color: amber.fade(0.8).cgColor); ctx.fill(dot, amber) }
            note.draw(x: rect.minX + 12 + 6 + 7, top: top, in: ctx)
        }
        return h
    }

    // MARK: Receipt

    /// A finished run's figures as Activity's stat tiles (how long, tokens with their cost, tasks),
    /// then where the time went as Activity's composition bar with a legend. Returns its height.
    static func drawReceipt(_ rc: RunReceiptModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let tileW = (w - 12) / 3, tileH: CGFloat = 49
        let parts = splitParts(rc.time, theme: t)
        let legendFont = F.sf(11, 500, tabular: true)
        var legend: [(Text, NSColor, CGPoint)] = []
        var legendH: CGFloat = 0
        if !parts.isEmpty {
            var lx: CGFloat = 0, ly: CGFloat = 0
            for p in parts {
                let label = Text(p.label + " " + RunsPresenter.duration(p.seconds), legendFont, t.muted)
                let iw = 7 + 5 + label.width
                if lx > 0, lx + iw > w { lx = 0; ly += 16 }
                legend.append((label, p.color, CGPoint(x: lx, y: ly)))
                lx += iw + 12
            }
            legendH = ly + 14
        }
        let h = tileH + (parts.isEmpty ? 0 : 9 + 5 + 8 + legendH)
        guard let ctx else { return h }
        let cost = rc.cost?.replacingOccurrences(of: "about ", with: "~")
        let tiles: [(String, String, String?)] = [("Took", rc.duration, nil), ("Tokens", rc.tokens, cost), ("Tasks", rc.tasks, nil)]
        for (i, tile) in tiles.enumerated() {
            let r = CGRect(x: x + CGFloat(i) * (tileW + 6), y: y, width: tileW, height: tileH)
            ctx.fill(rounded(r, 11), t.tileFill)
            Text(tile.0, F.sf(11, 500), t.muted).draw(x: r.minX + 9, baseline: baseline(top: r.minY + 8, font: F.sf(11, 500), lineHeight: 14), in: ctx)
            let vb = baseline(top: r.minY + 8 + 14 + 3, font: F.sf(15, 700), lineHeight: 17)
            let v = fit(tile.1, F.sf(15, 700, tabular: true), t.ink, width: r.width - 18, kern: -0.15)
            v.draw(x: r.minX + 9, baseline: vb, in: ctx)
            if let suffix = tile.2 {
                let room = r.width - 18 - v.width - 4
                let s = fit(suffix, F.sf(11, 500, tabular: true), t.ink.fade(0.45), width: room)
                if room > 18 { s.draw(x: r.minX + 9 + v.width + 4, baseline: vb, in: ctx) }
            }
        }
        guard !parts.isEmpty else { return h }
        var yy = y + tileH + 9
        let total = parts.reduce(0) { $0 + $1.seconds }
        let bar = CGRect(x: x, y: yy, width: w, height: 5)
        ctx.withState {
            ctx.addPath(rounded(bar, 3)); ctx.clip()
            let avail = w - 2 * CGFloat(parts.count - 1)
            var bx = x
            for p in parts {
                let bw = max(3, avail * CGFloat(p.seconds / total))
                ctx.fill(CGPath(rect: CGRect(x: bx, y: yy, width: bw, height: 5), transform: nil), p.color)
                bx += bw + 2
            }
        }
        yy += 5 + 8
        for (label, c, at) in legend {
            ctx.fill(rounded(CGRect(x: x + at.x, y: yy + at.y + 7 - 3.5, width: 7, height: 7), 2.5), c)
            label.draw(x: x + at.x + 12, capCenter: yy + at.y + 7, in: ctx)
        }
        return h
    }

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
        let tone = color(m.tone, t, glyph: m.glyph)
        return Capsule(label: Text(m.stateText, F.sf(11, 650), tone), tone: tone, strong: m.tone != .neutral && m.tone != .quiet)
    }

    /// "···" in a soft circle: the card's menu.
    static func drawMenuButton(_ r: CGRect, theme t: Theme, ctx: CGContext) {
        ctx.fill(CGPath(ellipseIn: r, transform: nil), t.isDark ? white(0.06) : black(0.04))
        for dx in [-4.0, 0, 4.0] as [CGFloat] {
            ctx.fill(CGPath(ellipseIn: CGRect(x: r.midX + dx - 1.2, y: r.midY - 1.2, width: 2.4, height: 2.4), transform: nil), t.muted)
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
