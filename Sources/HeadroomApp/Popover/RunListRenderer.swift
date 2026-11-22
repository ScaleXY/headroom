import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab's one list. The most pressing run is opened in place as the lead card (its
/// question and who asks, what's left on your turn, or what it's doing); with nothing live the
/// lead card is the day's receipt. The rest follow as two-line rows under "Needs you", "Working",
/// and each day with its total. Every row and the lead card open the run's own page (`.openRun`).
///
/// Colour: amber only for time and limits, rose only for a question, pearl (ink) for your turn
/// and settled runs, blue for work moving.
@MainActor
enum RunListRenderer {
    /// The whole list. `showFinished` opens the days' folded short sessions. Returns the height;
    /// the measuring pass (`ctx == nil`) returns the same height as the drawing one.
    @discardableResult
    static func drawPage(_ page: RunsPageModel, showFinished: Bool = false, origin: CGPoint, width: CGFloat, theme t: Theme,
                         ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        if page.isEmpty { return RunCardRenderer.drawEmpty(origin: origin, width: width, theme: t, ctx: ctx, out: out) }
        var y = origin.y
        let lead = page.leadID.flatMap { id in page.live.first { $0.id == id } }
        if let lead {
            y += drawLead(lead, origin: CGPoint(x: origin.x, y: y), width: width, theme: t, ctx: ctx, out: out)
        } else if let receipt = page.receipt {
            y += drawReceipt(receipt, origin: CGPoint(x: origin.x, y: y), width: width, theme: t, ctx: ctx)
        }
        var first = lead == nil && page.receipt == nil
        func section(_ label: String, color: NSColor, right: String? = nil, link: (String, HitRegion.Action)? = nil, _ body: (CGFloat) -> CGFloat) {
            y += header(label, color: color, right: right, link: link, x: origin.x, y: y, width: width, top: first, theme: t, ctx: ctx, out: out)
            y += body(y)
            first = false
        }
        let rest = page.live.filter { $0.id != lead?.id }
        let needsYou = rest.filter { $0.phase == .asks || $0.phase == .yourTurn }, working = rest.filter { $0.phase == .working }
        if !needsYou.isEmpty {
            section("\(lead == nil ? "" : "ALSO ")\(RunWords.needsYouSection.uppercased()) · \(needsYou.count)",
                    color: needsYou.contains { $0.phase == .asks } ? t.rose : t.muted2) {
                drawRows(needsYou, origin: CGPoint(x: origin.x, y: $0), width: width, theme: t, ctx: ctx, out: out)
            }
        }
        if !working.isEmpty {
            section("\(RunWords.workingSection.uppercased()) · \(working.count)", color: t.muted2) {
                drawRows(working, origin: CGPoint(x: origin.x, y: $0), width: width, theme: t, ctx: ctx, out: out)
            }
        }
        for day in page.days {
            // The cap is shared: one "more" link, on the first day that has runs past it.
            let link: (String, HitRegion.Action)? = day.more > 0 ? ("+ \(day.more) more", .moreRecent)
                : page.allRecent && day.id == page.days.last?.id ? ("Show fewer", .moreRecent) : nil
            section(day.title.uppercased(), color: t.muted2, right: day.summary, link: link) { top in
                drawDay(day, showShort: showFinished, origin: CGPoint(x: origin.x, y: top), width: width, theme: t, ctx: ctx, out: out)
            }
        }
        return y - origin.y
    }

    // MARK: Sections

    static let headerHeight: CGFloat = 32
    static let groupPad: CGFloat = 4

    /// "TODAY" in the charts' caps; on the right the day's total, and a link after it. Returns its height.
    static func header(_ label: String, color: NSColor, right: String?, link: (String, HitRegion.Action)?, x: CGFloat, y: CGFloat, width: CGFloat,
                       top: Bool, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let h: CGFloat = top ? 22 : headerHeight
        let mid = y + h - 11
        let caps = Text(label, F.sf(9.5, 700, tabular: true), color, kern: 0.95)
        if let ctx { caps.draw(x: x + 6, capCenter: mid, in: ctx) }
        var r = x + width - 6
        if let (text, action) = link {
            let l = Text(text, F.sf(11.5, 600), t.ink.fade(0.72))
            if let ctx { l.draw(x: r, capCenter: mid, align: .right, in: ctx) }
            out?.add(CGRect(x: r - l.width - 7, y: mid - 10, width: l.width + 14, height: 20), action: action, hover: 7)
            r -= l.width + 10
        }
        if let right, let ctx {
            RunCardRenderer.fit(right, F.sf(11.5, 550, tabular: true), t.muted, width: r - (x + 6 + caps.width + 12)).draw(x: r, capCenter: mid, align: .right, in: ctx)
        }
        return h
    }

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

    // MARK: Rows

    static let titleLine: CGFloat = 16.5, rowPadTop: CGFloat = 9, secondLine: CGFloat = 15, rowPadBottom: CGFloat = 9
    static let tileX: CGFloat = 19, textX: CGFloat = 40

    /// What a row's layout needs, measured once per pass.
    struct RowLayout {
        var title: TextBlock
        var figure: Text?
        var height: CGFloat
    }

    static func rowLayout(_ c: RunCardModel, width: CGFloat, theme t: Theme) -> RowLayout {
        let figure = c.line.figure.map { Text($0, F.sf(13, 650, tabular: true), c.phase == .settled ? t.ink.fade(0.85) : figureColor(c, t)) }
        let marked = c.mac.map { !c.title.contains($0) } ?? false
        let room = width - textX - 10 - (figure.map { $0.width + 10 } ?? 0) - (marked ? 20 : 0)
        let title = RunPageRenderer.clamp(c.title, F.sf(13, c.phase == .settled ? 550 : 600), c.phase == .settled ? t.ink.fade(0.88) : t.ink,
                                          width: max(room, 60), lineHeight: titleLine, lines: 2, kern: -0.05)
        return RowLayout(title: title, figure: figure, height: rowPadTop + title.height + 3 + secondLine + rowPadBottom)
    }

    /// Uniform two-line rows: the name (two lines before it's cut) and the figure, then the state's
    /// key and what's going on, with the time on the right.
    static func drawRows(_ cards: [RunCardModel], origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let inner = width - groupPad * 2
        let layouts = cards.map { rowLayout($0, width: inner, theme: t) }
        let g = group(rows: layouts.map(\.height), origin: origin, width: width, theme: t, ctx: ctx)
        for (i, (c, r)) in zip(cards, g.rects).enumerated() {
            if let ctx {
                if i > 0 { separator(r, inset: textX, theme: t, ctx: ctx) }
                drawRow(c, layout: layouts[i], row: r, theme: t, ctx: ctx)
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 10)
        }
        return g.height
    }

    static func drawRow(_ c: RunCardModel, layout l: RowLayout, row r: CGRect, theme t: Theme, ctx: CGContext) {
        let firstMid = r.minY + rowPadTop + titleLine / 2
        let second = r.minY + rowPadTop + l.title.height + 3 + secondLine / 2
        if c.phase == .settled {
            drawStateIcon(c, center: CGPoint(x: r.minX + tileX, y: firstMid), theme: t, ctx: ctx)
        } else {
            drawTile(c, center: CGPoint(x: r.minX + tileX, y: firstMid), tone: tone(c, t), theme: t, ctx: ctx)
        }
        let tx = r.minX + textX, right = r.maxX - 10
        l.title.draw(x: tx, top: r.minY + rowPadTop - 1.5, in: ctx)
        if let mac = c.mac, !c.title.contains(mac) {
            // The last line's end, roughly: the mark sits after a one-line title, else at the right.
            let lastW = l.title.height > titleLine + 1 ? 0 : Text(c.title, F.sf(13, 600), t.ink, kern: -0.05).width
            let mx = lastW > 0 ? tx + lastW + 6 : right - (l.figure.map { $0.width + 10 } ?? 0) - 16
            CanvasControlView.drawSymbol("desktopcomputer", in: CGRect(x: mx, y: firstMid - 5.5, width: 14, height: 11), color: t.muted, weight: .medium, ctx: ctx)
        }
        l.figure?.draw(x: right, capCenter: firstMid, align: .right, in: ctx)
        // The second line: the key in its colour, what's going on, the time on the right.
        var room = right
        if let time = c.line.time {
            let tt = Text(time, F.sf(11.5, 550, tabular: true), t.muted)
            tt.draw(x: right, capCenter: second, align: .right, in: ctx)
            room -= tt.width + 10
        }
        let key = RunCardRenderer.fit(c.line.key, F.sf(11.5, 650, tabular: true), keyColor(c.line.keyTone, c, t), width: room - tx)
        key.draw(x: tx, capCenter: second, in: ctx)
        if let detail = c.line.detail, !detail.isEmpty, room - tx - key.width - 7 > 24 {
            RunCardRenderer.fit(detail, F.sf(11.5, 500, tabular: true), t.muted, width: room - tx - key.width - 7)
                .draw(x: tx + key.width + 7, capCenter: second, in: ctx)
        }
    }

    // MARK: Days

    static let shortRow: CGFloat = 38, moreRow: CGFloat = 34

    /// A day's settled runs, then its short sessions folded into one line that opens them.
    static func drawDay(_ day: RunDaySection, showShort: Bool, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let inner = width - groupPad * 2
        let layouts = day.cards.map { rowLayout($0, width: inner, theme: t) }
        let shortOpen = showShort ? day.short : []
        let shortLayouts = shortOpen.map { rowLayout($0, width: inner, theme: t) }
        var heights = layouts.map(\.height)
        if day.shortLine != nil { heights.append(shortRow) }
        heights += shortLayouts.map(\.height)
        let g = group(rows: heights, origin: origin, width: width, theme: t, ctx: ctx)
        var i = 0
        for (c, l) in zip(day.cards, layouts) {
            let r = g.rects[i]
            if let ctx {
                if i > 0 { separator(r, inset: textX, theme: t, ctx: ctx) }
                drawRow(c, layout: l, row: r, theme: t, ctx: ctx)
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 10)
            i += 1
        }
        if let line = day.shortLine {
            let r = g.rects[i]
            if let ctx {
                if i > 0 { separator(r, inset: textX, theme: t, ctx: ctx) }
                let mid = r.midY
                let disc = CGRect(x: r.minX + tileX - 9, y: mid - 9, width: 18, height: 18)
                ctx.fill(CGPath(ellipseIn: disc, transform: nil), t.ink.fade(0.07))
                RunCardRenderer.drawGlyph(.more, color: t.muted, center: CGPoint(x: disc.midX, y: disc.midY), size: 10, ctx: ctx)
                RunCardRenderer.fit(line, F.sf(12, 550, tabular: true), t.muted, width: r.width - textX - 30).draw(x: r.minX + textX, capCenter: mid, in: ctx)
                RunCardRenderer.drawChevron(up: showShort, center: CGPoint(x: r.maxX - 14, y: mid), color: t.muted2, ctx: ctx)
            }
            out?.add(r, tooltip: showShort ? "Fold the short sessions" : "Short sessions that only kept a plan list: show them", action: .toggleFinished,
                     hover: 10)
            i += 1
        }
        for (c, l) in zip(shortOpen, shortLayouts) {
            let r = g.rects[i]
            if let ctx {
                separator(r, inset: textX, theme: t, ctx: ctx)
                drawRow(c, layout: l, row: r, theme: t, ctx: ctx)
            }
            out?.add(r, tooltip: tooltip(c), action: .openRun(c.id), hover: 10)
            i += 1
        }
        return g.height
    }

    // MARK: Lead card

    static let leadPad: CGFloat = 14, leadTile: CGFloat = 26

    /// The most pressing run, opened in place. Clicking it opens its page; its buttons act.
    static func drawLead(_ c: RunCardModel, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        // Regions go in after the card's own, so the buttons win over the card under them.
        let buttons = RenderOutput()
        let h = leadPass(c, origin: origin, width: width, theme: t, ctx: nil, out: nil)
        out?.add(CGRect(x: origin.x, y: origin.y, width: width, height: h), tooltip: tooltip(c), action: .openRun(c.id), hover: 14)
        if let ctx {
            CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: c.provider, theme: t, ctx: ctx)
            _ = leadPass(c, origin: origin, width: width, theme: t, ctx: ctx, out: buttons)
        } else if out != nil {
            _ = leadPass(c, origin: origin, width: width, theme: t, ctx: nil, out: buttons)
        }
        for r in buttons.regions { out?.add(r.rect, tooltip: r.tooltip, action: r.action, hover: r.hover) }
        return h
    }

    private static func leadPass(_ c: RunCardModel, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let x = origin.x + leadPad, w = width - leadPad * 2
        var y = origin.y + leadPad - 1
        y += drawLeadHeader(c, x: x, y: y, w: w, theme: t, ctx: ctx, out: out)
        let lead = c.lead
        y += 11
        y += drawBadge(c, x: x, y: y, w: w, theme: t, ctx: ctx)
        switch c.phase {
        case .asks:
            if let q = c.question {
                y += 10
                y += drawLeadQuestion(q, c: c, x: x, y: y, w: w, theme: t, ctx: ctx, out: out)
            }
            y += 12
            y += drawLeadMeter(c, compact: true, x: x, y: y, w: w, theme: t, ctx: ctx)
        case .yourTurn:
            if let lead, !lead.rows.isEmpty {
                y += 10
                y += drawLeftRows(lead, x: x, y: y, w: w, theme: t, ctx: ctx)
            }
            y += 12
            y += drawLeadMeter(c, compact: false, x: x, y: y, w: w, theme: t, ctx: ctx)
            y += 12
            y += drawButtons(c, verb: "Reply", x: x, y: y, w: w, theme: t, ctx: ctx, out: out)
        case .working, .settled:
            y += 12
            y += drawLeadMeter(c, compact: false, x: x, y: y, w: w, theme: t, ctx: ctx)
            if let note = lead?.note {
                y += 10
                y += drawNote(note, tone: lead?.noteTone ?? .quiet, x: x, y: y, w: w, theme: t, ctx: ctx)
            }
        }
        return y + leadPad - origin.y
    }

    /// Tile, the name (two lines at most) and where it runs; "↗" to the session on the right.
    static func drawLeadHeader(_ c: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        var right = x + w
        let size = RunPageRenderer.buttonSize
        var open: CGRect?
        if c.actions.openSession {
            let r = CGRect(x: right - size, y: y, width: size, height: size)
            out?.add(r.insetBy(dx: -2, dy: -2), tooltip: c.actions.resume ? "Resume the session" : "Open the session", action: .runButton(c.id, .openSession), hover: 9)
            open = r
            right = r.minX - 8
        }
        let tx = x + leadTile + 10
        let title = RunPageRenderer.clamp(c.title, F.sf(14.5, 650), t.ink, width: right - tx, lineHeight: 18, lines: 2, kern: -0.08)
        let sub = RunCardRenderer.fitParts(c.subtitle, F.sf(11.5, 500), t.muted, width: (title.height > 18 ? x + w : right) - tx)
        let h = max(leadTile, title.height + 2 + 14)
        guard let ctx else { return h }
        RunCardRenderer.drawTile(c, rect: CGRect(x: x, y: y + 1, width: leadTile, height: leadTile), tone: tone(c, t), theme: t, ctx: ctx)
        title.draw(x: tx, top: y - 1.5, in: ctx)
        sub.draw(x: tx, capCenter: y + title.height + 2 + 5.5, in: ctx)
        if let r = open {
            let shape = rounded(r, 8)
            ctx.fill(shape, t.chipFill)
            ctx.innerStroke(shape, t.chipBorder, width: 0.5)
            CanvasControlView.drawSymbol("arrow.up.forward.app", in: CGRect(x: r.midX - 7.5, y: r.midY - 6.75, width: 15, height: 13.5), color: t.ink.fade(0.72),
                                         weight: .semibold, ctx: ctx)
        }
        return h
    }

    /// The state as a pill: a dot and the key in a wash of the state's colour (pearl for your turn),
    /// then how long it's been.
    static func drawBadge(_ c: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let h: CGFloat = 22
        guard let ctx, let lead = c.lead else { return c.lead == nil ? 0 : h }
        let color = keyColor(lead.tone, c, t)
        let label = Text(lead.badge, F.sf(12, 650), lead.tone == .neutral ? t.ink : color)
        let pill = CGRect(x: x, y: y, width: 8 + 7 + 6 + label.width + 10, height: h)
        let shape = rounded(pill, h / 2)
        ctx.fill(shape, lead.tone == .neutral ? t.ink.fade(t.isDark ? 0.10 : 0.07) : color.fade(t.isDark ? 0.15 : 0.11))
        ctx.innerStroke(shape, lead.tone == .neutral ? t.ink.fade(t.isDark ? 0.16 : 0.12) : color.fade(0.3), width: 0.75)
        let dot = CGRect(x: pill.minX + 8, y: pill.midY - 3.5, width: 7, height: 7)
        ctx.withState {
            if lead.tone != .neutral && lead.tone != .quiet { ctx.setShadow(offset: .zero, blur: 6, color: color.cgColor) }
            ctx.fill(CGPath(ellipseIn: dot, transform: nil), lead.tone == .neutral ? t.ink : color)
        }
        label.draw(x: dot.maxX + 6, capCenter: pill.midY, in: ctx)
        if let since = lead.since {
            RunCardRenderer.fit(since, F.sf(11.5, 500, tabular: true), t.muted, width: x + w - pill.maxX - 8).draw(x: pill.maxX + 8, capCenter: pill.midY, in: ctx)
        }
        return h
    }

    /// The question in its own words behind a rose rule, the answers offered, and the buttons
    /// that go to the session.
    static func drawLeadQuestion(_ q: RunQuestionModel, c: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?,
                                 out: RenderOutput?) -> CGFloat {
        let rule: CGFloat = 12
        let text = RunPageRenderer.clamp(q.text, F.sf(13.5, 500), t.ink, width: w - rule, lineHeight: 18.5, lines: 5, kern: -0.05)
        let asker = q.asker.isEmpty ? nil : RunCardRenderer.fit(q.asker, F.sf(11.5, 600), t.rose, width: w - rule)
        var top = y
        let askerTop = top
        if asker != nil { top += 17 }
        let textTop = top
        top += text.height
        var offered: TextBlock?
        if !q.options.isEmpty {
            let s = NSMutableAttributedString(string: "Offered: ", attributes: [.font: F.sf(11.5, 500), .foregroundColor: t.muted])
            s.append(NSAttributedString(string: q.options.joined(separator: " · "), attributes: [.font: F.sf(11.5, 600), .foregroundColor: t.ink.fade(0.78)]))
            offered = TextBlock(s, width: w - rule, lineHeight: 15.5)
            top += 5 + offered!.height
        }
        let ruleBottom = top
        var buttons: [(String, HitRegion.RunButton, RunCardRenderer.PillStyle)] = []
        if c.actions.openSession { buttons.append(("Answer in \(RunPageRenderer.appName(c.provider)) \u{2197}", .openSession, .rose)) }
        if c.actions.copyResume { buttons.append(("Copy resume", .copyResume, .plain)) }
        var rects: [CGRect] = []
        if !buttons.isEmpty {
            top += 11
            var bx = x
            for (label, kind, _) in buttons {
                let r = RunCardRenderer.pillRect(label, x: bx, top: top)
                rects.append(r)
                out?.add(r, tooltip: kind == .openSession ? "Opens the session, where the question is answered" : "Copies a command that resumes the session",
                         action: .runButton(c.id, kind), hover: r.height / 2)
                bx = r.maxX + 8
            }
            top += 26
        }
        guard let ctx else { return top - y }
        ctx.fill(rounded(CGRect(x: x, y: y + 1, width: 2.5, height: ruleBottom - y - 2), 1.25), t.rose)
        asker?.draw(x: x + rule, capCenter: askerTop + 7, in: ctx)
        text.draw(x: x + rule, top: textTop, in: ctx)
        offered?.draw(x: x + rule, top: ruleBottom - offered!.height, in: ctx)
        for (i, (label, _, style)) in buttons.enumerated() { RunCardRenderer.drawPill(label, rect: rects[i], theme: t, ctx: ctx, style: style) }
        return top - y
    }

    /// "WHAT'S LEFT · 3" and up to three of the open tasks, yours first and marked.
    static func drawLeftRows(_ lead: RunLeadModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        var yy = y
        if let title = lead.rowsTitle {
            if let ctx { Text(title.uppercased(), F.sf(9.5, 700, tabular: true), t.muted2, kern: 0.9).draw(x: x, capCenter: yy + 6, in: ctx) }
            yy += 16
        }
        for row in lead.rows {
            let h = RunCardRenderer.rowHeight + (row.detail == nil ? 0 : RunCardRenderer.detailHeight)
            if let ctx { RunCardRenderer.drawRow(row, x: x, y: yy, w: w, theme: t, ctx: ctx) }
            yy += h + 2
        }
        return yy - y
    }

    /// The percent (or agents finished) with its counts, the time on the right, then the task map.
    /// `compact` keeps it to a line and the map, under a question.
    static func drawLeadMeter(_ c: RunCardModel, compact: Bool, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        guard let hero = c.hero else { return 0 }
        let numH: CGFloat = compact ? 16 : 30
        let mapH: CGFloat = 12
        let h = numH + (compact ? 6 : 9) + 14 * (compact ? 0 : 1) + (compact ? 0 : 6) + mapH
        guard let ctx else { return h }
        var yy = y
        if compact {
            let line = Text([Text(hero.number + hero.unit, F.sf(13, 700, tabular: true), t.ink), Text("  " + hero.label, F.sf(11.5, 500, tabular: true), t.muted)])
            line.draw(x: x, capCenter: yy + numH / 2, in: ctx)
            yy += numH + 6
        } else {
            let numFont = F.sf(32, 700, tabular: true)
            let num = Text(hero.number, numFont, t.ink, kern: -1.4)
            let base = baseline(top: yy, font: numFont, lineHeight: numH)
            num.draw(x: x - 1, baseline: base, in: ctx)
            let unitFont = F.sf(14, 650)
            Text(hero.unit, unitFont, t.ink.fade(0.85)).draw(x: x - 1 + num.width + 2, baseline: base - numFont.capHeight + 1 + unitFont.capHeight, in: ctx)
            if let side = hero.side {
                let sf = F.sf(20, 700, tabular: true)
                Text(side, sf, t.ink, kern: -0.6).draw(x: x + w, baseline: base, align: .right, in: ctx)
            }
            yy += numH + 9
            let labelMid = yy + 7
            let caption = hero.sideCaption.map { Text($0, F.sf(11.5, 500, tabular: true), t.muted) }
            caption?.draw(x: x + w, capCenter: labelMid, align: .right, in: ctx)
            RunCardRenderer.fit(hero.label, F.sf(11.5, 500, tabular: true), t.muted, width: w - (caption.map { $0.width + 12 } ?? 0))
                .draw(x: x, capCenter: labelMid, in: ctx)
            yy += 14 + 6
        }
        let track = CGRect(x: x, y: yy, width: w, height: mapH)
        if !c.segments.isEmpty {
            RunPageRenderer.drawThinMap(c.segments, rect: track, theme: t, ctx: ctx)
        } else {
            RunCardRenderer.drawBar(c.bar ?? TaskProgress(done: hero.fraction, inFlight: 0, estimate: hero.fraction),
                                    rect: track.insetBy(dx: 0, dy: 2), theme: t, ctx: ctx)
        }
        return h
    }

    /// Your turn's (and a left run's) ways forward: back to the session, close, a resume command.
    /// `verb` names the first: "Reply" on your turn, "Resume" once the session has ended.
    static func drawButtons(_ c: RunCardModel, verb: String = "Reply", x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?,
                            out: RenderOutput?) -> CGFloat {
        var buttons: [(String, HitRegion.RunButton, RunCardRenderer.PillStyle, String)] = []
        if c.actions.openSession {
            buttons.append(("\(verb) in \(RunPageRenderer.appName(c.provider)) \u{2197}", .openSession, .pearl, "Opens the session to pick it up"))
        }
        if c.actions.close { buttons.append((RunWords.close, .close, .plain, "Closes the run: its open tasks are set aside")) }
        if c.actions.copyResume { buttons.append(("Copy resume", .copyResume, .plain, "Copies a command that resumes the session")) }
        guard !buttons.isEmpty else { return -12 }
        var bx = x
        for (label, kind, style, tip) in buttons {
            let r = RunCardRenderer.pillRect(label, x: bx, top: y)
            // What doesn't fit stays on the run's page and its menu.
            guard r.maxX <= x + w else { break }
            out?.add(r, tooltip: tip, action: .runButton(c.id, kind), hover: r.height / 2)
            if let ctx { RunCardRenderer.drawPill(label, rect: r, theme: t, ctx: ctx, style: style) }
            bx = r.maxX + 8
        }
        return 26
    }

    /// One line under the meter: what it's doing, or the limit's pause in amber with its glyph.
    static func drawNote(_ note: String, tone: RunTone, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let warn = tone == .warn
        let block = RunPageRenderer.clamp(note, F.sf(12, warn ? 600 : 500), warn ? t.amber : t.muted, width: w - (warn ? 16 : 0), lineHeight: 16, lines: 2)
        guard let ctx else { return block.height }
        if warn { Glyph.pause(in: CGRect(x: x, y: y + 3.5, width: 8, height: 9), color: t.amber, ctx: ctx) }
        block.draw(x: x + (warn ? 16 : 0), top: y, in: ctx)
        return block.height
    }

    // MARK: The day's receipt

    /// With nothing live: what the day's runs cost, how long the agents worked, a block per run as
    /// wide as its work, and how they ended.
    static func drawReceipt(_ r: RunDayReceipt, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let x = origin.x + leadPad, w = width - leadPad * 2
        let h: CGFloat = leadPad + 12 + 12 + 34 + 6 + 14 + 12 + 10 + 10 + 14 + leadPad
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: nil, theme: t, ctx: ctx)
        var y = origin.y + leadPad
        Text(r.title.uppercased(), F.sf(9.5, 700, tabular: true), t.muted2, kern: 0.95).draw(x: x, capCenter: y + 6, in: ctx)
        y += 12 + 12
        let bigFont = F.sf(34, 700, tabular: true)
        let base = baseline(top: y, font: bigFont, lineHeight: 34)
        // The cost leads when the runs are priced, with the dollar sign raised; else the time worked.
        let lead = r.cost ?? r.worked
        if lead.hasPrefix("$") {
            let sign = Text("$", F.sf(16, 650), t.ink.fade(0.8))
            sign.draw(x: x, baseline: base - bigFont.capHeight + F.sf(16, 650).capHeight, in: ctx)
            Text(String(lead.dropFirst()), bigFont, t.ink, kern: -1.4).draw(x: x + sign.width + 1, baseline: base, in: ctx)
        } else {
            Text(lead, bigFont, t.ink, kern: -1.4).draw(x: x, baseline: base, in: ctx)
        }
        let rightBig = r.cost != nil ? r.worked : nil
        if let rightBig { Text(rightBig, F.sf(22, 700, tabular: true), t.ink, kern: -0.6).draw(x: x + w, baseline: base, align: .right, in: ctx) }
        y += 34 + 6
        Text(r.cost != nil ? r.costCaption : r.workedCaption, F.sf(11.5, 500), t.muted).draw(x: x, capCenter: y + 7, in: ctx)
        Text(r.cost != nil ? r.workedCaption : r.costCaption, F.sf(11.5, 500), t.muted).draw(x: x + w, capCenter: y + 7, align: .right, in: ctx)
        y += 14 + 12
        drawDayBar(r.segments, rect: CGRect(x: x, y: y, width: w, height: 10), theme: t, ctx: ctx)
        y += 10 + 10
        RunCardRenderer.fit(r.outcomes, F.sf(12, 550, tabular: true), t.ink.fade(0.8), width: w).draw(x: x, capCenter: y + 7, in: ctx)
        return h
    }

    /// A block per run: settled work in pearl, work left open hatched, failures in their colour.
    static func drawDayBar(_ segs: [RunSegment], rect: CGRect, theme t: Theme, ctx: CGContext) {
        guard !segs.isEmpty else { return }
        let gap: CGFloat = 3, minW: CGFloat = 6
        let avail = rect.width - gap * CGFloat(segs.count - 1)
        let spare = max(0, avail - minW * CGFloat(segs.count))
        var x = rect.minX
        for s in segs {
            let bw = avail > minW * CGFloat(segs.count) ? minW + CGFloat(s.weight) * spare : avail / CGFloat(segs.count)
            let shape = rounded(CGRect(x: x, y: rect.minY, width: bw, height: rect.height), rect.height / 2)
            if s.failed {
                ctx.fill(shape, RunCardRenderer.failure(t).fade(0.55))
            } else if s.tone == .quiet {
                ctx.fill(shape, t.ink.fade(t.isDark ? 0.12 : 0.10))
                RunCardRenderer.hatch(shape, color: t.ink.fade(t.isDark ? 0.45 : 0.38), spacing: 3.5, lineWidth: 1, ctx: ctx)
            } else {
                ctx.fillVertical(shape, t.ink.fade(t.isDark ? 0.62 : 0.52), t.ink.fade(t.isDark ? 0.48 : 0.40))
            }
            x += bw + gap
        }
    }

    // MARK: Pieces

    /// The colour a run's state reads in.
    static func tone(_ c: RunCardModel, _ t: Theme) -> NSColor { RunCardRenderer.color(c.tone, t, glyph: c.glyph) }

    /// The colour of a key or badge in `tone`: pearl for neutral, the failure colour for a failure.
    static func keyColor(_ tone: RunTone, _ c: RunCardModel, _ t: Theme) -> NSColor {
        switch tone {
        case .neutral: t.ink.fade(0.82)
        case .quiet: t.muted
        default: RunCardRenderer.color(tone, t, glyph: c.glyph)
        }
    }

    /// A live run's figure: ink, amber when quiet or at a limit.
    static func figureColor(_ c: RunCardModel, _ t: Theme) -> NSColor { c.tone == .warn ? t.amber : t.ink }

    /// The state as a glyph in a tinted disc; a quiet run's is a moon.
    static func drawStateIcon(_ c: RunCardModel, center: CGPoint, theme t: Theme, ctx: CGContext) {
        let tc = tone(c, t)
        let disc = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
        let calm = c.tone == .neutral || c.tone == .quiet
        ctx.fill(CGPath(ellipseIn: disc, transform: nil), (calm ? t.ink : tc).fade(calm ? 0.08 : 0.15))
        if c.glyph == .stale {
            drawMoon(center: center, color: tc, ctx: ctx)
        } else {
            RunCardRenderer.drawGlyph(c.glyph, color: calm ? t.ink.fade(0.72) : tc, center: center, size: 10, ctx: ctx)
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
        let dotColor = c.tone == .neutral ? t.ink.fade(0.85) : tone
        ctx.withState {
            if c.tone != .quiet && c.tone != .neutral { ctx.setShadow(offset: .zero, blur: 5, color: tone.fade(0.8).cgColor) }
            ctx.fill(CGPath(ellipseIn: dot, transform: nil), dotColor)
        }
    }

    /// What the row says, in words, on hover and to VoiceOver.
    static func tooltip(_ c: RunCardModel) -> String {
        var parts = [c.title, c.line.key.isEmpty ? c.stateText : c.line.key]
        if let detail = c.line.detail { parts.append(detail) }
        if c.phase != .settled, let label = c.hero?.label { parts.append(label) }
        if let caption = c.hero?.sideCaption, c.live { parts.append(caption) }
        if let limit = c.page?.limit { parts.append("pauses \(limit.pause) at the 5-hour limit") }
        if let mac = c.mac { parts.append("on \(mac)") }
        parts.append(c.subtitle)
        return parts.joined(separator: " · ")
    }
}
