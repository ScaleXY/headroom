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
        let tone = color(m.tone, t, glyph: m.glyph)

        // Header: tile (or the state glyph on a finished card), title, then the chevron and "···".
        let headH: CGFloat = 20
        let tx = x0 + (m.live && m.provider != nil ? 28 : 20)
        var right = x0 + w
        var menu: CGRect?
        if m.actions.any {
            menu = CGRect(x: right - menuSize + 4, y: y + 10 - menuSize / 2, width: menuSize, height: menuSize)
            right -= menuSize - 4 + 6
        }
        let chevronX = right - 4
        if m.expandable { right -= 8 + 10 }
        if let ctx {
            if m.live, let p = m.provider {
                BrandMark.drawTile(p, in: CGRect(x: x0, y: y, width: 20, height: 20), ctx: ctx)
            } else {
                drawGlyph(m.glyph, color: tone, center: CGPoint(x: x0 + 6, y: y + 10), size: 11, ctx: ctx)
            }
            if m.expandable { drawChevron(up: m.expanded, center: CGPoint(x: chevronX, y: y + 10), color: t.muted, ctx: ctx) }
            if let menu { drawMenuButton(menu, theme: t, ctx: ctx) }
            fit(m.title, F.sf(m.live ? 14 : 13, 650), m.live ? t.ink : t.ink.fade(0.85), width: right - tx, kern: -0.07)
                .draw(x: tx, capCenter: y + 10, in: ctx)
        }
        y += headH + 3

        // Subtitle; a live card adds its working time, a finished one its state on the right.
        let capsule = stateCapsule(m, theme: t)
        if m.live {
            if let ctx {
                let elapsed = m.elapsed.map { Text(" · " + $0, F.sf(11.5, 600, tabular: true), t.ink.fade(0.66)) }
                // Working time beats "updated 2m ago": that part goes first when both don't fit.
                let room = x0 + w - tx - (elapsed?.width ?? 0)
                var subtitle = m.subtitle
                if elapsed != nil, Text(subtitle, F.sf(11.5, 500), t.muted).width > room, let cut = subtitle.range(of: " · ", options: .backwards) {
                    subtitle = String(subtitle[..<cut.lowerBound])
                }
                let sub = fit(subtitle, F.sf(11.5, 500), t.muted, width: room)
                sub.draw(x: tx, capCenter: y + 6, in: ctx)
                elapsed?.draw(x: tx + sub.width, capCenter: y + 6, in: ctx)
            }
            y += 13
        } else {
            y += 2
            if let ctx {
                capsule.draw(right: x0 + w, mid: y + 6, ctx)
                fit(m.subtitle, F.sf(11.5, 500), t.muted, width: x0 + w - capsule.width - 10 - tx).draw(x: tx, capCenter: y + 6, in: ctx)
            }
            y += 14
        }
        if m.expandable {
            out?.add(CGRect(x: origin.x, y: origin.y, width: width, height: y - origin.y + 4),
                     tooltip: m.expanded ? "Show fewer tasks" : "Show every task", action: .toggleRun(m.id))
        }
        if let menu { out?.add(menu.insetBy(dx: -3, dy: -3), tooltip: "More", action: .runMenu(m.id)) }

        if m.live {
            // What it's asking leads the card.
            if let q = m.question {
                y += 12
                y += drawQuestion(q, id: m.id, actions: m.actions, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
            }
            y += 12
            if m.declared {
                if let ctx {
                    capsule.draw(right: x0 + w, mid: y + 11, ctx)
                    let big = Text(m.headline, F.sf(24, 700, tabular: true), t.ink, kern: -0.7)
                    let b = y + 19
                    big.draw(x: x0 - 0.5, baseline: b, in: ctx)
                    let ex = x0 + big.width + 7
                    let room = x0 + w - capsule.width - 10 - ex
                    // The counts give way to the state: shortened first, then left out.
                    let options = m.counts.map { c in [c, String(c.split(separator: "·").first ?? "").trimmingCharacters(in: .whitespaces)] } ?? ["done"]
                    if let c = options.map({ Text($0, F.sf(12.5, 600, tabular: true), t.muted) }).first(where: { $0.width <= room }) {
                        c.draw(x: ex, baseline: b, in: ctx)
                    }
                }
                y += 24 + 7
                if !m.segments.isEmpty {
                    if let ctx { drawMap(m.segments, rect: CGRect(x: x0, y: y, width: w, height: 8), theme: t, ctx: ctx) }
                    y += 8 + (m.segments.contains(where: \.critical) ? 4 : 0)
                } else {
                    if let bar = m.bar, let ctx { drawBar(bar, rect: CGRect(x: x0, y: y, width: w, height: 7), theme: t, ctx: ctx) }
                    y += 7
                }
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
            if let tl = m.timeline {
                y += 14
                y += drawTimeline(tl, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
        } else if let rc = m.receipt {
            y += 10
            y += drawReceipt(rc, x: x0, y: y, w: w, theme: t, ctx: ctx)
        } else {
            y += 4
            if let ctx {
                let line = ([m.declared ? m.headline + " done" : m.headline] + m.figures).joined(separator: " · ")
                fit(line, F.sf(11.5, 500, tabular: true), t.muted, width: x0 + w - tx).draw(x: tx, capCenter: y + 6, in: ctx)
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
            y += m.live ? 11 : 9
            if let ctx { ctx.fill(CGPath(rect: CGRect(x: x0, y: y, width: w, height: 0.5), transform: nil), t.separator) }
            y += 4
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
            y += 2
        } else {
            y += 4
        }
        return y + padBottom - origin.y
    }

    // MARK: Question

    /// The question block: who is asking, the question in full, the answers offered, and the
    /// buttons that take you to the session. Returns its height.
    static func drawQuestion(_ q: RunQuestionModel, id: String, actions: RunActionSet, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme,
                             ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let pad: CGFloat = 12, inner = w - pad * 2
        let text = TextBlock(q.text, F.sf(13, 550), t.ink, width: inner, lineHeight: 17.5, kern: -0.08)
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
        let askerTop = y + pad, textTop = askerTop + 12 + 7
        let chipsTop = textTop + text.height + 9
        let buttonsTop = (chips.isEmpty ? textTop + text.height : chipsTop + chipsH) + 12
        let h = (buttons.isEmpty ? (chips.isEmpty ? textTop + text.height : chipsTop + chipsH) : buttonsTop + 26) + pad - y
        var bx = x + pad
        var rects: [CGRect] = []
        for (label, kind) in buttons {
            let r = pillRect(label, x: bx, top: buttonsTop)
            rects.append(r)
            out?.add(r, action: .runButton(id, kind))
            bx = r.maxX + 8
        }
        guard let ctx else { return h }
        let rose = t.rose
        let panel = rounded(CGRect(x: x, y: y, width: w, height: h), 12)
        ctx.fill(panel, rose.fade(t.isDark ? 0.11 : 0.065))
        ctx.innerStroke(panel, rose.fade(t.isDark ? 0.30 : 0.22), width: 0.75)
        drawGlyph(.needsInput, color: rose, center: CGPoint(x: x + pad + 5.5, y: askerTop + 6), size: 11, ctx: ctx)
        fit(q.asker, F.sf(11.5, 650), rose, width: inner - 16).draw(x: x + pad + 16, capCenter: askerTop + 6, in: ctx)
        text.draw(x: x + pad, top: textTop, in: ctx)
        for (label, r) in chips {
            let shape = rounded(r.offsetBy(dx: x + pad, dy: chipsTop), chipH / 2)
            ctx.fill(shape, t.isDark ? white(0.07) : white(0.75))
            ctx.innerStroke(shape, rose.fade(t.isDark ? 0.34 : 0.26), width: 0.75)
            label.draw(x: shape.boundingBox.midX, capCenter: shape.boundingBox.midY, align: .center, in: ctx)
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

    /// One block per counted task, as wide as its share: closed solid, under way filled as far as
    /// it has got over a wash of its colour, untouched an empty slot; failed hatched in vermilion;
    /// a short pearl rule under each must-have.
    static func drawMap(_ segs: [RunSegment], rect r: CGRect, theme t: Theme, ctx: CGContext) {
        let n = segs.count
        let gap: CGFloat = n > 24 ? 1.5 : 2.5, minW: CGFloat = 3
        let avail = r.width - gap * CGFloat(n - 1)
        let spare = max(0, avail - minW * CGFloat(n))
        let azure = t.pacing(.plenty)
        let pearl = t.isDark ? white(0.8) : rgb(0x50535B)
        var x = r.minX
        for (i, s) in segs.enumerated() {
            let bw = avail > minW * CGFloat(n) ? minW + CGFloat(s.weight) * spare : avail / CGFloat(n)
            let b = CGRect(x: x, y: r.minY, width: bw, height: r.height)
            let shape = rounded(b, left: i == 0 ? r.height / 2 : 2, right: i == n - 1 ? r.height / 2 : 2)
            ctx.fill(shape, t.meterTrack)
            if t.isDark { ctx.innerStroke(shape, t.meterTrackBorder, width: 0.5) }
            let f = CGFloat(min(max(s.fill, 0), 1))
            if s.failed {
                let c = failure(t)
                ctx.fill(shape, c.fade(0.5))
                hatch(shape, color: c, ctx: ctx)
            } else {
                let (solid, wash): (NSColor?, NSColor?) = switch s.tone {
                case .progress: (nil, azure.bottom.fade(t.isDark ? 0.30 : 0.2))
                case .alert: (t.rose, t.rose.fade(0.24))
                case .warn: (t.amber, t.amber.fade(0.22))
                case .neutral: (t.ink.fade(0.5), t.ink.fade(0.12))
                case .quiet: (t.muted.fade(0.6), nil)
                }
                ctx.withState {
                    ctx.addPath(shape); ctx.clip()
                    if f < 1, let wash { ctx.fill(CGPath(rect: b, transform: nil), wash) }
                    if f > 0 {
                        let fr = CGRect(x: b.minX, y: b.minY, width: max(b.width * f, 2), height: b.height)
                        if let solid { ctx.fill(CGPath(rect: fr, transform: nil), solid) } else { ctx.fillVertical(CGPath(rect: fr, transform: nil), azure.top, azure.bottom) }
                    }
                }
            }
            if s.critical {
                let tw = max(4, min(bw - 4, 14))
                ctx.fill(rounded(CGRect(x: b.midX - tw / 2, y: r.maxY + 2.5, width: tw, height: 1.75), 0.875), pearl)
            }
            x += bw + gap
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

    /// Working, paused at the window, working again after the reset, done: a track with labelled
    /// ticks and the note beneath. Returns its height.
    static func drawTimeline(_ tl: RunTimelineModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let trackH: CGFloat = 8, labelsTop = y + trackH + 7
        let note = tl.note.map { TextBlock($0, F.sf(11, 500), t.muted, width: w, lineHeight: 15) }
        let h = trackH + 7 + 12 + 13 + (note.map { 9 + $0.height } ?? 0)
        guard let ctx else { return h }
        let track = CGRect(x: x, y: y, width: w, height: trackH)
        let shape = rounded(track, trackH / 2)
        ctx.fill(shape, t.meterTrack)
        let azure = t.pacing(.plenty)
        ctx.withState {
            ctx.addPath(shape); ctx.clip()
            for s in tl.spans where s.end > s.start {
                let r = CGRect(x: x + w * CGFloat(s.start), y: y, width: w * CGFloat(s.end - s.start), height: trackH)
                switch s.kind {
                case .working:
                    ctx.fillVertical(CGPath(rect: r.insetBy(dx: 0.75, dy: 0), transform: nil), azure.top, azure.bottom)
                case .paused:
                    let p = CGPath(rect: r.insetBy(dx: 0.75, dy: 0), transform: nil)
                    ctx.fill(p, t.amber.fade(0.16))
                    hatch(p, color: t.amber.fade(0.6), spacing: 3.2, lineWidth: 1, ctx: ctx)
                }
            }
        }
        // Labels: "now" left, "done" right, the rest centred on their tick, nudged apart.
        struct Label { var tick: RunTimelineModel.Tick; var label: Text; var time: Text; var left: CGFloat; var width: CGFloat; var shown = true }
        var labels: [Label] = tl.ticks.sorted { $0.at < $1.at }.map { tick in
            let l = Text(tick.label, F.sf(10.5, tick.strong ? 650 : 500), tick.strong ? t.ink.fade(0.9) : t.muted)
            let tm = Text(tick.time, F.sf(10.5, 500, tabular: true), t.muted2)
            let lw = max(l.width, tm.width)
            let cx = x + w * CGFloat(tick.at)
            return Label(tick: tick, label: l, time: tm, left: min(max(cx - lw / 2, x), x + w - lw), width: lw)
        }
        let space: CGFloat = 8
        // Pull labels left from the right edge first, so a label crowded by "done" moves rather than goes.
        for i in labels.indices.reversed().dropFirst() {
            let next = labels[i + 1].left
            if labels[i].left + labels[i].width + space > next { labels[i].left = max(x, next - space - labels[i].width) }
        }
        for i in labels.indices.dropFirst() {
            guard let prev = labels[..<i].lastIndex(where: \.shown) else { continue }
            let prevRight = labels[prev].left + labels[prev].width
            if labels[i].left < prevRight + space {
                labels[i].left = prevRight + space
                if labels[i].left + labels[i].width > x + w {
                    // No room: the weaker of the two keeps its tick but loses its words.
                    if labels[i].tick.strong && !labels[prev].tick.strong { labels[prev].shown = false; labels[i].left = x + w - labels[i].width }
                    else { labels[i].shown = false }
                }
            }
        }
        for l in labels {
            let cx = min(max(x + w * CGFloat(l.tick.at), x + 1), x + w - 1)
            let mark = CGMutablePath(); mark.move(to: CGPoint(x: cx, y: y + trackH + 1.5)); mark.addLine(to: CGPoint(x: cx, y: y + trackH + 5))
            ctx.stroke(mark, l.tick.strong ? t.ink.fade(0.55) : t.muted2, width: 1, cap: .round)
            guard l.shown else { continue }
            l.label.draw(x: l.left, capCenter: labelsTop + 6, in: ctx)
            l.time.draw(x: l.left, capCenter: labelsTop + 19, in: ctx)
        }
        note?.draw(x: x, top: labelsTop + 25 + 9, in: ctx)
        return h
    }

    // MARK: Receipt

    /// Three figures (start to finish, tokens and cost, tasks), where the time went, and the footnote.
    static func drawReceipt(_ rc: RunReceiptModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let tokens: String = rc.cost.map { "tokens · " + $0 } ?? "tokens"
        let cols: [(String, String)] = [(rc.duration, "start to finish"), (rc.tokens, tokens), (rc.tasks, rc.tasksNote)]
        let colW = w / 3
        let captions = cols.map { TextBlock($0.1, F.sf(10.5, 500), t.muted, width: colW - 20, lineHeight: 13) }
        let captionH: CGFloat = captions.map(\.height).max() ?? 13
        let tileH: CGFloat = 9 + 17 + 4 + captionH + 9
        var h = tileH
        let parts = splitParts(rc.time, theme: t)
        let legendFont = F.sf(10.5, 500, tabular: true)
        var legend: [(Text, NSColor, CGPoint)] = []
        var legendH: CGFloat = 0
        if !parts.isEmpty {
            h += 10 + 6 + 8
            var lx: CGFloat = 0, ly: CGFloat = 0
            for p in parts {
                let label = Text(p.label + " " + RunsPresenter.duration(p.seconds), legendFont, t.muted)
                let iw = 6 + 5 + label.width
                if lx > 0, lx + iw > w { lx = 0; ly += 15 }
                legend.append((label, p.color, CGPoint(x: lx, y: ly)))
                lx += iw + 12
            }
            legendH = ly + 13
            h += legendH
        }
        let foot = rc.footnote.map { TextBlock($0, F.sf(10.5, 500), t.muted2, width: w, lineHeight: 14) }
        if let foot { h += 7 + foot.height }
        guard let ctx else { return h }

        let tile = CGRect(x: x, y: y, width: w, height: tileH)
        ctx.fill(rounded(tile, 10), t.isDark ? white(0.035) : white(0.7))
        ctx.innerStroke(rounded(tile, 10), t.isDark ? white(0.06) : black(0.05), width: 0.5)
        for (i, c) in cols.enumerated() {
            let cx = x + colW * CGFloat(i) + 10
            if i > 0 { ctx.fill(CGPath(rect: CGRect(x: x + colW * CGFloat(i), y: y + 9, width: 0.5, height: tileH - 18), transform: nil), t.separator) }
            fit(c.0, F.sf(15, 680, tabular: true), t.ink, width: colW - 20, kern: -0.3).draw(x: cx, capCenter: y + 9 + 8, in: ctx)
            captions[i].draw(x: cx, top: y + 9 + 17 + 4, in: ctx)
        }
        var yy = y + tileH
        if !parts.isEmpty {
            yy += 10
            let total = parts.reduce(0) { $0 + $1.seconds }
            let gap: CGFloat = 2, avail = w - gap * CGFloat(parts.count - 1)
            var bx = x
            for (i, p) in parts.enumerated() {
                let bw = max(3, avail * CGFloat(p.seconds / total))
                let r = CGRect(x: bx, y: yy, width: min(bw, x + w - bx), height: 6)
                ctx.fill(rounded(r, left: i == 0 ? 3 : 1.5, right: i == parts.count - 1 ? 3 : 1.5), p.color)
                bx += bw + gap
            }
            yy += 6 + 8
            for (label, c, at) in legend {
                ctx.fill(CGPath(ellipseIn: CGRect(x: x + at.x, y: yy + at.y + 6.5 - 3, width: 6, height: 6), transform: nil), c)
                label.draw(x: x + at.x + 11, capCenter: yy + at.y + 6.5, in: ctx)
            }
            yy += legendH
        }
        if let foot { foot.draw(x: x, top: yy + 7, in: ctx) }
        return h
    }

    /// The parts of the run's time worth a mark: working in graphite (a finished run isn't
    /// progress, so never azure), waiting on you in rose, on a limit in amber, idle faint.
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
