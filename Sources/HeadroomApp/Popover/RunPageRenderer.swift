import AppKit
import HeadroomKit
import HeadroomPresent

/// A run's own page, opened from the Runs list, in the style Settings picks.
///
/// Briefing: one status line (or the question, while it asks), the percent beside its facts, the
/// task meter with a diamond under each must-have, the limit as one amber line, then the open tasks
/// under their parents. Lanes: the same header and question, then the run as a time chart, a lane
/// per open task, with now, the limit's pause and the forecast finish on one axis, then the tasks.
/// A finished run always reads as a Briefing: its outcome, what it took, where the time went, and
/// what didn't finish.
@MainActor
enum RunPageRenderer {
    static let padX: CGFloat = 14, padTop: CGFloat = 13, padBottom: CGFloat = 12
    static let tileSize: CGFloat = 24, buttonSize: CGFloat = 26
    static let laneHeight: CGFloat = 34

    /// The run as one card. Returns the height.
    @discardableResult
    static func draw(_ card: RunCardModel, style: RunPageStyle, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?,
                     out: RenderOutput? = nil) -> CGFloat {
        let lanes = style == .lanes && card.live && card.page?.lanes != nil
        let h = pass(card, lanes: lanes, origin: origin, width: width, theme: t, ctx: nil, out: nil)
        guard let ctx else {
            // Measuring with regions wanted (tests, hit-testing without drawing).
            if out != nil { _ = pass(card, lanes: lanes, origin: origin, width: width, theme: t, ctx: nil, out: out) }
            return h
        }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: card.provider, theme: t, ctx: ctx)
        _ = pass(card, lanes: lanes, origin: origin, width: width, theme: t, ctx: ctx, out: out)
        return h
    }

    private static func pass(_ m: RunCardModel, lanes: Bool, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?,
                             out: RenderOutput?) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        var y = origin.y + padTop
        let tone = RunCardRenderer.color(m.tone, t, glyph: m.glyph)
        let page = m.page

        y += drawHeader(m, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)

        if m.live {
            // What it's asking leads; otherwise one line of what's going on.
            if let q = m.question {
                y += 12
                y += drawQuestion(q, m: m, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
            } else if let status = page?.status {
                y += 11
                y += drawStatus(status, m: m, tone: tone, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
            if lanes, let page, let model = page.lanes {
                y += 12
                y += drawLanesSummary(m, page: page, x: x0, y: y, w: w, theme: t, ctx: ctx)
                y += 14
                y += drawLanes(model, page: page, x: x0, y: y, w: w, theme: t, ctx: ctx)
            } else {
                if let hero = m.hero {
                    y += 13
                    y += drawHero(hero, facts: page?.facts ?? [], x: x0, y: y, w: w, theme: t, ctx: ctx)
                }
                y += 12
                y += drawMeter(m, x: x0, y: y, w: w, theme: t, ctx: ctx)
                if let limit = page?.limit {
                    y += 10
                    y += drawLimit(limit, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
                }
            }
            if m.phase == .yourTurn {
                y += 12
                y += RunListRenderer.drawButtons(m, verb: "Reply", x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
            }
            if let warning = m.warning, page?.limit == nil {
                y += 10
                y += RunCardRenderer.drawCallout(warning, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
        } else {
            if let status = page?.status {
                y += 11
                y += drawStatus(status, m: m, tone: tone, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
            if let facts = page?.facts, !facts.isEmpty {
                y += 5
                y += drawFactsLine(facts, x: x0, y: y, w: w, theme: t, ctx: ctx)
            }
            // Left with work open: how far it got, and both ways forward.
            if m.actions.resume, m.actions.openSession || m.actions.close {
                y += 12
                y += drawMeter(m, x: x0, y: y, w: w, theme: t, ctx: ctx)
                y += 12
                y += RunListRenderer.drawButtons(m, verb: "Resume", x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
            }
            if let rc = m.receipt {
                let parts = RunCardRenderer.splitParts(rc.time, theme: t)
                if !parts.isEmpty {
                    y += 12
                    y += drawSplitCaption(parts, open: rc.open, x: x0, y: y, w: w, theme: t, ctx: ctx)
                    y += 6
                    y += drawSplit(parts, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out)
                }
            }
            if let secondary = m.verdict?.secondary {
                let block = TextBlock(secondary, F.sf(12, 500), t.muted, width: w, lineHeight: 16)
                y += 9
                if let ctx { block.draw(x: x0, top: y, in: ctx) }
                y += block.height
            }
        }

        if let page { y += drawTasks(page, m: m, x: x0, y: y, w: w, theme: t, ctx: ctx, out: out) }
        return y + padBottom - origin.y
    }

    // MARK: Header

    /// Tile, title (two lines at most), subtitle; "↗" to the session and "···" on the right.
    static func drawHeader(_ m: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        var right = x + w
        var buttons: [(CGRect, String)] = []
        if m.actions.any {
            let r = CGRect(x: right - buttonSize, y: y - 1, width: buttonSize, height: buttonSize)
            out?.add(r.insetBy(dx: -2, dy: -2), tooltip: "More", action: .runMenu(m.id), hover: 9)
            buttons.append((r, "ellipsis"))
            right = r.minX - 4
        }
        if m.actions.openSession {
            let r = CGRect(x: right - buttonSize, y: y - 1, width: buttonSize, height: buttonSize)
            out?.add(r.insetBy(dx: -2, dy: -2), tooltip: "Open session", action: .runButton(m.id, .openSession), hover: 9)
            buttons.append((r, "arrow.up.forward.app"))
            right = r.minX
        }
        if !buttons.isEmpty { right -= 8 }
        let tx = x + tileSize + 10
        let title = clamp(m.title, F.sf(14.5, 650), t.ink, width: right - tx, lineHeight: 18, lines: 2, kern: -0.08)
        // Under the buttons only when the title took two lines.
        let subWidth = (title.height > 18 ? x + w : right) - tx
        let sub = RunCardRenderer.fitParts(m.subtitle, F.sf(11.5, 500), t.muted, width: subWidth)
        let h = max(tileSize, title.height + 2 + 14)
        guard let ctx else { return h }
        let tone = RunCardRenderer.color(m.tone, t, glyph: m.glyph)
        RunCardRenderer.drawTile(m, rect: CGRect(x: x, y: y, width: tileSize, height: tileSize), tone: tone, theme: t, ctx: ctx)
        title.draw(x: tx, top: y - 1.5, in: ctx)
        sub.draw(x: tx, capCenter: y + title.height + 2 + 5.5, in: ctx)
        for (r, symbol) in buttons {
            let shape = rounded(r, 8)
            ctx.fill(shape, t.chipFill)
            ctx.innerStroke(shape, t.chipBorder, width: 0.5)
            let s: CGFloat = symbol == "ellipsis" ? 4.5 : 13.5
            CanvasControlView.drawSymbol(symbol, in: CGRect(x: r.midX - 7.5, y: r.midY - s / 2, width: 15, height: s), color: t.ink.fade(0.72),
                                         weight: .semibold, ctx: ctx)
        }
        return h
    }

    /// `s` wrapped to at most `lines` lines, the last cut with an ellipsis.
    static func clamp(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat, lineHeight: CGFloat, lines: Int, kern: CGFloat = 0) -> TextBlock {
        let max = lineHeight * CGFloat(lines) + 0.5
        let full = TextBlock(s, font, color, width: width, lineHeight: lineHeight, kern: kern)
        guard full.height > max else { return full }
        let chars = Array(s)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let cut = String(chars[..<mid]).trimmingCharacters(in: .whitespaces) + "…"
            if TextBlock(cut, font, color, width: width, lineHeight: lineHeight, kern: kern).height <= max { lo = mid } else { hi = mid - 1 }
        }
        return TextBlock(String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…", font, color, width: width, lineHeight: lineHeight, kern: kern)
    }

    // MARK: Status

    /// One line: a glowing dot (live) or the outcome's glyph (finished), the key in the state's
    /// colour, and what it's about.
    static func drawStatus(_ s: RunStatusModel, m: RunCardModel, tone: NSColor, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme,
                           ctx: CGContext?) -> CGFloat {
        let h: CGFloat = 18
        guard let ctx else { return h }
        let mid = y + h / 2
        let keyColor = m.tone == .quiet ? t.muted : tone
        var kx = x
        if m.live {
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: x + 0.5, y: mid - 3.5, width: 7, height: 7))
            ctx.withState {
                if m.tone != .quiet && m.tone != .neutral { ctx.setShadow(offset: .zero, blur: 8, color: tone.cgColor) }
                ctx.fill(dot, keyColor)
            }
            kx += 7 + 8
        } else {
            RunCardRenderer.drawGlyph(m.glyph, color: keyColor, center: CGPoint(x: x + 5.5, y: mid), size: 11, ctx: ctx)
            kx += 11 + 7
        }
        let key = Text(s.key, F.sf(12.5, 650), keyColor)
        key.draw(x: kx, capCenter: mid, in: ctx)
        if let detail = s.detail, !detail.isEmpty {
            let dx = kx + key.width + 5
            RunCardRenderer.fit("· " + detail, F.sf(12.5, 500), t.muted, width: x + w - dx).draw(x: dx, capCenter: mid, in: ctx)
        }
        return h
    }

    // MARK: Question

    /// What it's asking, in a rose wash: who asks, the question, the answers offered as plain text
    /// (they're given in the session), and the buttons that go there.
    static func drawQuestion(_ q: RunQuestionModel, m: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?,
                             out: RenderOutput?) -> CGFloat {
        let pad: CGFloat = 11, inner = w - pad * 2
        let text = TextBlock(q.text, F.sf(13.5, 500), t.ink, width: inner, lineHeight: 18.5, kern: -0.05)
        var offered: TextBlock?
        if !q.options.isEmpty {
            let s = NSMutableAttributedString(string: "Offered: ", attributes: [.font: F.sf(11.5, 500), .foregroundColor: t.muted])
            s.append(NSAttributedString(string: q.options.joined(separator: " · "), attributes: [.font: F.sf(11.5, 600), .foregroundColor: t.ink.fade(0.78)]))
            offered = TextBlock(s, width: inner, lineHeight: 15.5)
        }
        var buttons: [(String, HitRegion.RunButton)] = []
        if m.actions.openSession { buttons.append(("Answer in \(appName(m.provider)) \u{2197}", .openSession)) }
        if m.actions.copyResume { buttons.append(("Copy resume", .copyResume)) }
        let headTop = y + 10
        let textTop = headTop + 16 + 6
        var bottom = textTop + text.height
        let offeredTop = bottom + 6
        if let offered { bottom = offeredTop + offered.height }
        let buttonsTop = bottom + 11
        if !buttons.isEmpty { bottom = buttonsTop + 26 }
        let h = bottom + pad - y
        var bx = x + pad
        var rects: [CGRect] = []
        for (label, kind) in buttons {
            let r = RunCardRenderer.pillRect(label, x: bx, top: buttonsTop)
            rects.append(r)
            out?.add(r, tooltip: kind == .openSession ? "Opens the session, where the question is answered" : "Copies a command that resumes the session",
                     action: .runButton(m.id, kind), hover: r.height / 2)
            bx = r.maxX + 8
        }
        guard let ctx else { return h }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let shape = rounded(rect, 13)
        ctx.fillLinear(shape, [rgb(0xEE3459).fade(t.isDark ? 0.16 : 0.11), rgb(0xEE3459).fade(t.isDark ? 0.06 : 0.035)],
                       from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.innerStroke(shape, rgb(0xFF6982).fade(t.isDark ? 0.32 : 0.42), width: 0.75)
        RunCardRenderer.drawGlyph(.needsInput, color: t.rose, center: CGPoint(x: x + pad + 6, y: headTop + 8), size: 12, ctx: ctx)
        // Another Mac's question without its wording names nobody (and an empty line can't be drawn).
        RunCardRenderer.fit(q.asker.isEmpty ? RunWords.needsInput : q.asker, F.sf(12, 650), t.rose, width: inner - 20)
            .draw(x: x + pad + 18, capCenter: headTop + 8, in: ctx)
        text.draw(x: x + pad, top: textTop, in: ctx)
        offered?.draw(x: x + pad, top: offeredTop, in: ctx)
        for (i, (label, _)) in buttons.enumerated() {
            RunCardRenderer.drawPill(label, rect: rects[i], theme: t, ctx: ctx, style: i == 0 && buttons[0].1 == .openSession ? .rose : .plain)
        }
        return h
    }

    static func appName(_ p: Provider?) -> String {
        switch p {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case nil: "session"
        }
    }

    // MARK: Hero

    /// The percent at 40pt with its unit raised and its label under; the facts beside it on the
    /// right as a label · value grid.
    static func drawHero(_ h: RunHeroModel, facts: [RunFactModel], x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let numH: CGFloat = 34, labelGap: CGFloat = 7, labelH: CGFloat = 14, factH: CGFloat = 16.5
        let height = max(numH + labelGap + labelH, CGFloat(facts.count) * factH)
        guard let ctx else { return height }
        let numFont = F.sf(40, 700, tabular: true)
        let num = Text(h.number, numFont, t.ink, kern: -1.8)
        let numBase = baseline(top: y, font: numFont, lineHeight: numH)
        num.draw(x: x - 1, baseline: numBase, in: ctx)
        let unitFont = F.sf(17, 650)
        let unit = Text(h.unit, unitFont, t.ink.fade(0.85))
        unit.draw(x: x - 1 + num.width + 3, baseline: numBase - numFont.capHeight + 2 + unitFont.capHeight, in: ctx)
        // Facts: values right-aligned, labels right-aligned before the widest value.
        let valueFont = F.sf(11.5, 650, tabular: true), labelFont = F.sf(11, 500)
        let values = facts.map { Text($0.value, valueFont, t.ink) }
        let valueW = zip(facts, values).map { $1.width + ($0.mustHave ? 12 : 0) }.max() ?? 0
        let labelsW = facts.map { Text($0.label, labelFont, t.muted2).width }.max() ?? 0
        let block = CGFloat(facts.count) * factH
        var fy = y + max(0, (numH + labelGap + labelH - block) / 2)
        for (f, v) in zip(facts, values) {
            let mid = fy + factH / 2
            v.draw(x: x + w, capCenter: mid, align: .right, in: ctx)
            if f.mustHave { drawDiamond(center: CGPoint(x: x + w - v.width - 7, y: mid), size: 8, color: t.ink.fade(0.8), filled: true, ctx: ctx) }
            Text(f.label, labelFont, t.muted2).draw(x: x + w - valueW - 8, capCenter: mid, align: .right, in: ctx)
            fy += factH
        }
        let labelRoom = w - (facts.isEmpty ? 0 : valueW + 8 + labelsW + 14)
        RunCardRenderer.fit(countsOnly(h.label), F.sf(11.5, 500, tabular: true), t.muted, width: max(labelRoom, 60))
            .draw(x: x, capCenter: y + numH + labelGap + labelH / 2, in: ctx)
        return height
    }

    // MARK: Meter

    static let trackHeight: CGFloat = 16

    /// The task map at 10pt cells with a diamond under each must-have; a plain bar without a map.
    static func drawMeter(_ m: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let track = CGRect(x: x, y: y, width: w, height: trackHeight)
        if !m.segments.isEmpty {
            let musts = m.segments.contains(where: \.critical)
            let h = trackHeight + (musts ? 4 + 8 : 0)
            guard let ctx else { return h }
            drawThinMap(m.segments, rect: track, theme: t, ctx: ctx)
            if musts {
                for (s, cx) in zip(m.segments, RunCardRenderer.centers(m.segments, track: track)) where s.critical {
                    let done = s.fill >= 1 && !s.failed
                    drawDiamond(center: CGPoint(x: cx, y: y + trackHeight + 4 + 4), size: 7.5,
                                color: done ? t.ink.fade(0.82) : t.muted2, filled: done, ctx: ctx)
                }
            }
            return h
        }
        let h: CGFloat = 8
        guard let ctx else { return h }
        let f = m.hero?.fraction ?? 0
        RunCardRenderer.drawBar(m.bar ?? TaskProgress(done: f, inFlight: 0, estimate: f), rect: CGRect(x: x, y: y, width: w, height: h), theme: t, ctx: ctx)
        return h
    }

    /// `RunCardRenderer.drawMap` with 10pt cells in a 16pt track.
    static func drawThinMap(_ segs: [RunSegment], rect: CGRect, theme t: Theme, ctx: CGContext) {
        let track = rounded(rect, 8)
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
        let endR: CGFloat = 5, innerR: CGFloat = n > 12 ? 2 : 3
        var x = inner.minX
        for (i, s) in segs.enumerated() {
            let bw = avail > minW * CGFloat(n) ? minW + CGFloat(s.weight) * spare : avail / CGFloat(n)
            let r = CGRect(x: x, y: inner.minY, width: bw, height: inner.height)
            let left = i == 0 ? endR : innerR, right = i == n - 1 ? endR : innerR
            let shape = rounded(r, left: left, right: right)
            ctx.fill(shape, t.meterEmpty)
            let f = CGFloat(min(max(s.fill, 0), 1))
            if s.failed {
                let c = RunCardRenderer.failure(t)
                ctx.fill(shape, c.fade(0.35))
                RunCardRenderer.hatch(shape, color: c.fade(0.85), spacing: 3, lineWidth: 1, ctx: ctx)
            } else if f > 0 {
                let pc: PacingColors = switch s.tone {
                case .alert: t.pacing(.veryTight)
                case .warn: t.pacing(.tight)
                default: t.pacing(.plenty)
                }
                let colors: (top: NSColor, bottom: NSColor, glow: NSColor) = s.tone == .quiet
                    ? (t.muted.fade(0.7), t.muted.fade(0.5), .clear) : (pc.top, pc.bottom, pc.glow)
                if f >= 1 {
                    if s.tone != .quiet { ctx.glow(shape, color: colors.glow, blur: 8, base: colors.bottom) }
                    ctx.fillVertical(shape, colors.top, colors.bottom)
                    ctx.withState {
                        ctx.addPath(shape); ctx.clip()
                        ctx.fill(CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: 0.75), transform: nil), white(0.5))
                    }
                } else {
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

    /// The must-have mark: a small diamond.
    static func drawDiamond(center c: CGPoint, size s: CGFloat, color: NSColor, filled: Bool, ctx: CGContext) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - s / 2))
        p.addLine(to: CGPoint(x: c.x + s * 0.4, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y + s / 2))
        p.addLine(to: CGPoint(x: c.x - s * 0.4, y: c.y))
        p.closeSubpath()
        if filled { ctx.fill(p, color) } else { ctx.stroke(p, color, width: 1.1, join: .round) }
    }

    // MARK: Limit

    /// "Pauses 10:30 AM at the 5-hour limit · resumes 11:20 AM" in one amber line; the forecast's
    /// reasoning as its tooltip.
    static func drawLimit(_ l: RunLimitModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let h: CGFloat = 30
        let rect = CGRect(x: x, y: y, width: w, height: h)
        out?.add(rect, tooltip: l.note.map { $0 + "." } ?? "Forecast to pause at the 5-hour limit before it finishes.")
        guard let ctx else { return h }
        let shape = rounded(rect, 10)
        ctx.fill(shape, t.amber.fade(t.isDark ? 0.09 : 0.08))
        ctx.innerStroke(shape, t.amber.fade(t.isDark ? 0.30 : 0.34), width: 0.5)
        Glyph.pause(in: CGRect(x: x + 11, y: rect.midY - 5, width: 9, height: 10), color: t.amber, ctx: ctx)
        let tx = x + 11 + 9 + 8, room = x + w - 10 - tx
        let full = Text([Text("Pauses \(l.pause)", F.sf(12, 650, tabular: true), t.amber),
                         Text(" at the 5-hour limit", F.sf(12, 500), t.amber),
                         Text(" · resumes \(l.resume)", F.sf(12, 500, tabular: true), t.amber.fade(0.68))])
        let middle = Text([Text("Pauses \(l.pause)", F.sf(12, 650, tabular: true), t.amber),
                           Text(" at the limit", F.sf(12, 500), t.amber),
                           Text(" · resumes \(l.resume)", F.sf(12, 500, tabular: true), t.amber.fade(0.68))])
        let short = Text([Text("Pauses \(l.pause)", F.sf(12, 650, tabular: true), t.amber),
                          Text(" · resumes \(l.resume)", F.sf(12, 500, tabular: true), t.amber.fade(0.68))])
        (full.width <= room ? full : middle.width <= room ? middle : short).draw(x: tx, capCenter: rect.midY, in: ctx)
        return h
    }

    // MARK: Finished

    /// "56m · 598K tokens · ~$3.83".
    static func drawFactsLine(_ facts: [RunFactModel], x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let h: CGFloat = 16
        guard let ctx else { return h }
        var parts: [Text] = []
        for (i, f) in facts.enumerated() {
            if i > 0 { parts.append(Text(" · ", F.sf(12, 500), t.muted2)) }
            parts.append(Text(f.value, F.sf(12, 650, tabular: true), t.ink.fade(0.9)))
            if f.label == "Tokens" { parts.append(Text(" tokens", F.sf(12, 500), t.muted)) }
        }
        Text(parts).draw(x: x, capCenter: y + h / 2, in: ctx)
        return h
    }

    /// Where the time went, in words over the bar: each part with a dot in its colour, and on the
    /// right how long the run was open (the one place time open is shown).
    static func drawSplitCaption(_ parts: [(label: String, seconds: Double, color: NSColor)], open: String?, x: CGFloat, y: CGFloat, w: CGFloat,
                                 theme t: Theme, ctx: CGContext?) -> CGFloat {
        let h: CGFloat = 15
        guard let ctx else { return h }
        let mid = y + h / 2
        var right = x + w
        if let open {
            let o = Text("\(open) open", F.sf(11, 550, tabular: true), t.muted)
            o.draw(x: right, capCenter: mid, align: .right, in: ctx)
            right -= o.width + 12
        }
        var px = x
        for p in parts {
            let word = p.label == "waiting on you" ? "On you" : p.label == "on a limit" ? "Limit" : p.label.prefix(1).uppercased() + p.label.dropFirst()
            let label = Text([Text(word + " ", F.sf(11, 600), t.ink.fade(0.8)), Text(RunsPresenter.duration(p.seconds), F.sf(11, 500, tabular: true), t.muted)])
            guard px + 10 + label.width <= right else { break }
            ctx.fill(CGPath(ellipseIn: CGRect(x: px, y: mid - 3, width: 6, height: 6), transform: nil), p.color)
            label.draw(x: px + 10, capCenter: mid, in: ctx)
            px += 10 + label.width + 12
        }
        return h
    }

    /// Where the time went, as a 4pt bar; the split in words as its tooltip.
    static func drawSplit(_ parts: [(label: String, seconds: Double, color: NSColor)], x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme,
                          ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let h: CGFloat = 4
        out?.add(CGRect(x: x, y: y - 5, width: w, height: h + 10),
                 tooltip: parts.map { "\($0.label) \(RunsPresenter.duration($0.seconds))" }.joined(separator: " · "))
        guard let ctx else { return h }
        let total = parts.reduce(0) { $0 + $1.seconds }
        let bar = CGRect(x: x, y: y, width: w, height: h)
        ctx.withState {
            ctx.addPath(rounded(bar, 2)); ctx.clip()
            let avail = w - 2 * CGFloat(parts.count - 1)
            var bx = x
            for p in parts {
                let bw = max(3, avail * CGFloat(p.seconds / total))
                ctx.fill(CGPath(rect: CGRect(x: bx, y: y, width: bw, height: h), transform: nil), p.color)
                bx += bw + 2
            }
        }
        return h
    }

    // MARK: Tasks

    /// "OPEN TASKS · 4" with "4 done ▾" on the right, then each group's title and its rows.
    static func drawTasks(_ page: RunPageModel, m: RunCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?,
                          out: RenderOutput?) -> CGFloat {
        guard !page.groups.isEmpty || page.doneCount > 0 else { return 0 }
        var yy = y + 14
        let headMid = yy + 8
        let open = page.groups.filter { $0.id != "~done" }
        let title = open.isEmpty ? m.rowsTitle.uppercased() : "\(page.groupsTitle.uppercased()) · \(page.openCount)"
        if let ctx { Text(title, F.sf(9.5, 700), t.muted2, kern: 0.9).draw(x: x, capCenter: headMid, in: ctx) }
        if page.doneCount > 0, !page.listsDone {
            // Another Mac's run counts its finished tasks without listing them: nothing to open.
            if let ctx { Text("\(page.doneCount) done", F.sf(11, 600, tabular: true), t.muted).draw(x: x + w, capCenter: headMid, align: .right, in: ctx) }
        } else if page.doneCount > 0 {
            let label = Text(page.showDone ? "Hide done" : "\(page.doneCount) done", F.sf(11, 600, tabular: true), t.muted)
            let lw = label.width + 6 + 8
            let r = CGRect(x: x + w - lw - 8, y: headMid - 11, width: lw + 12, height: 22)
            out?.add(r, tooltip: page.showDone ? "Hide the finished ones" : "Show the finished ones", action: .toggleRun(m.id), hover: 7)
            if let ctx {
                label.draw(x: x + w - 4 - 11 - label.width, capCenter: headMid, in: ctx)
                RunCardRenderer.drawChevron(up: page.showDone, center: CGPoint(x: x + w - 4 - 2, y: headMid), color: t.muted, ctx: ctx)
            }
        }
        yy += 16 + 2
        for group in page.groups {
            if let gt = group.title {
                yy += 3
                if let ctx {
                    RunCardRenderer.fit(gt, F.sf(11, 600), group.id == "~done" ? t.muted : t.muted2, width: w).draw(x: x, capCenter: yy + 8, in: ctx)
                }
                yy += 17
            }
            for row in group.rows {
                let panel = row.details.map { RunCardRenderer.DetailPanel($0, width: w - 17 + 8, theme: t) }
                let h = RunCardRenderer.rowHeight + (panel == nil ? (row.detail == nil ? 0 : RunCardRenderer.detailHeight) : panel!.height + 4)
                if let ctx { RunCardRenderer.drawRow(row, panel: panel, x: x, y: yy, w: w, theme: t, ctx: ctx) }
                if row.opens {
                    out?.add(CGRect(x: x - 7, y: yy, width: w + 14, height: h + 2), tooltip: row.details == nil ? "Show details" : "Hide details",
                             action: .toggleRow(m.id, row.id), hover: 8)
                }
                yy += h + 2
            }
        }
        if page.moreOpen > 0 {
            if let ctx { Text("and \(page.moreOpen) more", F.sf(11.5, 500), t.muted).draw(x: x + 17, capCenter: yy + 10, in: ctx) }
            yy += 20
        }
        return yy - y
    }

    // MARK: Lanes

    /// The percent at 24pt with its counts beside it, and the must-haves on the right.
    static func drawLanesSummary(_ m: RunCardModel, page: RunPageModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let h: CGFloat = 24
        guard let ctx, let hero = m.hero else { return m.hero == nil ? 0 : h }
        let mid = y + h / 2
        let numFont = F.sf(25, 700, tabular: true)
        let num = Text(hero.number, numFont, t.ink, kern: -0.9)
        let base = mid + numFont.capHeight / 2
        num.draw(x: x - 0.5, baseline: base, in: ctx)
        let unit = Text(hero.unit, F.sf(12.5, 650), t.ink.fade(0.85))
        unit.draw(x: x + num.width + 2, baseline: base - numFont.capHeight + F.sf(12.5, 650).capHeight + 1, in: ctx)
        var right = x + w
        if let must = page.facts.first(where: \.mustHave) {
            let v = Text(must.value, F.sf(11.5, 650, tabular: true), t.ink)
            v.draw(x: right, capCenter: mid, align: .right, in: ctx)
            drawDiamond(center: CGPoint(x: right - v.width - 7, y: mid), size: 8, color: t.ink.fade(0.8), filled: true, ctx: ctx)
            right -= v.width + 14 + 10
        }
        let lx = x + num.width + 2 + unit.width + 9
        RunCardRenderer.fit(countsOnly(hero.label), F.sf(11.5, 500, tabular: true), t.muted, width: right - lx).draw(x: lx, capCenter: mid + 1, in: ctx)
        return h
    }

    /// The chart: times along the top with now as a playhead; a lane per open task with its mark,
    /// title and where it stands, over a track its bars sit on; the limit's pause as a hatched
    /// band; the forecast finish as a dashed line; then what the chart says in words.
    static func drawLanes(_ l: RunLanesModel, page: RunPageModel, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext?) -> CGFloat {
        let headerH: CGFloat = 18, gap: CGFloat = 6
        let lanesTop = y + headerH + gap
        let lanesH = CGFloat(l.lanes.count) * laneHeight
        let lanesBottom = lanesTop + lanesH - 6
        // Legend items, wrapped.
        var items: [(Text, Bool)] = []
        if let limit = page.limit {
            items.append((Text("Pauses \(limit.pause)–\(limit.resume) at the 5-hour limit", F.sf(11.5, 600, tabular: true), t.amber), true))
        }
        if let done = page.facts.first(where: { $0.label == "Done" }) {
            items.append((Text([Text("Done ", F.sf(11.5, 500), t.muted), Text(done.value, F.sf(11.5, 650, tabular: true), t.ink)]), false))
        } else if let working = page.facts.first(where: { $0.label == "Working" }) {
            items.append((Text([Text(working.value, F.sf(11.5, 650, tabular: true), t.ink), Text(" working", F.sf(11.5, 500), t.muted)]), false))
        }
        if let tokens = page.facts.first(where: { $0.label == "Tokens" }) {
            items.append((Text([Text(tokens.value, F.sf(11.5, 650, tabular: true), t.ink), Text(" tokens", F.sf(11.5, 500), t.muted)]), false))
        }
        var placed: [(Text, Bool, CGPoint)] = []
        var lx: CGFloat = 0, ly: CGFloat = 0
        for (text, pause) in items {
            let iw = text.width + (pause ? 15 : 0)
            if lx > 0, lx + iw > w { lx = 0; ly += 16 }
            placed.append((text, pause, CGPoint(x: lx, y: ly)))
            lx += iw + 14
        }
        let legendH = items.isEmpty ? 0 : ly + 16
        let moreH: CGFloat = l.moreLanes > 0 ? 18 : 0
        let h = headerH + gap + lanesH + (legendH > 0 ? 6 + legendH : 0) + moreH
        guard let ctx else { return h }

        func px(_ f: Double) -> CGFloat { x + CGFloat(min(max(f, 0), 1)) * w }
        let nx = px(l.now)

        // Each lane's labels, laid out first so lines through the chart can step around them.
        struct Row { var top: CGFloat; var left: (Text, CGFloat); var status: Text?; var title: Text; var meta: Text?; var textSpans: [ClosedRange<CGFloat>] }
        let glyphW: CGFloat = 16
        var rows: [Row] = []
        for (i, lane) in l.lanes.enumerated() {
            let top = lanesTop + CGFloat(i) * laneHeight
            let statusColor: NSColor = lane.statusTone == .neutral ? t.ink.fade(0.72) : lane.statusTone == .quiet ? t.muted2
                : RunCardRenderer.color(lane.statusTone, t, glyph: lane.glyph)
            let status = lane.status.map { Text($0, F.sf(11, 650, tabular: true), statusColor) }
            let statusW = status.map { $0.width + 10 } ?? 0
            let meta = lane.meta.map { Text($0, F.sf(11, 500, tabular: true), t.muted2) }
            let metaW = meta.map { $0.width + 7 } ?? 0
            let diamondW: CGFloat = lane.mustHave ? 13 : 0
            let titleColor = lane.isFinished || lane.glyph == .planned ? t.muted : t.ink
            let title = RunCardRenderer.fit(lane.title, F.sf(11.5, lane.isFinished ? 550 : 600), titleColor,
                                            width: max(w - glyphW - metaW - diamondW - statusW, 40))
            let leftW = glyphW + title.width + diamondW + metaW
            var spans: [ClosedRange<CGFloat>] = [(x - 2)...(x + leftW + 4)]
            if let status { spans.append((x + w - status.width - 5)...(x + w + 2)) }
            rows.append(Row(top: top, left: (title, leftW), status: status, title: title, meta: meta, textSpans: spans))
        }
        /// A vertical line through the chart that steps around the lanes' labels.
        func through(_ lineX: CGFloat, from top: CGFloat, to bottom: CGFloat) -> CGMutablePath {
            let p = CGMutablePath()
            var yy = top
            for row in rows where row.textSpans.contains(where: { $0.contains(lineX) }) {
                let a = row.top - 3, b = row.top + 12
                if a > yy { p.move(to: CGPoint(x: lineX, y: yy)); p.addLine(to: CGPoint(x: lineX, y: a)) }
                yy = max(yy, b)
            }
            if bottom > yy { p.move(to: CGPoint(x: lineX, y: yy)); p.addLine(to: CGPoint(x: lineX, y: bottom)) }
            return p
        }

        let chartTop = y + headerH + 1
        // What's still to come: a faint wash right of now.
        if nx < x + w - 2 {
            ctx.fill(rounded(CGRect(x: nx, y: chartTop, width: x + w - nx, height: lanesBottom - chartTop + 4), 4), t.ink.fade(t.isDark ? 0.03 : 0.022))
        }
        /// Draws `body` everywhere but under the lanes' labels.
        func underChart(_ body: () -> Void) {
            ctx.withState {
                let clip = CGMutablePath()
                clip.addRect(CGRect(x: x - 4, y: chartTop - 2, width: w + 8, height: lanesBottom - chartTop + 10))
                for row in rows {
                    for span in row.textSpans {
                        clip.addPath(rounded(CGRect(x: span.lowerBound, y: row.top - 3, width: span.upperBound - span.lowerBound, height: 15), 4))
                    }
                }
                ctx.addPath(clip)
                ctx.clip(using: .evenOdd)
                body()
            }
        }
        // The pause band.
        if let p = l.pause { underChart {
            let band = CGRect(x: px(p.lowerBound), y: chartTop, width: max(px(p.upperBound) - px(p.lowerBound), 2), height: lanesBottom - chartTop + 4)
            let shape = CGPath(rect: band, transform: nil)
            ctx.fill(shape, t.amber.fade(t.isDark ? 0.07 : 0.08))
            RunCardRenderer.hatch(shape, color: t.amber.fade(t.isDark ? 0.16 : 0.2), spacing: 5, lineWidth: 1, ctx: ctx)
            for ex in [band.minX, band.maxX] {
                let edge = CGMutablePath(); edge.move(to: CGPoint(x: ex, y: band.minY)); edge.addLine(to: CGPoint(x: ex, y: band.maxY))
                ctx.stroke(edge, t.amber.fade(0.55), width: 1, dash: [3, 3])
            }
        } }
        // Hours, as faint guides.
        for tick in l.ticks where tick.kind == .plain {
            let gx = px(tick.at)
            guard gx > x + 4, gx < x + w - 4 else { continue }
            ctx.stroke(through(gx, from: chartTop, to: lanesBottom + 4), t.ink.fade(t.isDark ? 0.08 : 0.07), width: 1)
        }
        // The forecast finish.
        if let f = l.finish {
            ctx.stroke(through(px(f), from: chartTop, to: lanesBottom + 4), t.ink.fade(t.isDark ? 0.45 : 0.35), width: 1, dash: [2.5, 2.5])
        }

        // Lanes.
        let pc = t.pacing(.plenty), rose = t.pacing(.veryTight), amber = t.pacing(.tight)
        let trackH: CGFloat = 6, trackOffset: CGFloat = 17
        for (lane, row) in zip(l.lanes, rows) {
            let labelMid = row.top + 4.5
            let glyphColor = lane.isFinished && lane.glyph == .done ? t.muted : RunCardRenderer.color(lane.tone, t, glyph: lane.glyph)
            RunCardRenderer.drawGlyph(lane.glyph, color: glyphColor, center: CGPoint(x: x + 5, y: labelMid), size: 10, ctx: ctx)
            row.title.draw(x: x + glyphW, capCenter: labelMid, in: ctx)
            var mx = x + glyphW + row.title.width
            if lane.mustHave {
                drawDiamond(center: CGPoint(x: mx + 7, y: labelMid), size: 7.5, color: t.ink.fade(0.8), filled: true, ctx: ctx)
                mx += 13
            }
            row.meta?.draw(x: mx + 7, capCenter: labelMid, in: ctx)
            row.status?.draw(x: x + w, capCenter: labelMid, align: .right, in: ctx)

            // The track the bars sit on.
            let track = CGRect(x: x, y: row.top + trackOffset, width: w, height: trackH)
            ctx.fill(rounded(track, trackH / 2), t.ink.fade(t.isDark ? 0.07 : 0.055))
            func bar(_ b: RunLanesModel.Bar) -> (CGRect, CGPath) {
                let r = CGRect(x: px(b.start), y: track.minY, width: max(px(b.end) - px(b.start), trackH), height: trackH)
                return (r, rounded(r, trackH / 2))
            }
            if lane.isFinished {
                // One band where any finished task ran, a dot where each one ended, failures hatched.
                for span in RunLanesModel.merged(lane.bars) {
                    ctx.fill(bar(.init(kind: .done, start: span.lowerBound, end: span.upperBound)).1, t.ink.fade(t.isDark ? 0.26 : 0.18))
                }
                for b in lane.bars where b.kind == .failed {
                    let (_, shape) = bar(b)
                    let c = RunCardRenderer.failure(t)
                    ctx.fill(shape, c.fade(0.3))
                    RunCardRenderer.hatch(shape, color: c.fade(0.85), spacing: 3, lineWidth: 1, ctx: ctx)
                }
                // A dot per task only while they can be told apart.
                for b in lane.bars where lane.bars.count <= RunLanesModel.dotCap {
                    let ex = max(px(b.end) - trackH / 2, px(b.start) + trackH / 2)
                    let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: ex - 2, y: track.midY - 2, width: 4, height: 4))
                    ctx.fill(dot, b.kind == .failed ? RunCardRenderer.failure(t) : t.ink.fade(t.isDark ? 0.7 : 0.55))
                }
                continue
            }
            for b in lane.bars {
                let (r, shape) = bar(b)
                switch b.kind {
                case .done:
                    ctx.fill(shape, t.ink.fade(t.isDark ? 0.42 : 0.30))
                case .running:
                    ctx.glow(shape, color: pc.glow, blur: 6, base: pc.bottom)
                    ctx.fillLinear(shape, [pc.bottom, pc.top], from: CGPoint(x: r.minX, y: r.midY), to: CGPoint(x: r.maxX, y: r.midY))
                case .asking:
                    ctx.glow(shape, color: rose.glow, blur: 6, base: rose.bottom)
                    ctx.fillLinear(shape, [rose.bottom, rose.top], from: CGPoint(x: r.minX, y: r.midY), to: CGPoint(x: r.maxX, y: r.midY))
                case .held:
                    ctx.fillLinear(shape, [amber.bottom, amber.top], from: CGPoint(x: r.minX, y: r.midY), to: CGPoint(x: r.maxX, y: r.midY))
                case .failed:
                    let c = RunCardRenderer.failure(t)
                    ctx.fill(shape, c.fade(0.35))
                    RunCardRenderer.hatch(shape, color: c.fade(0.9), spacing: 3, lineWidth: 1, ctx: ctx)
                case .forecast:
                    ctx.fill(shape, t.azure.fade(t.isDark ? 0.16 : 0.12))
                    ctx.stroke(rounded(r.insetBy(dx: 0.5, dy: 0.5), trackH / 2 - 0.5), t.azure.fade(0.75), width: 1)
                case .planned:
                    ctx.fill(shape, t.cardSolid.fade(0.7))
                    ctx.stroke(rounded(r.insetBy(dx: 0.5, dy: 0.5), trackH / 2 - 0.5), t.ink.fade(0.4), width: 1, dash: [2.5, 2])
                }
            }
        }

        // Now: a playhead from the axis down through every lane, stepping around labels.
        ctx.withState {
            if t.isDark { ctx.setShadow(offset: .zero, blur: 5, color: white(0.4).cgColor) }
            ctx.stroke(through(nx, from: chartTop - 1, to: lanesBottom + 4), t.ink.fade(0.9), width: 1.5, cap: .round)
        }
        drawTicks(l.ticks, x: x, w: w, mid: y + headerH / 2, theme: t, ctx: ctx)

        // Legend.
        var yy = lanesTop + lanesH
        if legendH > 0 {
            yy += 6
            for (text, pause, at) in placed {
                var tx = x + at.x
                if pause {
                    Glyph.pause(in: CGRect(x: tx, y: yy + at.y + 8 - 4.5, width: 8, height: 9), color: t.amber, ctx: ctx)
                    tx += 15
                }
                text.draw(x: tx, capCenter: yy + at.y + 8, in: ctx)
            }
            yy += legendH
        }
        if l.moreLanes > 0 {
            Text("+ \(l.moreLanes) more task\(l.moreLanes == 1 ? "" : "s") in the list below", F.sf(11.5, 500), t.muted).draw(x: x, capCenter: yy + 10, in: ctx)
        }
        return h
    }

    /// The axis along the top: now as a filled tag, then the limit, the finish, the start and the
    /// hours where they fit. Each important one keeps a mark even when its label gives way.
    static func drawTicks(_ ticks: [RunLanesModel.Tick], x: CGFloat, w: CGFloat, mid: CGFloat, theme t: Theme, ctx: CGContext) {
        let ranked = ticks.sorted { rank($0.kind) < rank($1.kind) }
        var taken: [ClosedRange<CGFloat>] = []
        var said: Set<String> = []
        for tick in ranked {
            let cx = x + CGFloat(min(max(tick.at, 0), 1)) * w
            if tick.kind == .now {
                let label = Text("NOW", F.sf(9, 750), t.cardSolid, kern: 0.7)
                let tagW = label.width + 10
                let left = min(max(cx - tagW / 2, x), x + w - tagW)
                let tag = CGRect(x: left, y: mid - 7.5, width: tagW, height: 15)
                ctx.fill(rounded(tag, 7.5), t.ink.fade(0.92))
                label.draw(x: left + 5, capCenter: mid, in: ctx)
                taken.append((tag.minX - 4)...(tag.maxX + 4))
                continue
            }
            let color: NSColor = switch tick.kind {
            case .limit: t.amber
            case .finish: t.ink.fade(0.85)
            case .start, .plain, .now: t.muted2
            }
            let label = Text(tick.label, F.sf(9.5, tick.kind == .plain || tick.kind == .start ? 600 : 700, tabular: true), color, kern: 0.2)
            // An hour that would repeat a label already on the axis (a span of days) says nothing new.
            guard tick.kind != .plain || !said.contains(tick.label) else { continue }
            // Centred on its line; an important one slides to either side of it before giving way.
            let clamp = { (l: CGFloat) in min(max(l, x), x + w - label.width) }
            let tries = tick.kind == .start ? [x] : tick.kind == .plain ? [clamp(cx - label.width / 2)]
                : [clamp(cx - label.width / 2), clamp(cx - 1), clamp(cx - label.width + 1)]
            guard let left = tries.first(where: { l in !taken.contains { $0.overlaps((l - 3)...(l + label.width + 3)) } }) else { continue }
            taken.append((left - 3)...(left + label.width + 3))
            said.insert(tick.label)
            label.draw(x: left, capCenter: mid, in: ctx)
        }
    }

    private static func rank(_ k: RunLanesModel.Tick.Kind) -> Int {
        switch k {
        case .now: 0
        case .limit: 1
        case .finish: 2
        case .start: 3
        case .plain: 4
        }
    }

    /// "5 of 10 tasks": the hero's label without "· 3 running", which the status line already says.
    static func countsOnly(_ label: String) -> String {
        label.components(separatedBy: " · ").filter { !$0.hasSuffix(" running") }.joined(separator: " · ")
    }
}
