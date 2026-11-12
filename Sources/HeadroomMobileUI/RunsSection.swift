import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// Agent runs from every Mac, at the top of Now: live runs first, the last day's finished ones
/// folded below. It's there only while some Mac syncs a run.
struct RunsSection: View {
    var model: MobileModel
    var columns = 1
    @State private var showFinished = false

    var body: some View {
        let page = RunsPresenter(now: model.reader.now, calendar: .current, locale: .current).page(model.reader.runs)
        if !page.isEmpty {
            RunsSectionContent(page: page, columns: columns, showFinished: $showFinished)
        }
    }
}

/// The section itself, from a page model, so the PNG renderer draws exactly what the app does.
public struct RunsSectionContent: View {
    var page: RunsPageModel
    var columns: Int
    @Binding var showFinished: Bool
    @Environment(\.colorScheme) private var scheme

    public init(page: RunsPageModel, columns: Int = 1, showFinished: Binding<Bool>) {
        self.page = page; self.columns = columns; self._showFinished = showFinished
    }

    public var body: some View {
        let p = Palette(scheme)
        let grid = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columns)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Agent runs").font(.headline).foregroundStyle(p.ink)
                Spacer()
                if page.live.contains(where: \.needsInput) {
                    Text("Needs you").font(.caption.weight(.semibold)).foregroundStyle(p.rose)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
            if !page.live.isEmpty {
                LazyVGrid(columns: grid, spacing: 14) {
                    ForEach(page.live) { RunCardView(card: $0) }
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
                        ForEach(page.recent) { RunCardView(card: $0) }
                    }
                    if page.moreRecent > 0 {
                        Text("+ \(page.moreRecent) more").font(.caption).foregroundStyle(p.muted).padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}

/// One run, as the Mac's Runs tab draws it: title, the state capsule, the three-part bar for a
/// declared plan or agent counts, the figures, the warning, and the rows or the counts line.
public struct RunCardView: View {
    public var card: RunCardModel
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title) private var headlineSize: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 24

    public init(card: RunCardModel) { self.card = card }

    public var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            if card.live { liveFigures(p) } else { finishedLine(p) }
            if let warning = card.warning { WarningBox(text: warning).padding(.top, 10) }
            if !card.rows.isEmpty {
                Rectangle().fill(p.separator).frame(height: 0.5).padding(.top, card.live ? 12 : 9).padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(card.rows) { RunRowView(row: $0) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, card.rows.isEmpty ? 13 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(p))
        .accessibilityElement(children: .combine)
    }

    private func header(_ p: Palette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if card.live, let provider = card.provider {
                BrandTile(provider: provider, size: tile)
            } else {
                RunMarkView(RunMark(card.glyph), color: p.run(RunHue(card.tone)), size: 12).frame(width: tile, height: tile)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(card.live ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                    .foregroundStyle(card.live ? p.ink : p.ink.opacity(0.85)).lineLimit(2)
                Text(card.subtitle).font(.caption).foregroundStyle(p.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func liveFigures(_ p: Palette) -> some View {
        let capsule = RunStateCapsule(card.stateText, hue: RunHue(card.tone))
        VStack(alignment: .leading, spacing: 8) {
            if card.declared {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) { percent(p, estimate: true); Spacer(minLength: 4); capsule }
                    HStack(alignment: .center, spacing: 8) { percent(p, estimate: false); Spacer(minLength: 4); capsule }
                    VStack(alignment: .leading, spacing: 6) { percent(p, estimate: false); capsule }
                }
                if let bar = card.bar { RunProgressBar(done: bar.done, inFlight: bar.inFlight) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { Text(card.headline).font(.callout.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1); Spacer(minLength: 4); capsule }
                    VStack(alignment: .leading, spacing: 6) { Text(card.headline).font(.callout.weight(.semibold)).foregroundStyle(p.ink); capsule }
                }
            }
            if !card.figures.isEmpty {
                Text(card.figures.joined(separator: " · ")).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
    }

    private func percent(_ p: Palette, estimate: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(card.headline).font(.system(size: headlineSize, weight: .bold).monospacedDigit()).foregroundStyle(p.ink).fixedSize()
            Text("done").font(.footnote.weight(.semibold)).foregroundStyle(p.muted).fixedSize()
            if estimate, let e = card.estimate {
                Text(e + " by tokens").font(.caption.weight(.medium)).foregroundStyle(p.muted2).fixedSize()
            }
        }
    }

    private func finishedLine(_ p: Palette) -> some View {
        let line = ([card.declared ? card.headline + " done" : card.headline] + card.figures).joined(separator: " · ")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(line).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                Spacer(minLength: 4)
                RunStateCapsule(card.stateText, hue: RunHue(card.tone))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(line).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted)
                RunStateCapsule(card.stateText, hue: RunHue(card.tone))
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

/// One row under a card: a task, or a summary line ("and 3 more", "4 finished", the counts).
struct RunRowView: View {
    var row: RunRowModel
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var indent: CGFloat = 16

    var body: some View {
        let p = Palette(scheme)
        let summary = row.kind != .task
        let color = summary ? p.muted2 : (row.glyph == .done ? p.muted : p.run(RunHue(row.tone)))
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RunMarkView(RunMark(row.glyph), color: color, size: 10).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title).font(summary ? .footnote : .footnote.weight(.semibold))
                        .foregroundStyle(summary || row.quiet ? p.muted : p.ink).lineLimit(summary ? 2 : 1)
                    if let marker = row.marker {
                        Text(marker.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(marker == "critical" ? p.ink.opacity(0.8) : p.muted)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill((marker == "critical" ? p.ink : p.muted).opacity(0.12)))
                            .fixedSize()
                    }
                }
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(row.detailTone == .quiet ? p.muted : p.run(RunHue(row.detailTone))).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let steps = row.steps {
                Text(steps).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink.opacity(row.quiet ? 0.45 : 0.7)).fixedSize()
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
}

extension RunActivityState {
    /// The Live Activity's words for a synced run, from the same presenter as the card.
    public static func from(_ d: RunDigest, presenter: RunsPresenter) -> RunActivityState {
        let card = presenter.card(d)
        let declared = d.hasDeclaredTasks
        let detail = declared ? (d.counts.total > 0 ? d.counts.line : nil) : card.headline
        return RunActivityState(title: card.title, stateText: card.stateText, mark: RunMark(card.glyph), hue: RunHue(card.tone),
                                provider: card.provider, figure: presenter.shortFigure(d), done: declared ? d.progress.done : nil,
                                inFlight: declared ? d.progress.inFlight : nil, detail: detail,
                                finishAt: d.etaSeconds.map { d.updatedAt.addingTimeInterval($0) }, subtitle: presenter.source(d), updatedAt: d.updatedAt, live: d.isLive)
    }
}
