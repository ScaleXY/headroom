import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// The keys Settings and the runs list share; the Mac uses the same names for its own.
public enum RunStyleKeys {
    public static let list = "runsListStyle"
    public static let page = "runPageStyle"
}

/// Agent runs from every Mac, at the top of Now: what needs you first, then the other live runs,
/// then the last day's finished ones, in the list style Settings picks. A line opens the run's own
/// page. It's there only while some Mac syncs a run.
struct RunsSection: View {
    var model: MobileModel
    @State private var showFinished = false
    @State private var openRun: String?
    @AppStorage(RunStyleKeys.list) private var listStyle = RunsListStyle.ledger.rawValue

    var body: some View {
        let page = RunsPresenter(now: model.reader.now, calendar: .current, locale: .current).page(model.reader.runs)
        Group {
            if !page.isEmpty {
                RunsSectionContent(page: page, style: RunsListStyle(rawValue: listStyle) ?? .ledger, showFinished: $showFinished,
                                   setStyle: { s in withAnimation(.snappy) { listStyle = s.rawValue } }, open: { openRun = $0 })
            }
        }
        .navigationDestination(item: $openRun) { RunPageScreen(model: model, id: $0) }
    }
}

/// The section itself, from a page model, so the PNG renderer draws exactly what the app does.
public struct RunsSectionContent: View {
    var page: RunsPageModel
    var style: RunsListStyle
    @Binding var showFinished: Bool
    /// Picks the list style from the header's menu; no menu without it.
    var setStyle: ((RunsListStyle) -> Void)?
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(page: RunsPageModel, style: RunsListStyle = .ledger, showFinished: Binding<Bool>, setStyle: ((RunsListStyle) -> Void)? = nil,
                open: @escaping (String) -> Void = { _ in }) {
        self.page = page; self.style = style; self._showFinished = showFinished; self.setStyle = setStyle; self.open = open
    }

    public var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Agent runs").font(.headline).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
                Spacer()
                if let setStyle {
                    Menu {
                        Picker("List style", selection: Binding(get: { style }, set: { setStyle($0) })) {
                            ForEach(RunsListStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "list.bullet.below.rectangle")
                            .font(.footnote.weight(.semibold)).foregroundStyle(p.muted)
                            .frame(width: 32, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.chipFill))
                    }
                    .accessibilityLabel("List style, \(style.title)")
                }
            }
            .padding(.horizontal, 4)
            RunsListView(page: page, style: style, showFinished: $showFinished, open: open)
        }
    }
}

/// A run's own page, pushed from the list. It follows the synced run as it changes, and its menu
/// switches the page style for every run.
struct RunPageScreen: View {
    var model: MobileModel
    var id: String
    @AppStorage(RunStyleKeys.page) private var pageStyle = RunPageStyle.briefing.rawValue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let presenter = RunsPresenter(now: model.reader.now, calendar: .current, locale: .current)
        let listed = presenter.page(model.reader.runs)
        let card = (listed.live + listed.recent).first { $0.id == id } ?? model.reader.runs.first { $0.id == id }.map { presenter.card($0) }
        ScrollView {
            if let card {
                RunPageView(card: card, style: RunPageStyle(rawValue: pageStyle) ?? .briefing).padding(16)
                    .animation(.snappy, value: pageStyle)
            } else {
                ContentUnavailableView("This run isn't synced anymore", systemImage: "checklist",
                                       description: Text("Its Mac stopped sharing it, or it finished more than a day ago."))
                    .padding(.top, 80)
            }
        }
        .background(Palette(scheme).pageBackground)
        .navigationTitle(card?.live == false ? "Finished run" : "Run")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Page style", selection: $pageStyle) {
                        ForEach(RunPageStyle.allCases, id: \.self) { Label($0.title, systemImage: $0 == .briefing ? "text.alignleft" : "chart.bar.xaxis").tag($0.rawValue) }
                    }
                } label: {
                    Label("Page style", systemImage: pageStyle == RunPageStyle.lanes.rawValue ? "chart.bar.xaxis" : "text.alignleft")
                }
            }
        }
        .refreshable { await model.reader.reload() }
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
            // Answers are given in the session on the Mac, so they read as text, not buttons.
            if !question.options.isEmpty {
                (Text("Offered: ").foregroundStyle(p.muted) + Text(question.options.joined(separator: " · ")).fontWeight(.semibold).foregroundStyle(p.ink.opacity(0.8)))
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if !question.asker.isEmpty {
                Label("Answer it in the session on your Mac", systemImage: "laptopcomputer").font(.caption).foregroundStyle(p.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.text.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.text.opacity(0.26), lineWidth: 0.5))
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
        case .yourTurn: .yourTurn
        // Settled with work open: half done, as a parked task reads.
        case .left: .parked
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
