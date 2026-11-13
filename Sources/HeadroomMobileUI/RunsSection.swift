import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// Agent runs from every Mac, at the top of Now: live runs first, the last day's finished ones
/// folded below. It's there only while some Mac syncs a run. Tapping a card with more rows than
/// fit lists every row its Mac synced.
struct RunsSection: View {
    var model: MobileModel
    var columns = 1
    @State private var showFinished = false
    @State private var expanded: Set<String> = []

    var body: some View {
        let page = RunsPresenter(now: model.reader.now, calendar: .current, locale: .current).page(model.reader.runs, expanded: expanded)
        if !page.isEmpty {
            RunsSectionContent(page: page, columns: columns, showFinished: $showFinished) { id in
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
    var toggle: ((String) -> Void)?
    @Environment(\.colorScheme) private var scheme

    public init(page: RunsPageModel, columns: Int = 1, showFinished: Binding<Bool>, toggle: ((String) -> Void)? = nil) {
        self.page = page; self.columns = columns; self._showFinished = showFinished; self.toggle = toggle
    }

    public var body: some View {
        let p = Palette(scheme)
        let grid = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columns)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Agent runs").font(.headline).foregroundStyle(p.ink)
                Spacer()
                if page.live.contains(where: \.needsInput) {
                    Text(RunWords.needsInput).font(.caption.weight(.semibold)).foregroundStyle(p.rose)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
            if !page.live.isEmpty {
                LazyVGrid(columns: grid, spacing: 14) {
                    ForEach(page.live) { card in RunCardView(card: card) { toggle?(card.id) } }
                }
            }
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
                    LazyVGrid(columns: grid, spacing: 10) {
                        ForEach(page.recent) { card in RunCardView(card: card) { toggle?(card.id) } }
                    }
                    if page.moreRecent > 0 {
                        Text("+ \(page.moreRecent) more").font(.caption).foregroundStyle(p.muted).padding(.horizontal, 4)
                    }
                }
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
    @ScaledMetric(relativeTo: .title) private var headlineSize: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 24

    public init(card: RunCardModel, toggle: (() -> Void)? = nil) { self.card = card; self.toggle = toggle }

    public var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            if let q = card.question { RunQuestionBlock(question: q).padding(.top, 12) }
            if card.live { liveFigures(p) } else if let receipt = card.receipt { RunReceiptView(receipt: receipt).padding(.top, 12) } else { finishedLine(p) }
            if let timeline = card.timeline { RunTimelineView(timeline: timeline).padding(.top, 12) }
            if let warning = card.warning { WarningBox(text: warning).padding(.top, 10) }
            if !card.rows.isEmpty {
                Rectangle().fill(p.separator).frame(height: 0.5).padding(.top, card.live ? 12 : 10).padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(card.rows) { row in RunRowView(row: row, opens: card.expandable && !card.expanded && row.id == "~more", live: card.live) }
                    if card.expandable, card.expanded {
                        RunRowView(row: RunRowModel(id: "~fewer", kind: .more(0), glyph: .more, tone: .quiet, title: "Show fewer"), opens: true, closes: true, live: card.live)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, card.rows.isEmpty ? 13 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(p))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { if card.expandable { toggle?() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(card.expandable ? .isButton : [])
        .accessibilityHint(card.expandable ? (card.expanded ? "Shows fewer tasks" : "Shows every task") : "")
    }

    @ViewBuilder private func header(_ p: Palette) -> some View {
        if !card.live, card.receipt != nil {
            // A receipt card says how it ended beside the title when the subtitle still fits whole,
            // else beneath it.
            let capsule = RunStateCapsule(card.stateText, hue: RunHue(card.tone, glyph: card.glyph)).fixedSize()
            ViewThatFits(in: .horizontal) {
                headerRow(p, wholeSubtitle: true) { capsule }
                VStack(alignment: .leading, spacing: 8) {
                    headerRow(p, wholeSubtitle: false) { EmptyView() }
                    capsule.padding(.leading, tile + 10)
                }
            }
        } else {
            headerRow(p, wholeSubtitle: false) { EmptyView() }
        }
    }

    private func headerRow(_ p: Palette, wholeSubtitle: Bool, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if card.live, let provider = card.provider {
                BrandTile(provider: provider, size: tile)
            } else {
                RunMarkView(RunMark(card.glyph), color: p.run(RunHue(card.tone, glyph: card.glyph)), size: 12).frame(width: tile, height: tile)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(card.live ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                    .foregroundStyle(card.live ? p.ink : p.ink.opacity(0.85)).lineLimit(2)
                Text(card.subtitle).font(.caption).foregroundStyle(p.muted).lineLimit(1).fixedSize(horizontal: wholeSubtitle, vertical: false)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }

    /// "1h 12m working · must-haves 1 of 2 · 20–35m left · 2.31M tokens".
    private var figureLine: String? {
        let parts = [card.elapsed].compactMap { $0 } + card.figures
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func liveFigures(_ p: Palette) -> some View {
        let capsule = RunStateCapsule(card.stateText, hue: RunHue(card.tone, glyph: card.glyph))
        VStack(alignment: .leading, spacing: 8) {
            if card.declared {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) { percent(p, estimate: true); Spacer(minLength: 4); capsule }
                    HStack(alignment: .center, spacing: 8) { percent(p, estimate: false); Spacer(minLength: 4); capsule }
                    VStack(alignment: .leading, spacing: 6) { percent(p, estimate: false); capsule }
                }
                if !card.segments.isEmpty {
                    RunTaskMap(blocks: card.segments.map(RunMapBlock.init), height: 8).padding(.top, 1)
                } else if let bar = card.bar {
                    RunProgressBar(done: bar.done, inFlight: bar.inFlight)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { Text(card.headline).font(.callout.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1); Spacer(minLength: 4); capsule }
                    VStack(alignment: .leading, spacing: 6) { Text(card.headline).font(.callout.weight(.semibold)).foregroundStyle(p.ink); capsule }
                }
            }
            if let line = figureLine {
                Text(line).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
    }

    private func percent(_ p: Palette, estimate: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(card.headline).font(.system(size: headlineSize, weight: .bold).monospacedDigit()).foregroundStyle(p.ink).fixedSize()
            Text(card.counts ?? "done").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1).fixedSize()
            if estimate, let e = card.estimate {
                Text(e + " by tokens").font(.caption.weight(.medium)).foregroundStyle(p.muted2).fixedSize()
            }
        }
    }

    private func finishedLine(_ p: Palette) -> some View {
        let line = ([card.declared ? card.headline + " done" : card.headline] + [card.elapsed].compactMap { $0 } + card.figures).joined(separator: " · ")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(line).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                Spacer(minLength: 4)
                RunStateCapsule(card.stateText, hue: RunHue(card.tone, glyph: card.glyph))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(line).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted)
                RunStateCapsule(card.stateText, hue: RunHue(card.tone, glyph: card.glyph))
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func background(_ p: Palette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if card.live {
            ZStack {
                shape.fill(p.cardSolid)
                if let provider = card.provider {
                    // The brand wash the Mac's card chrome gives a live run.
                    shape.fill(RadialGradient(colors: [BrandColors.of(provider).base.opacity(p.dark ? 0.20 : 0.10), .clear],
                                              center: .topLeading, startRadius: 0, endRadius: 260))
                }
                shape.strokeBorder(card.needsInput ? p.rose.opacity(0.45) : p.groupBorder, lineWidth: card.needsInput ? 1 : 0.5)
            }
        } else {
            // Finished: recessed and without the wash, so live work stands out above it.
            ZStack { shape.fill(p.groupFill); shape.strokeBorder(p.groupBorder, lineWidth: 0.5) }
        }
    }
}

/// What the run is asking, at the top of its card: the wording and the answers offered when the
/// Mac shares them, otherwise where to answer.
struct RunQuestionBlock: View {
    var question: RunQuestionModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 6) {
            if question.asker.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "laptopcomputer").font(.footnote.weight(.semibold)).foregroundStyle(p.rose)
                    Text(question.text).font(.footnote.weight(.semibold)).foregroundStyle(p.ink)
                }
            } else {
                Text(question.asker).font(.caption.weight(.semibold)).foregroundStyle(p.rose).lineLimit(1)
                Text(question.text).font(.subheadline).foregroundStyle(p.ink).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                if !question.options.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, o in
                            Text(o).font(.caption.weight(.semibold)).foregroundStyle(p.ink.opacity(0.85)).lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(p.ink.opacity(p.dark ? 0.08 : 0.05)))
                                .overlay(Capsule().strokeBorder(p.ink.opacity(0.14), lineWidth: 0.5))
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.rose.opacity(p.dark ? 0.10 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.rose.opacity(0.26), lineWidth: 0.5))
    }
}

/// The run against its provider's 5-hour window: working, paused at the limit, working again
/// after the reset, with the times beneath.
struct RunTimelineView: View {
    var timeline: RunTimelineModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), blue = p.tone(.plenty)
        VStack(alignment: .leading, spacing: 7) {
            Canvas { ctx, size in
                let h: CGFloat = 8, y = (size.height - h) / 2
                let track = Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: h / 2)
                ctx.fill(track, with: .color(p.meterTrack))
                ctx.drawLayer { layer in
                    layer.clip(to: track)
                    for s in timeline.spans {
                        let r = CGRect(x: size.width * s.start, y: y, width: size.width * (s.end - s.start), height: h)
                        switch s.kind {
                        case .working:
                            layer.fill(Path(r), with: .linearGradient(Gradient(colors: [blue.top, blue.bottom]), startPoint: CGPoint(x: 0, y: y),
                                                                      endPoint: CGPoint(x: 0, y: y + h)))
                        case .paused:
                            layer.fill(Path(r), with: .color(p.amber.opacity(0.22)))
                            var stripes = Path()
                            var x = r.minX - h
                            while x < r.maxX { stripes.move(to: CGPoint(x: x, y: y + h)); stripes.addLine(to: CGPoint(x: x + h, y: y)); x += 4.5 }
                            layer.clip(to: Path(r))
                            layer.stroke(stripes, with: .color(p.amber.opacity(0.75)), lineWidth: 1.4)
                        }
                    }
                }
                for t in timeline.ticks where t.at > 0.001 && t.at < 0.999 {
                    let x = size.width * t.at
                    ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(p.ink.opacity(0.55)))
                }
            }
            .frame(height: 14)
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(timeline.ticks.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Spacer(minLength: 2) }
                    VStack(alignment: i == 0 ? .leading : i == timeline.ticks.count - 1 ? .trailing : .center, spacing: 1) {
                        Text(t.label).font(.caption2).foregroundStyle(p.muted).lineLimit(1)
                        Text(t.time).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(t.strong ? p.ink : p.ink.opacity(0.75)).lineLimit(1)
                    }
                    .fixedSize()
                }
            }
            if let note = timeline.note {
                Text(note).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A finished run's receipt: how long, how much, how it went, and where the time went.
struct RunReceiptView: View {
    var receipt: RunReceiptModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                stat(receipt.duration, "start to finish", p)
                stat(receipt.tokens, receipt.cost.map { "tokens · \($0)" } ?? "tokens", p)
                stat(receipt.tasks, receipt.tasksNote, p)
            }
            if receipt.time.total > 0 { RunTimeSplitView(time: receipt.time) }
            if let foot = receipt.footnote {
                Text(foot).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ value: String, _ caption: String, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.8)
            Text(caption).font(.caption2).foregroundStyle(p.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Lays its children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
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
