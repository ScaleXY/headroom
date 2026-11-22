import HeadroomKit
import HeadroomPresent
import HeadroomWidgetUI
import SwiftUI

/// How the phone's Runs section lists runs. The Mac draws one list (a lead card and two-line
/// rows); the phone keeps its three, picked in its own Settings.
public enum RunsListStyle: Int, CaseIterable, Sendable {
    /// One line per run in fixed columns: state, name, meter, figure, time.
    case ledger
    /// The name and figure, and under them what's happening, with a hairline of progress.
    case twoLine
    /// Each line is its own progress bar, tinted by state; finished runs fold into a tally.
    case fill

    public var title: String {
        switch self {
        case .ledger: "Ledger"
        case .twoLine: "Two-line"
        case .fill: "Fill rows"
        }
    }

    public var detail: String {
        switch self {
        case .ledger: "One line per run, in columns. The densest."
        case .twoLine: "Adds what each run is doing, under its name."
        case .fill: "Each line fills as the run gets along."
        }
    }
}

/// The runs list in the style the phone's Settings picks (Ledger, Two-line, Fill rows): what needs
/// you (a question, or your turn) under its own header, then the runs the agents are working on,
/// then the last day's settled ones. Every line opens the run's own page.
public struct RunsListView: View {
    var page: RunsPageModel
    var style: RunsListStyle
    @Binding var showFinished: Bool
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(page: RunsPageModel, style: RunsListStyle, showFinished: Binding<Bool>, open: @escaping (String) -> Void = { _ in }) {
        self.page = page; self.style = style; self._showFinished = showFinished; self.open = open
    }

    public var body: some View {
        let p = Palette(scheme)
        let asking = page.live.filter { $0.phase != .working }, others = page.live.filter { $0.phase == .working }
        VStack(alignment: .leading, spacing: 8) {
            if !asking.isEmpty {
                header("NEEDS YOU · \(asking.count)", color: p.rose)
                live(asking)
            }
            if !others.isEmpty {
                header("WORKING · \(others.count)", color: p.muted2).padding(.top, asking.isEmpty ? 0 : 6)
                live(others)
            }
            if !page.recent.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    header("FINISHED TODAY · \(page.recent.count + page.moreRecent)", color: p.muted2)
                    Spacer()
                    if page.moreRecent > 0 { Text("+ \(page.moreRecent) more").font(.caption).foregroundStyle(p.muted) }
                }
                .padding(.top, page.live.isEmpty ? 0 : 6)
                finished(page.recent)
            }
        }
    }

    private func header(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .bold).monospacedDigit()).tracking(1).foregroundStyle(color)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func live(_ cards: [RunCardModel]) -> some View {
        switch style {
        case .ledger: RunListGroup(cards: cards, inset: 42) { RunLedgerRow(card: $0) } open: { open($0) }
        case .twoLine: RunListGroup(cards: cards, inset: 50) { RunTwoLineRow(card: $0) } open: { open($0) }
        case .fill:
            VStack(spacing: 5) {
                ForEach(cards) { c in
                    Button { open(c.id) } label: { RunFillRow(card: c) }.buttonStyle(.plain).accessibilityHint("Opens the run")
                }
            }
        }
    }

    @ViewBuilder private func finished(_ cards: [RunCardModel]) -> some View {
        switch style {
        case .ledger: RunListGroup(cards: cards, inset: 42) { RunLedgerRow(card: $0) } open: { open($0) }
        case .twoLine: RunFoldedGroup(cards: cards, showFinished: $showFinished, open: open)
        case .fill: RunTally(cards: cards, open: open)
        }
    }
}

/// Lines in one card, a hairline between them, each opening its run.
struct RunListGroup<Row: View>: View {
    var cards: [RunCardModel]
    var inset: CGFloat
    @ViewBuilder var row: (RunCardModel) -> Row
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Rectangle().fill(p.separator).frame(height: 0.5).padding(.leading, inset).padding(.trailing, 10) }
                Button { open(c.id) } label: { row(c).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the run")
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .runGroupCard(p)
    }
}

extension View {
    /// The list's card: solid, a hairline edge.
    func runGroupCard(_ p: Palette) -> some View {
        background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.cardSolid))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.groupBorder, lineWidth: 0.5))
    }
}

// MARK: - Ledger

/// state · name · meter · figure · time · ›; a finished run: state · name · n of m · took · cost · ›.
struct RunLedgerRow: View {
    var card: RunCardModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var meterWidth: CGFloat = 34
    @ScaledMetric(relativeTo: .footnote) private var figureWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 52

    var body: some View {
        let p = Palette(scheme), c = card
        HStack(spacing: 8) {
            RunStateIcon(card: c)
            Text(c.title).font(.subheadline.weight(c.live ? .semibold : .medium)).foregroundStyle(c.live ? p.ink : p.ink.opacity(0.85)).lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if c.live {
                // Large text needs the room for the name more than the meter.
                if typeSize <= .large { RunMiniMeter(card: c).frame(width: meterWidth) }
                RunFigure(card: c, size: 15).frame(minWidth: figureWidth, alignment: .trailing)
                RunStateWord(card: c).frame(minWidth: typeSize <= .large ? timeWidth : 0, alignment: .trailing)
            } else {
                if let tasks = c.receipt?.tasks { Text(tasks).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted2).fixedSize() }
                if let took = c.receipt?.duration ?? c.hero?.side {
                    Text(took).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted).fixedSize()
                }
                Text(c.receipt?.cost.map { $0.replacingOccurrences(of: "about ", with: "~") } ?? "")
                    .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink.opacity(0.85)).fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            RunOpens()
        }
        .padding(.horizontal, 8).frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RunListText.spoken(c))
    }
}

// MARK: - Two-line

/// The name and figure, then the state's key and what's happening, over a hairline of progress.
struct RunTwoLineRow: View {
    var card: RunCardModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), c = card, tone = p.run(c.hue)
        HStack(alignment: .center, spacing: 10) {
            RunTile(card: c, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    RunFigure(card: c, size: 16)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.needsInput ? "Asks" : c.page?.status.key ?? c.stateText).font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(c.settled ? p.ink.opacity(0.75) : tone).lineLimit(1).fixedSize()
                    if let line = c.page?.line, !line.isEmpty {
                        Text(line).font(.caption.monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                RunHairline(fraction: c.hero?.fraction ?? 0, color: c.settled ? p.azure : tone).padding(.top, 3)
            }
            RunOpens()
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RunListText.spoken(c))
    }
}

struct RunHairline: View {
    var fraction: Double
    var color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let f = min(max(fraction, 0), 1)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette(scheme).meterTrack)
                if f > 0 { Capsule().fill(color).frame(width: max(g.size.width * f, 3)).shadow(color: color.opacity(0.6), radius: 3) }
            }
        }
        .frame(height: 3)
    }
}

/// The finished runs folded into one line that opens them as ledger lines.
struct RunFoldedGroup: View {
    var cards: [RunCardModel]
    @Binding var showFinished: Bool
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), o = RunOutcomes(cards)
        let tail = o.words + (o.cost.map { ["~" + NumberFormat.dollars($0, style: .precise)] } ?? [])
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { showFinished.toggle() } } label: {
                HStack(spacing: 8) {
                    RunMarkView(.done, color: p.ink.opacity(0.75), size: 9).frame(width: 22, height: 22).background(Circle().fill(p.ink.opacity(0.08)))
                    (Text(cards.count == 1 ? "1 run" : "\(cards.count) runs").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                        + Text(tail.map { " · " + $0 }.joined()).font(.footnote.monospacedDigit()).foregroundStyle(p.muted))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(p.muted2)
                        .rotationEffect(.degrees(showFinished ? 180 : 0))
                }
                .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showFinished ? "Shown" : "Hidden")
            if showFinished {
                ForEach(cards) { c in
                    Rectangle().fill(p.separator).frame(height: 0.5).padding(.leading, 42).padding(.trailing, 10)
                    Button { open(c.id) } label: { RunLedgerRow(card: c).contentShape(Rectangle()) }.buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .runGroupCard(p)
    }
}

// MARK: - Fill rows

/// A line that fills as the run gets along, tinted by its state.
struct RunFillRow: View {
    var card: RunCardModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), c = card
        let tone = c.settled ? p.azure : p.run(c.hue)
        let f = min(max(c.hero?.fraction ?? 0, 0), 1)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 9) {
            RunTile(card: c, size: 20)
            Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let hero = c.hero { Text(hero.number + hero.unit).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(p.muted).fixedSize() }
            RunStateWord(card: c)
            RunOpens()
        }
        .padding(.horizontal, 10).frame(minHeight: 44)
        .background {
            shape.fill(p.dark ? Color.white.opacity(0.04) : Color.white.opacity(0.8))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        if f > 0 {
                            let w = max(g.size.width * f, 10)
                            ZStack(alignment: .trailing) {
                                LinearGradient(colors: [tone.opacity(p.dark ? 0.07 : 0.05), tone.opacity(p.dark ? 0.26 : 0.18)], startPoint: .leading, endPoint: .trailing)
                                if f < 1 {
                                    VStack {
                                        Rectangle().fill(tone.opacity(0.9)).frame(width: 1.5, height: 5)
                                        Spacer()
                                        Rectangle().fill(tone.opacity(0.9)).frame(width: 1.5, height: 5)
                                    }
                                }
                            }
                            .frame(width: w)
                        }
                    }
                }
                .clipShape(shape)
        }
        .overlay(shape.strokeBorder(p.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 0.5))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RunListText.spoken(c))
    }
}

/// Settled runs as a tally (done, failures, left with work open, cost) and a chip per run. Closed
/// runs count with the left ones: closing is neutral and gets no tile of its own.
struct RunTally: View {
    var cards: [RunCardModel]
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), o = RunOutcomes(cards)
        var tiles: [(String, String, Color)] = [("\(o.done)", "DONE", p.ink), ("\(o.failed)", "FAILURES", o.failed > 0 ? p.run(.failed) : p.ink),
                                                ("\(o.left + o.closed)", "LEFT", p.ink)]
        if let cost = o.cost { tiles.append(("~" + NumberFormat.dollars(cost, style: .precise), "COST", p.ink)) } else { tiles.append(("\(cards.count)", "RUNS", p.ink)) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.0).font(.headline.weight(.bold).monospacedDigit()).foregroundStyle(t.2).lineLimit(1).minimumScaleFactor(0.7)
                        Text(t.1).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(p.muted2).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.dark ? Color.white.opacity(0.04) : Color.white.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                }
            }
            FlowRow(spacing: 5, lineSpacing: 5) {
                ForEach(cards) { c in
                    Button { open(c.id) } label: {
                        HStack(spacing: 6) {
                            RunMarkView(RunMark(c.glyph), color: c.glyph == .done ? p.ink.opacity(0.7) : p.run(c.hue), size: 9)
                            Text(c.title).font(.footnote.weight(.medium)).foregroundStyle(p.ink.opacity(0.85)).lineLimit(1)
                        }
                        .padding(.horizontal, 10).frame(minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.chipFill))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(p.chipBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(RunListText.spoken(c))
                    .accessibilityHint("Opens the run")
                }
            }
        }
    }
}

// MARK: - Pieces

extension RunCardModel {
    var hue: RunHue { RunHue(tone, glyph: glyph) }
    /// A settled state (done, left, closed) and your turn draw quietly.
    var settled: Bool { tone == .neutral || tone == .quiet }
}

/// The state as a glyph in a tinted disc; a quiet run's is a moon.
struct RunStateIcon: View {
    var card: RunCardModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), c = card, tone = p.run(c.hue)
        ZStack {
            Circle().fill((c.glyph == .done ? p.ink : tone).opacity(c.settled ? 0.08 : 0.15))
            if c.glyph == .stale {
                Image(systemName: "moon.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(tone)
            } else {
                RunMarkView(RunMark(c.glyph), color: c.glyph == .done ? p.ink.opacity(0.75) : tone, size: 10)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// The provider's tile with the state as a dot on its corner, as an app badge sits.
struct RunTile: View {
    var card: RunCardModel
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), c = card, tone = p.run(c.hue)
        if let provider = c.provider {
            BrandTile(provider: provider, size: size)
                .overlay(alignment: .bottomTrailing) {
                    let d = (size * 0.42).rounded()
                    Circle().fill(tone).frame(width: d, height: d)
                        .overlay(Circle().strokeBorder(p.cardSolid, lineWidth: 1.5))
                        .shadow(color: c.settled ? .clear : tone.opacity(0.7), radius: 3)
                        .offset(x: d * 0.33, y: d * 0.33)
                }
        } else {
            RunMarkView(RunMark(c.glyph), color: tone, size: size / 2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(p.chipFill))
        }
    }
}

/// The task map at line height; five cells when there's no map.
struct RunMiniMeter: View {
    var card: RunCardModel

    var body: some View {
        if !card.segments.isEmpty {
            RunTaskMap(blocks: card.segments.map(RunMapBlock.init), height: 5, gap: 1, carets: false)
        } else if let hero = card.hero {
            CellMeter(state: card.tone == .warn ? .tight : .plenty, cells: Int((min(max(hero.fraction, 0), 1) * 5).rounded()), height: 5)
        }
    }
}

/// "62%" or "7/9", in the state's colour when something's wrong.
struct RunFigure: View {
    var card: RunCardModel
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let color = card.tone == .alert || card.tone == .warn ? p.run(card.hue) : p.ink
        if let hero = card.hero {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(hero.number).font(.system(size: size, weight: .bold).monospacedDigit())
                Text(hero.unit).font(.system(size: (size * 0.72).rounded(), weight: .semibold).monospacedDigit()).opacity(0.7)
            }
            .foregroundStyle(color).lineLimit(1).fixedSize()
        }
    }
}

/// "asks" in rose, "quiet 18m" or the pause's clock in amber, "your turn", else the time left or spent.
struct RunStateWord: View {
    var card: RunCardModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), c = card
        let font = Font.caption.weight(.semibold).monospacedDigit()
        Group {
            if c.needsInput {
                Text("asks").font(font).foregroundStyle(p.rose)
            } else if c.glyph == .stale {
                Text(c.page?.status.key.lowercased() ?? "quiet").font(font).foregroundStyle(p.amber)
            } else if let limit = c.page?.limit {
                HStack(spacing: 3) {
                    Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                    Text(RunListText.shortClock(limit.pause)).font(font)
                }
                .foregroundStyle(p.amber)
            } else if let flag = c.compactFlag {
                Text(flag).font(font).foregroundStyle(flag == "waiting" ? p.muted : p.run(c.hue))
            } else if let side = c.hero?.side {
                Text(side).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(c.hero?.hourglass == true ? p.ink.opacity(0.75) : p.muted)
            }
        }
        .lineLimit(1).fixedSize()
    }
}

/// The "›" that says a line opens.
struct RunOpens: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Palette(scheme).muted2).accessibilityHidden(true)
    }
}

enum RunListText {
    /// "10:30 AM" → "10:30": the column has no room for the meridiem.
    static func shortClock(_ s: String) -> String { s.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") }

    /// What VoiceOver reads for a line: its name, state, how far along, and the pause.
    static func spoken(_ c: RunCardModel) -> String {
        var parts = [c.title, c.stateText]
        if let h = c.hero { parts.append("\(h.number)\(h.unit) \(h.label)") }
        if let caption = c.hero?.sideCaption, c.live { parts.append(caption) }
        if let limit = c.page?.limit { parts.append("pauses \(limit.pause) at the 5-hour limit") }
        return parts.joined(separator: ", ")
    }
}
