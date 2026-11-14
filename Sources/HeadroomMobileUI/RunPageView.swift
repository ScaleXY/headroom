import HeadroomKit
import HeadroomPresent
import HeadroomWidgetUI
import SwiftUI

/// A run's own page, opened from the runs list, in the style Settings picks, as the Mac draws it.
///
/// Briefing: one status line (or the question, while it asks), the percent beside its facts, the
/// task meter with a diamond under each must-have, the limit as one amber line, then the open
/// tasks under their parents. Lanes: the same header, then the run as a time chart, a lane per
/// open task, with now, the limit's pause and the forecast finish on one axis. A finished run, or
/// one synced without its tasks' times, reads as a Briefing.
public struct RunPageView: View {
    public var card: RunCardModel
    public var style: RunPageStyle
    @Environment(\.colorScheme) private var scheme

    public init(card: RunCardModel, style: RunPageStyle) { self.card = card; self.style = style }

    public var body: some View {
        let p = Palette(scheme), c = card, page = c.page
        let lanes = style == .lanes && c.live ? page?.lanes.flatMap { $0.lanes.isEmpty ? nil : $0 } : nil
        VStack(alignment: .leading, spacing: 14) {
            header(p)
            if c.live {
                if let q = c.question {
                    RunQuestionBlock(question: q)
                } else if let status = page?.status {
                    RunStatusLine(card: c, status: status)
                }
                if let lanes, let page {
                    RunLanesSummary(card: c, page: page)
                    RunLanesChart(lanes: lanes, page: page)
                } else {
                    if let hero = c.hero { RunHeroBlock(hero: hero, facts: page?.facts ?? []) }
                    RunPageMeter(card: c)
                    if let limit = page?.limit { RunLimitLine(limit: limit) }
                }
                if let warning = c.warning, page?.limit == nil { WarningBox(text: warning) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let status = page?.status { RunStatusLine(card: c, status: status) }
                    if let facts = page?.facts, !facts.isEmpty { RunFactsLine(facts: facts) }
                }
                if let time = c.receipt?.time, time.total > 0 { RunTimeSplitView(time: time) }
                if let secondary = c.verdict?.secondary {
                    Text(secondary).font(.footnote).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let page { RunPageTasks(card: c, page: page) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(p.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(c.needsInput ? p.rose.opacity(0.45) : p.groupBorder, lineWidth: c.needsInput ? 1 : 0.5))
    }

    private func header(_ p: Palette) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RunTile(card: card, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline).foregroundStyle(p.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(card.subtitle).font(.caption).foregroundStyle(p.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A glowing dot (live) or the outcome's glyph (finished), the key in the state's colour, and what it's about.
struct RunStatusLine: View {
    var card: RunCardModel
    var status: RunStatusModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), c = card
        let tone = c.tone == .quiet ? p.muted : p.run(c.hue)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Group {
                if c.live {
                    Circle().fill(tone).frame(width: 7, height: 7).shadow(color: c.settled ? .clear : tone, radius: 4)
                } else {
                    RunMarkView(RunMark(c.glyph), color: tone, size: 11)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            (Text(status.key).font(.subheadline.weight(.semibold)).foregroundStyle(tone)
                + Text(status.detail.map { " · " + $0 } ?? "").font(.subheadline).foregroundStyle(p.muted))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Briefing

/// The percent with its unit raised and its label under; the facts beside it as a label · value grid.
struct RunHeroBlock: View {
    var hero: RunHeroModel
    var facts: [RunFactModel]
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 44

    var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(hero.number).font(.system(size: size, weight: .bold).monospacedDigit()).tracking(-1.5).foregroundStyle(p.ink)
                        .contentTransition(.numericText())
                    Text(hero.unit).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(p.ink.opacity(0.85))
                }
                .fixedSize()
                Text(RunPageText.countsOnly(hero.label)).font(.footnote.monospacedDigit()).foregroundStyle(p.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            if !facts.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(facts, id: \.self) { f in
                        GridRow {
                            Text(f.label).font(.caption).foregroundStyle(p.muted2)
                            HStack(spacing: 5) {
                                if f.mustHave { RunDiamond(filled: true, color: p.ink.opacity(0.8)).frame(width: 7, height: 9) }
                                Text(f.value).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink)
                            }
                        }
                    }
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The task map with a caret under each must-have; a plain bar without a map.
struct RunPageMeter: View {
    var card: RunCardModel

    var body: some View {
        if !card.segments.isEmpty {
            RunTaskMap(blocks: card.segments.map(RunMapBlock.init), height: 11, gap: 3)
        } else if let bar = card.bar {
            RunProgressBar(done: bar.done, inFlight: bar.inFlight, height: 8)
        } else if let hero = card.hero {
            CellMeter(state: card.tone == .warn ? .tight : .plenty, cells: Int((min(max(hero.fraction, 0), 1) * 5).rounded()), height: 11)
        }
    }
}

/// "Pauses 10:30 AM at the 5-hour limit · resumes 11:20 AM", with the forecast's reasoning under it.
struct RunLimitLine: View {
    var limit: RunLimitModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pause.fill").font(.caption2.weight(.bold))
                (Text("Pauses \(limit.pause)").font(.footnote.weight(.semibold).monospacedDigit())
                    + Text(" at the 5-hour limit").font(.footnote)
                    + Text(" · resumes \(limit.resume)").font(.footnote.monospacedDigit()).foregroundStyle(p.amber.opacity(0.7)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(p.amber)
            if let note = limit.note {
                Text(note + ".").font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true).padding(.leading, 18)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.amber.opacity(p.dark ? 0.09 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.amber.opacity(p.dark ? 0.3 : 0.34), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// "56m · 598K tokens · ~$3.83".
struct RunFactsLine: View {
    var facts: [RunFactModel]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        facts.enumerated().reduce(Text("")) { t, e in
            let (i, f) = e
            return t + Text(i > 0 ? " · " : "").foregroundStyle(p.muted2)
                + Text(f.value).fontWeight(.semibold).foregroundStyle(p.ink.opacity(0.9))
                + Text(f.label == "Tokens" ? " tokens" : "").foregroundStyle(p.muted)
        }
        .font(.footnote.monospacedDigit())
    }
}

/// The must-have mark: a small diamond.
struct RunDiamond: View {
    var filled: Bool
    var color: Color

    var body: some View {
        let shape = DiamondShape()
        if filled { shape.fill(color) } else { shape.stroke(color, lineWidth: 1.1) }
    }

    struct DiamondShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - Tasks

/// "OPEN TASKS · 4" with how many are done on the right, then each group's title and its rows.
struct RunPageTasks: View {
    var card: RunCardModel
    var page: RunPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        // A run synced without names has no rows to group: its counts line stands in.
        let counts = page.groups.isEmpty ? card.rows.filter { $0.kind == .counts } : []
        if !page.groups.isEmpty || page.doneCount > 0 || !counts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    let open = page.groups.contains { $0.id != "~done" }
                    Caps(open ? "\(page.groupsTitle) · \(page.openCount)" : card.rowsTitle, size: 10)
                    Spacer()
                    if page.doneCount > 0 { Text("\(page.doneCount) done").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(p.muted) }
                }
                .padding(.bottom, 4)
                ForEach(page.groups) { g in
                    if let title = g.title {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(g.id == "~done" ? p.muted : p.muted2).lineLimit(1)
                            .padding(.top, 8).padding(.bottom, 1)
                    }
                    ForEach(g.rows) { RunRowView(row: $0, live: card.live) }
                }
                ForEach(counts) { RunRowView(row: $0, live: card.live) }
                if page.moreOpen > 0 {
                    Text("and \(page.moreOpen) more").font(.footnote).foregroundStyle(p.muted).padding(.leading, 17).padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Lanes

/// The percent with its counts beside it, and the must-haves on the right.
struct RunLanesSummary: View {
    var card: RunCardModel
    var page: RunPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        if let hero = card.hero {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(hero.number).font(.system(size: 28, weight: .bold).monospacedDigit()).tracking(-0.8)
                    Text(hero.unit).font(.system(size: 14, weight: .semibold)).opacity(0.85)
                }
                .foregroundStyle(p.ink).fixedSize()
                Text(RunPageText.countsOnly(hero.label)).font(.footnote.monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                Spacer(minLength: 4)
                if let must = page.facts.first(where: \.mustHave) {
                    HStack(spacing: 5) {
                        RunDiamond(filled: true, color: p.ink.opacity(0.8)).frame(width: 7, height: 9)
                        Text(must.value).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink)
                    }
                    .fixedSize()
                    .accessibilityLabel("Must-haves \(must.value)")
                }
            }
        }
    }
}

/// A lane per open task with its bars, the limit's pause as a hatched band, now as a line, the
/// axis, and a legend of what the chart says in words.
struct RunLanesChart: View {
    var lanes: RunLanesModel
    var page: RunPageModel
    @Environment(\.colorScheme) private var scheme
    static let laneHeight: CGFloat = 36

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    bands(p)
                    VStack(spacing: 0) {
                        ForEach(lanes.lanes) { lane(p, $0).frame(height: Self.laneHeight) }
                    }
                }
                .frame(height: CGFloat(lanes.lanes.count) * Self.laneHeight)
                Rectangle().fill(p.separator).frame(height: 0.5)
                RunLaneTicks(ticks: lanes.ticks).frame(height: 18)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            legend(p)
            if lanes.moreLanes > 0 {
                Text("+ \(lanes.moreLanes) more task\(lanes.moreLanes == 1 ? "" : "s") in the list below").font(.footnote).foregroundStyle(p.muted)
            }
        }
    }

    /// The pause band, and now as a line, under the bars.
    private func bands(_ p: Palette) -> some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(min(max(f, 0), 1)) * size.width }
            if let pause = lanes.pause {
                let band = CGRect(x: x(pause.lowerBound), y: 0, width: max(x(pause.upperBound) - x(pause.lowerBound), 2), height: size.height)
                ctx.fill(Path(band), with: .color(p.amber.opacity(p.dark ? 0.07 : 0.08)))
                var stripes = Path(), sx = band.minX - size.height
                while sx < band.maxX { stripes.move(to: CGPoint(x: sx, y: size.height)); stripes.addLine(to: CGPoint(x: sx + size.height, y: 0)); sx += 6 }
                var inner = ctx
                inner.clip(to: Path(band))
                inner.stroke(stripes, with: .color(p.amber.opacity(p.dark ? 0.18 : 0.22)), lineWidth: 1)
                for ex in [band.minX, band.maxX] {
                    var edge = Path(); edge.move(to: CGPoint(x: ex, y: 0)); edge.addLine(to: CGPoint(x: ex, y: size.height))
                    ctx.stroke(edge, with: .color(p.amber.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
    }

    private func lane(_ p: Palette, _ lane: RunLanesModel.Lane) -> some View {
        let finished = lane.id == "~done"
        let toneColor: Color = switch lane.tone {
        case .alert: lane.glyph == .failed ? p.run(.failed) : p.rose
        case .warn: p.amber
        case .quiet: p.muted
        default: p.ink
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(lane.title).font(.caption.weight(finished ? .medium : .semibold)).foregroundStyle(finished ? p.muted : toneColor).lineLimit(1)
                if lane.mustHave { RunDiamond(filled: true, color: p.ink.opacity(0.8)).frame(width: 6, height: 8) }
                if let meta = lane.meta { Text(meta).font(.caption2.monospacedDigit()).foregroundStyle(p.muted2).lineLimit(1).fixedSize() }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 2)
            Canvas { ctx, size in
                let h: CGFloat = 7
                ctx.fill(Path(CGRect(x: 0, y: h / 2 - 0.25, width: size.width, height: 0.5)), with: .color(p.separator))
                defer {
                    // Now: a line through the lane's bars, clear of its label, down to the next lane.
                    let nx = CGFloat(min(max(lanes.now, 0), 1)) * size.width
                    var now = Path(); now.move(to: CGPoint(x: nx, y: -4)); now.addLine(to: CGPoint(x: nx, y: size.height))
                    var glow = ctx
                    if p.dark { glow.addFilter(.shadow(color: .white.opacity(0.45), radius: 2.5)) }
                    glow.stroke(now, with: .color(p.ink.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                let blue = p.tone(.plenty), rose = p.tone(.veryTight), amber = p.tone(.tight)
                for b in lane.bars {
                    let x0 = CGFloat(min(max(b.start, 0), 1)) * size.width, x1 = CGFloat(min(max(b.end, 0), 1)) * size.width
                    let r = CGRect(x: x0, y: 0, width: max(x1 - x0, 3), height: h)
                    let shape = Path(roundedRect: r, cornerRadius: h / 2)
                    let across = { (a: Color, b: Color) in GraphicsContext.Shading.linearGradient(Gradient(colors: [a, b]), startPoint: CGPoint(x: r.minX, y: r.midY),
                                                                                                   endPoint: CGPoint(x: r.maxX, y: r.midY)) }
                    switch b.kind {
                    case .done: ctx.fill(shape, with: .color(p.ink.opacity(p.dark ? 0.42 : 0.3)))
                    case .running: ctx.fill(shape, with: across(blue.bottom, blue.top))
                    case .asking: ctx.fill(shape, with: across(rose.bottom, rose.top))
                    case .held: ctx.fill(shape, with: across(amber.bottom, amber.top))
                    case .failed:
                        ctx.fill(shape, with: .color(p.run(.failed).opacity(0.35)))
                        var hatch = Path(), sx = r.minX - h
                        while sx < r.maxX { hatch.move(to: CGPoint(x: sx, y: h)); hatch.addLine(to: CGPoint(x: sx + h, y: 0)); sx += 3 }
                        var inner = ctx
                        inner.clip(to: shape)
                        inner.stroke(hatch, with: .color(p.run(.failed).opacity(0.9)), lineWidth: 1)
                    case .forecast:
                        ctx.fill(shape, with: .color(p.cardSolid.opacity(0.6)))
                        ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: h / 2 - 0.5), with: .color(p.azure.opacity(0.7)), lineWidth: 1)
                    case .planned:
                        ctx.fill(shape, with: .color(p.cardSolid.opacity(0.6)))
                        ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: h / 2 - 0.5), with: .color(p.ink.opacity(0.3)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                    }
                }
            }
            .frame(height: 14, alignment: .top)
        }
        .padding(.top, 3)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func legend(_ p: Palette) -> some View {
        FlowRow(spacing: 14, lineSpacing: 4) {
            if let limit = page.limit {
                HStack(spacing: 5) {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                    Text("Pauses \(limit.pause)–\(limit.resume) at the 5-hour limit").font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(p.amber)
            }
            if let done = page.facts.first(where: { $0.label == "Done" }) {
                (Text("Done ").foregroundStyle(p.muted) + Text(done.value).fontWeight(.semibold).foregroundStyle(p.ink)).font(.caption.monospacedDigit())
            } else if let working = page.facts.first(where: { $0.label == "Working" }) {
                (Text(working.value).fontWeight(.semibold).foregroundStyle(p.ink) + Text(" working").foregroundStyle(p.muted)).font(.caption.monospacedDigit())
            }
            if let tokens = page.facts.first(where: { $0.label == "Tokens" }) {
                (Text(tokens.value).fontWeight(.semibold).foregroundStyle(p.ink) + Text(" tokens").foregroundStyle(p.muted)).font(.caption.monospacedDigit())
            }
        }
    }

    private var spoken: String {
        var parts = lanes.lanes.map { [$0.title, $0.meta].compactMap { $0 }.joined(separator: ", ") }
        if let limit = page.limit { parts.append("pauses \(limit.pause) to \(limit.resume) at the 5-hour limit") }
        return "Timeline: " + parts.joined(separator: "; ")
    }
}

/// Axis labels: now, the limit and the finish first, then the hours where they fit.
struct RunLaneTicks: View {
    var ticks: [RunLanesModel.Tick]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        Canvas { ctx, size in
            let ranked = ticks.sorted { rank($0.kind) < rank($1.kind) }
            var taken: [ClosedRange<CGFloat>] = []
            var said: Set<String> = []
            for t in ranked {
                let color: Color = switch t.kind {
                case .now: p.ink
                case .limit: p.amber
                case .finish: p.ink.opacity(0.8)
                case .plain: p.muted2
                }
                let label = ctx.resolve(Text(t.label).font(.system(size: 10, weight: t.kind == .plain ? .semibold : .bold).monospacedDigit()).foregroundStyle(color))
                let w = label.measure(in: size).width
                let cx = CGFloat(min(max(t.at, 0), 1)) * size.width
                if t.kind != .plain {
                    var mark = Path(); mark.move(to: CGPoint(x: cx, y: 0)); mark.addLine(to: CGPoint(x: cx, y: 3.5))
                    ctx.stroke(mark, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
                let left = min(max(cx - w / 2, 0), size.width - w)
                let span = (left - 3)...(left + w + 3)
                guard !taken.contains(where: { $0.overlaps(span) }), t.kind != .plain || !said.contains(t.label) else { continue }
                taken.append(span)
                said.insert(t.label)
                ctx.draw(label, at: CGPoint(x: left, y: 11), anchor: .leading)
            }
        }
    }

    private func rank(_ k: RunLanesModel.Tick.Kind) -> Int {
        switch k {
        case .now: 0
        case .limit: 1
        case .finish: 2
        case .plain: 3
        }
    }
}

enum RunPageText {
    /// "5 of 10 tasks": the hero's label without "· 3 running", which the status line already says.
    static func countsOnly(_ label: String) -> String {
        label.components(separatedBy: " · ").filter { !$0.hasSuffix(" running") }.joined(separator: " · ")
    }
}
