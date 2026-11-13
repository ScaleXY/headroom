import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// Agent runs from every Mac, at the top of Now: live runs first, the last day's finished ones
/// folded below. It's there only while some Mac syncs a run. Cards by default; the compact view
/// puts each run on one line, and a tap opens that run's card in its place.
struct RunsSection: View {
    var model: MobileModel
    var columns = 1
    @State private var showFinished = false
    @State private var expanded: Set<String> = []
    @State private var opened: Set<String> = []
    @AppStorage("runsCompact") private var compact = false

    var body: some View {
        let page = RunsPresenter(now: model.reader.now, calendar: .current, locale: .current).page(model.reader.runs, expanded: expanded)
        if !page.isEmpty {
            RunsSectionContent(page: page, columns: columns, showFinished: $showFinished, compact: $compact, opened: opened,
                               open: { id in withAnimation(.snappy) { if opened.contains(id) { opened.remove(id) } else { opened.insert(id) } } }) { id in
                withAnimation(.snappy) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
            }
        }
    }
}

/// The section itself, from a page model, so the PNG renderer draws exactly what the app does.
public struct RunsSectionContent: View {
    var page: RunsPageModel
    var columns: Int
    @Binding var showFinished: Bool
    @Binding var compact: Bool
    /// In the compact view, the runs shown as cards.
    var opened: Set<String>
    var open: ((String) -> Void)?
    var toggle: ((String) -> Void)?
    @Environment(\.colorScheme) private var scheme

    public init(page: RunsPageModel, columns: Int = 1, showFinished: Binding<Bool>, compact: Binding<Bool> = .constant(false),
                opened: Set<String> = [], open: ((String) -> Void)? = nil, toggle: ((String) -> Void)? = nil) {
        self.page = page; self.columns = columns; self._showFinished = showFinished; self._compact = compact
        self.opened = opened; self.open = open; self.toggle = toggle
    }

    public var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Agent runs").font(.headline).foregroundStyle(p.ink)
                Spacer()
                if page.live.contains(where: \.needsInput) {
                    Text(RunWords.needsInput).font(.caption.weight(.semibold)).foregroundStyle(p.rose)
                }
                Button { withAnimation(.snappy) { compact.toggle() } } label: {
                    Image(systemName: compact ? "rectangle.grid.1x2" : "list.bullet")
                        .font(.footnote.weight(.semibold)).foregroundStyle(p.muted)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.chipFill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(compact ? "Show runs as cards" : "Show runs on one line each")
            }
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
            if !page.live.isEmpty { runs(page.live, spacing: 14) }
            if !page.recent.isEmpty {
                // Not a DisclosureGroup: its indent would set finished cards off the live ones' edges.
                Button { withAnimation(.snappy) { showFinished.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(showFinished ? 90 : 0))
                        Text("\(RunsPageModel.recentTitle) (\(page.recent.count + page.moreRecent))").font(.footnote.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4).padding(.top, 4)
                .accessibilityValue(showFinished ? "Shown" : "Hidden")
                if showFinished {
                    runs(page.recent, spacing: 10)
                    if page.moreRecent > 0 {
                        Text("+ \(page.moreRecent) more").font(.caption).foregroundStyle(p.muted).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    /// Cards in a grid, or, compact, lines in shared lists broken by the runs opened into cards.
    @ViewBuilder private func runs(_ cards: [RunCardModel], spacing: CGFloat) -> some View {
        if compact {
            VStack(spacing: 10) {
                ForEach(Array(Self.groups(cards, opened: opened).enumerated()), id: \.offset) { _, group in
                    switch group {
                    case .card(let card):
                        RunCardView(card: card) { toggle?(card.id) }
                            .overlay(alignment: .topTrailing) {
                                Button { open?(card.id) } label: {
                                    Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(Palette(scheme).muted)
                                        .frame(width: 32, height: 32).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).padding(.top, 54).padding(.trailing, 8)
                                .accessibilityLabel("Back to one line")
                            }
                    case .lines(let cards):
                        RunCompactList(cards: cards) { open?($0) }
                    }
                }
            }
        } else {
            let grid = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columns)
            LazyVGrid(columns: grid, spacing: spacing) {
                ForEach(cards) { card in RunCardView(card: card) { toggle?(card.id) } }
            }
        }
    }

    enum Group { case card(RunCardModel), lines([RunCardModel]) }

    static func groups(_ cards: [RunCardModel], opened: Set<String>) -> [Group] {
        var out: [Group] = [], lines: [RunCardModel] = []
        for c in cards {
            if opened.contains(c.id) {
                if !lines.isEmpty { out.append(.lines(lines)); lines = [] }
                out.append(.card(c))
            } else {
                lines.append(c)
            }
        }
        if !lines.isEmpty { out.append(.lines(lines)) }
        return out
    }
}

/// Runs a line each, in one card: the provider's tile with a state dot, the title, a small task
/// meter, the percent and the time left (or what holds it up); a finished run's outcome, title,
/// tasks, how long and what it cost.
struct RunCompactList: View {
    var cards: [RunCardModel]
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                if i > 0, !card.needsInput, !cards[i - 1].needsInput {
                    Rectangle().fill(p.separator).frame(height: 0.5).padding(.leading, 44)
                }
                Button { open(card.id) } label: { RunCompactRow(card: card).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the run")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.groupBorder, lineWidth: 0.5))
    }
}

struct RunCompactRow: View {
    var card: RunCardModel
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var meterWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .footnote) private var figureWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .footnote) private var sideWidth: CGFloat = 48

    var body: some View {
        let p = Palette(scheme), hue = RunHue(card.tone, glyph: card.glyph), tone = p.run(hue)
        HStack(spacing: 8) {
            if card.live { tile(p, tone: tone) } else { outcome(p, tone: tone) }
            Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(card.live ? p.ink : p.ink.opacity(0.88)).lineLimit(1)
            Spacer(minLength: 4)
            if card.live {
                meter.frame(width: meterWidth)
                // At least the column's width, so figures line up; wider when a count needs it.
                figure(p, tone: tone).frame(minWidth: figureWidth, alignment: .trailing)
                side(p, tone: tone).frame(width: sideWidth, alignment: .trailing)
            } else if let r = card.receipt {
                Text(r.tasks).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted2).lineLimit(1).fixedSize()
                Text(r.duration).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1).fixedSize()
                if let cost = r.cost {
                    Text(cost.replacingOccurrences(of: "about ", with: "~")).font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(p.ink).lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 8).frame(minHeight: 42)
        .background {
            if card.needsInput {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.rose.opacity(p.dark ? 0.12 : 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.rose.opacity(0.26), lineWidth: 0.5))
                    .padding(.vertical, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([card.title, card.stateText, card.hero.map { "\($0.number)\($0.unit) · \($0.label)" }, card.hero?.sideCaption]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// The provider's tile with the state as a dot on its corner.
    private func tile(_ p: Palette, tone: Color) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let provider = card.provider {
                BrandTile(provider: provider, size: 24)
            } else {
                RunMarkView(RunMark(card.glyph), color: tone, size: 11).frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(p.groupFill))
            }
            Circle().fill(tone).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(p.cardSolid, lineWidth: 1.5))
                .shadow(color: card.tone == .quiet || card.tone == .neutral ? .clear : tone.opacity(0.6), radius: 3)
                .offset(x: 3, y: 3)
        }
        .frame(width: 28, height: 28, alignment: .topLeading)
    }

    private func outcome(_ p: Palette, tone: Color) -> some View {
        RunMarkView(RunMark(card.glyph), color: card.glyph == .done ? p.ink.opacity(0.7) : tone, size: 9)
            .frame(width: 20, height: 20)
            .background(Circle().fill(tone.opacity(card.tone == .neutral || card.tone == .quiet ? 0.08 : 0.14)))
            .frame(width: 28, height: 28)
    }

    @ViewBuilder private var meter: some View {
        if !card.segments.isEmpty {
            RunTaskMap(blocks: card.segments.map(RunMapBlock.init), height: 5, gap: 1, carets: false)
        } else if let hero = card.hero {
            CellMeter(state: card.tone == .warn ? .tight : .plenty, cells: Int((min(max(hero.fraction, 0), 1) * 5).rounded()), height: 5)
        }
    }

    private func figure(_ p: Palette, tone: Color) -> some View {
        let strong = card.tone == .alert || card.tone == .warn
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(card.hero?.number ?? "").font(.subheadline.weight(.bold).monospacedDigit())
            Text(card.hero?.unit ?? "").font(.caption2.weight(.semibold).monospacedDigit()).opacity(0.7)
        }
        .foregroundStyle(strong ? tone : p.ink).lineLimit(1).fixedSize()
    }

    @ViewBuilder private func side(_ p: Palette, tone: Color) -> some View {
        if let flag = card.compactFlag {
            Text(flag).font(.caption.weight(.semibold)).foregroundStyle(tone).lineLimit(1)
        } else if let hero = card.hero, let side = hero.side {
            HStack(spacing: 3) {
                if hero.hourglass { Hourglass(color: p.tone(.plenty).text, height: 8) }
                Text(side).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(hero.hourglass ? p.muted : p.muted2).lineLimit(1)
            }
        }
    }
}

/// One run, as the Mac's Runs tab draws it: title, the question it waits on, the percent with its
/// task counts, the task map, the figures, the limit timeline, the warning, a receipt once it's
/// finished, and the rows or the counts line.
public struct RunCardView: View {
    public var card: RunCardModel
    var toggle: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    /// The Pace card's hero size, so a run's percent reads like the allowance above it.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 46

    public init(card: RunCardModel, toggle: (() -> Void)? = nil) { self.card = card; self.toggle = toggle }

    public var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 12) {
            header(p)
            if let q = card.question { RunQuestionBlock(question: q) }
            if card.live {
                if let hero = card.hero { heroRow(hero, p) }
                meter
                verdict(p)
                if let timeline = card.timeline { RunTimelineView(timeline: timeline) }
            } else {
                verdict(p)
                if let receipt = card.receipt { RunReceiptView(receipt: receipt) }
            }
            if let warning = card.warning, card.verdict?.primary != warning, card.timeline == nil { WarningBox(text: warning) }
            if !card.rows.isEmpty { rows(p) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(card.needsInput ? p.rose.opacity(0.45) : p.groupBorder, lineWidth: card.needsInput ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { if card.expandable { toggle?() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(card.expandable ? .isButton : [])
        .accessibilityHint(card.expandable ? (card.expanded ? "Shows fewer tasks" : "Shows every task") : "")
    }

    /// The Pace card's header: the provider's tile, the title, a status dot with where and when,
    /// and the state chip on the right.
    private func header(_ p: Palette) -> some View {
        let hue = RunHue(card.tone, glyph: card.glyph)
        let chip = RunStateCapsule(card.stateText, hue: hue).fixedSize()
        // The chip sits beside the title when both fit whole, else under it.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                tile(hue, p)
                titles(p, hue: hue, whole: true)
                Spacer(minLength: 8)
                chip
            }
            HStack(alignment: .top, spacing: 10) {
                tile(hue, p)
                VStack(alignment: .leading, spacing: 6) {
                    titles(p, hue: hue, whole: false)
                    chip
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func tile(_ hue: RunHue, _ p: Palette) -> some View {
        if let provider = card.provider {
            BrandTile(provider: provider, size: 26)
        } else {
            RunMarkView(RunMark(card.glyph), color: p.run(hue), size: 12)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.groupFill))
        }
    }

    private func titles(_ p: Palette, hue: RunHue, whole: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(whole ? 1 : 2)
                .fixedSize(horizontal: whole, vertical: !whole)
            HStack(spacing: 5) {
                Dot(color: card.live ? p.run(hue) : p.muted2, size: 6)
                Text(card.subtitle).font(.caption).foregroundStyle(p.muted).lineLimit(1)
            }
        }
    }

    /// The Pace card's hero: the number at the hero size beside its label and, under it, the
    /// hourglass and the clock time ("done ~10:26 AM · in ~26m").
    private func heroRow(_ hero: RunHeroModel, _ p: Palette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // "82%" in one piece, as the Pace card sets it; "7/9" agents with the total quieter.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(hero.unit == "%" ? hero.number + "%" : hero.number).font(.system(size: heroSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(p.ink).contentTransition(.numericText())
                if hero.unit != "%" {
                    Text(hero.unit).font(.system(size: heroSize * 0.5, weight: .semibold).monospacedDigit()).foregroundStyle(p.muted)
                }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(hero.label).font(.subheadline.weight(.medium)).foregroundStyle(p.muted).lineLimit(1)
                if let side = hero.side {
                    HStack(spacing: 4) {
                        if hero.hourglass { Hourglass(color: p.tone(.plenty).text, height: 11) }
                        Text(hero.hourglass ? [hero.sideCaption, "in \(side)"].compactMap { $0 }.joined(separator: " · ") : [side, hero.sideCaption].compactMap { $0 }.joined(separator: " "))
                            .font(.footnote.weight(.medium).monospacedDigit()).foregroundStyle(p.muted2)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One cell per task in the meter's grammar, or the five cells when there's no map.
    @ViewBuilder private var meter: some View {
        if !card.segments.isEmpty {
            RunTaskMap(blocks: card.segments.map(RunMapBlock.init), height: 13, gap: 3)
        } else if let hero = card.hero {
            CellMeter(state: card.tone == .warn ? .tight : .plenty, cells: Int((min(max(hero.fraction, 0), 1) * 5).rounded()), height: 13)
        }
    }

    /// The Pace card's verdict: a sentence, then a quieter line (with the tokens).
    @ViewBuilder private func verdict(_ p: Palette) -> some View {
        let v = card.verdict
        let quieter = [v?.secondary, v?.figure].compactMap { $0 }.joined(separator: " · ")
        if v?.primary != nil || !quieter.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let primary = v?.primary {
                    Text(primary).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
                }
                if !quieter.isEmpty {
                    Text(quieter).font(.footnote).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The tasks under a quiet header, as the Pace card's details sit under it.
    private func rows(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if card.rows.contains(where: { $0.kind == .task }) {
                Caps(card.rowsTitle, size: 9).padding(.bottom, 4)
            }
            ForEach(card.rows) { row in RunRowView(row: row, opens: card.expandable && !card.expanded && row.id == "~more", live: card.live) }
            if card.expandable, card.expanded {
                RunRowView(row: RunRowModel(id: "~fewer", kind: .more(0), glyph: .more, tone: .quiet, title: "Show fewer"), opens: true, closes: true, live: card.live)
            }
        }
    }
}

/// What the run is asking, at the top of its card, in the 5-hour panel's grammar: a rose wash, the
/// asker beside an icon, the question, the answers offered; or where to answer when the Mac
/// doesn't share the wording.
struct RunQuestionBlock: View {
    var question: RunQuestionModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), t = p.tone(.veryTight)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: question.asker.isEmpty ? "laptopcomputer" : "exclamationmark")
                    .font(.caption.weight(.heavy)).foregroundStyle(t.text)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(t.text.opacity(0.18)))
                Text(question.asker.isEmpty ? RunWords.needsInput : question.asker)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(t.text).lineLimit(1)
            }
            Text(question.text).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).lineLimit(8).fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, o in
                        Text(o).font(.caption.weight(.semibold)).foregroundStyle(p.ink.opacity(0.88)).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.chipFill))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(p.chipBorder, lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.text.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.text.opacity(0.26), lineWidth: 0.5))
    }
}

/// The run against its provider's 5-hour window, in the 5-hour panel's grammar: what happens and
/// when, the countdown on the right, the track (working, paused, working again) with its ticks as
/// chart caps, and the forecast.
struct RunTimelineView: View {
    var timeline: RunTimelineModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), blue = p.tone(.plenty), amber = p.tone(.tight)
        let tick = { (label: String) in timeline.ticks.first { $0.label == label } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "pause.fill").font(.caption2.weight(.bold)).foregroundStyle(amber.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pauses at the 5-hour limit").font(.subheadline.weight(.semibold)).foregroundStyle(amber.text)
                    Text([tick("window empty").map { "empties \($0.time)" }, tick("resets").map { "resets \($0.time)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(p.muted)
                }
                Spacer()
                if let done = tick("done") {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(done.time).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(amber.text)
                        Caps("done", size: 8, color: amber.text.opacity(0.8))
                    }
                }
            }
            Canvas { ctx, size in
                let h: CGFloat = 6, y: CGFloat = 0
                let track = Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: 3)
                ctx.fill(track, with: .color(p.meterTrack))
                ctx.drawLayer { layer in
                    layer.clip(to: track)
                    for s in timeline.spans where s.end > s.start {
                        let r = CGRect(x: size.width * s.start, y: y, width: size.width * (s.end - s.start), height: h)
                        switch s.kind {
                        case .working:
                            layer.fill(Path(r), with: .linearGradient(Gradient(colors: [blue.top, blue.bottom]), startPoint: CGPoint(x: 0, y: y),
                                                                      endPoint: CGPoint(x: 0, y: y + h)))
                        case .paused:
                            layer.fill(Path(r), with: .color(amber.text.opacity(0.2)))
                            var stripes = Path(), x = r.minX - h
                            while x < r.maxX { stripes.move(to: CGPoint(x: x, y: y + h)); stripes.addLine(to: CGPoint(x: x + h, y: y)); x += 3.5 }
                            var inner = layer
                            inner.clip(to: Path(r))
                            inner.stroke(stripes, with: .color(amber.text.opacity(0.7)), lineWidth: 1)
                        }
                    }
                }
                for t in timeline.ticks {
                    let x = min(max(size.width * t.at, 0.5), size.width - 0.5)
                    ctx.fill(Path(CGRect(x: x - 0.5, y: h + 1.5, width: 1, height: 3)), with: .color(t.strong ? amber.text.opacity(0.8) : p.muted2))
                }
            }
            .frame(height: 10)
            HStack {
                ForEach(Array(timeline.ticks.sorted { $0.at < $1.at }.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Spacer(minLength: 4) }
                    Caps(t.label, size: 8, color: t.strong ? amber.text.opacity(0.9) : nil).fixedSize()
                }
            }
            if let note = timeline.note {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Dot(color: amber.text, size: 6)
                    Text(note).font(.footnote.weight(.medium)).foregroundStyle(p.ink.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(amber.text.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(amber.text.opacity(0.26), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// A finished run's figures as stat tiles (how long, tokens with their cost, tasks), then where
/// the time went.
struct RunReceiptView: View {
    var receipt: RunReceiptModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                tile("Took", receipt.duration, nil, p)
                tile("Tokens", receipt.tokens, receipt.cost?.replacingOccurrences(of: "about ", with: "~"), p)
                tile("Tasks", receipt.tasks, nil, p)
            }
            if receipt.time.total > 0 { RunTimeSplitView(time: receipt.time) }
        }
    }

    private func tile(_ label: String, _ value: String, _ suffix: String?, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(p.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.8)
                if let suffix { Text(suffix).font(.caption2.monospacedDigit()).foregroundStyle(p.ink.opacity(0.45)).lineLimit(1) }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.chipFill))
    }
}

/// Where a run's time went: working, waiting on you, waiting on a limit, idle.
struct RunTimeSplitView: View {
    var time: TaskTimeSplit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let parts: [(String, Double, Color)] = [("working", time.working, p.ink.opacity(0.72)), ("waiting on you", time.waitingInput, p.rose),
                                                ("on a limit", time.waitingLimit, p.amber), ("idle", time.idle, p.muted2)]
            .filter { $0.1 >= 30 }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(part.2)
                            .frame(width: max(3, (g.size.width - CGFloat(parts.count - 1) * 2) * part.1 / max(time.total, 1)))
                    }
                }
            }
            .frame(height: 6)
            FlowRow(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 4) {
                        Circle().fill(part.2).frame(width: 6, height: 6)
                        Text("\(part.0) \(RunsPresenter.duration(part.1))").font(.caption2.monospacedDigit()).foregroundStyle(p.muted)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays its children out left to right, wrapping onto new lines. Measuring and placing break the
/// lines at the same width, so the height it reports is the height it draws.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    /// Each child's origin and the total size, for children laid out within `width`.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: width.isFinite ? min(widest, width) : widest, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: proposal.width ?? bounds.width)
        for (s, o) in zip(subviews, laid.origins) {
            s.place(at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y),
                    proposal: ProposedViewSize(width: proposal.width.map { min($0, bounds.width) }, height: nil))
        }
    }
}

/// One row under a card: a task, or a summary line ("and 3 more", "4 finished", the counts).
/// `opens` marks the line that shows every row; `closes` the one that folds them again.
struct RunRowView: View {
    var row: RunRowModel
    var opens = false
    var closes = false
    /// On a live card; a finished card draws no blue.
    var live = true
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var indent: CGFloat = 16

    var body: some View {
        let p = Palette(scheme)
        let accent = live ? p.azure : p.ink.opacity(0.8)
        let summary = row.kind != .task
        let color = summary ? p.muted2 : (row.glyph == .done ? p.muted : p.run(RunHue(row.tone, glyph: row.glyph)))
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RunMarkView(RunMark(row.glyph), color: opens ? accent : color, size: 10).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title).font(summary ? (opens ? .footnote.weight(.semibold) : .footnote) : .footnote.weight(.semibold))
                        .foregroundStyle(opens ? accent : summary || row.quiet ? p.muted : p.ink).lineLimit(summary ? 2 : 1)
                    if let marker = row.marker {
                        Text(marker.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(marker == "critical" ? p.ink.opacity(0.8) : p.muted)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill((marker == "critical" ? p.ink : p.muted).opacity(0.12)))
                            .fixedSize()
                    }
                }
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(row.detailTone == .quiet ? p.muted : p.run(RunHue(row.detailTone, glyph: row.glyph))).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let steps = row.steps {
                Text(steps).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink.opacity(row.quiet ? 0.45 : 0.7)).fixedSize()
            }
            if opens {
                Image(systemName: closes ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(accent)
            }
        }
        .padding(.leading, CGFloat(row.depth) * indent)
        .padding(.vertical, 5)
    }
}

/// The amber note a limit warning gets.
struct WarningBox: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(p.amber)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(p.amber).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.amber.opacity(p.dark ? 0.10 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(p.amber.opacity(0.28), lineWidth: 0.5))
    }
}

// MARK: - Presenter to drawing

extension RunMark {
    public init(_ g: RunGlyph) {
        self = switch g {
        case .planned: .planned
        case .running: .running
        case .stale: .stale
        case .needsInput: .needsInput
        case .waiting: .waiting
        case .parked: .parked
        case .stopped: .stopped
        case .done: .done
        case .partial: .partial
        case .failed: .failed
        case .skipped: .skipped
        case .more: .more
        }
    }
}

extension RunHue {
    public init(_ t: RunTone) {
        self = switch t {
        case .progress: .progress
        case .neutral: .neutral
        case .warn: .warn
        case .alert: .alert
        case .quiet: .quiet
        }
    }

    /// Rose only for needing you: an alert on anything else (a failure) draws as `failed`.
    public init(_ t: RunTone, glyph: RunGlyph) { self = t == .alert && glyph != .needsInput ? .failed : RunHue(t) }
}

extension RunMapBlock {
    public init(_ s: RunSegment) { self.init(weight: s.weight, fill: s.fill, hue: s.failed ? .failed : RunHue(s.tone), critical: s.critical) }
}

extension RunActivityState {
    /// The Live Activity's words for a synced run, from the same presenter as the card. An
    /// observed run's ring and bar show finished agents over all agents seen.
    public static func from(_ d: RunDigest, presenter: RunsPresenter) -> RunActivityState {
        let card = presenter.card(d)
        let declared = d.hasDeclaredTasks || d.mirrored
        let total = Double(max(d.counts.total, 1))
        let detail = declared ? (card.counts ?? (d.counts.total > 0 ? d.counts.line : nil)) : card.headline
        let question = d.question?.text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
        return RunActivityState(title: card.title, stateText: card.stateText, mark: RunMark(card.glyph), hue: RunHue(card.tone, glyph: card.glyph),
                                provider: card.provider, figure: declared ? card.headline : presenter.shortFigure(d),
                                done: declared ? d.progress.done : (d.counts.total > 0 ? Double(d.counts.finished) / total : nil),
                                inFlight: declared ? d.progress.inFlight : (d.counts.total > 0 ? Double(d.counts.running) / total : nil),
                                detail: detail, finishAt: d.finishAt ?? d.etaSeconds.map { d.updatedAt.addingTimeInterval($0) },
                                subtitle: presenter.source(d), updatedAt: d.updatedAt, live: d.isLive,
                                blocks: card.segments.isEmpty ? nil : card.segments.map(RunMapBlock.init),
                                finishLow: d.finishLow, finishHigh: d.finishHigh, question: d.needsInput ? question : nil)
    }
}
