import Charts
import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// Tokens by hour for the last day, week or month, and what they would have cost at API prices,
/// as the Mac's Activity tab draws them: a summary across every account first, then a card per
/// account (drag across the bars to price any stretch), then past weeks. Every Mac reporting an
/// account adds up here. Projects never leave the Mac, so there's no project breakdown.
struct ActivityView: View {
    var model: MobileModel
    @SceneStorage("activity.range") private var rangeRaw = ActivityRange.day.rawValue
    /// The "Include cached reads" switch, as `ActivityMode`'s raw value.
    @SceneStorage("activity.mode") private var modeRaw = ActivityMode.all.rawValue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            Group {
                if let state = EmptyState.current(model) {
                    EmptyStateView(model: model, state: state)
                } else {
                    ActivityTabContent(model: model, rangeRaw: $rangeRaw, modeRaw: $modeRaw)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette(scheme).pageBackground)
        .navigationTitle("Activity")
    }
}

/// The Activity tab's stack (also drawn on its own by the preview renderer).
struct ActivityTabContent: View {
    var model: MobileModel
    @Binding var rangeRaw: Int
    @Binding var modeRaw: Int
    /// Bars selected when the cards first draw (the preview renderer's span chip).
    var initialSelection: Range<Int>? = nil
    @Environment(\.colorScheme) private var scheme

    var range: ActivityRange { ActivityRange(rawValue: rangeRaw) ?? .day }
    var mode: ActivityMode { ActivityMode(rawValue: modeRaw) ?? .all }

    var body: some View {
        let p = Palette(scheme), now = model.reader.now
        // Claude before Codex, as the summary's split reads.
        let accounts = model.orderedAccounts.enumerated().sorted { ($0.element.provider, $0.offset) < ($1.element.provider, $1.offset) }.map(\.element)
        let presenter = ActivityPresenter(now: now, calendar: .current, locale: .current)
        let heading = presenter.rangeTitle(range)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(heading.title).font(.headline).foregroundStyle(p.ink)
                    if !heading.since.isEmpty { Text(heading.since).font(.caption).foregroundStyle(p.muted) }
                }
                Spacer(minLength: 0)
                RangeControl(rangeRaw: $rangeRaw)
            }
            if !accounts.isEmpty {
                SummaryCard(summary: summary(accounts, presenter: presenter), includeCached: Binding(
                    get: { mode.includesCachedReads },
                    set: { modeRaw = ($0 ? ActivityMode.all : .newOnly).rawValue }))
            }
            ForEach(accounts) { account in
                ActivityCard(account: account, title: title(account, in: accounts), range: range, mode: mode, now: now, initialSelection: initialSelection)
            }
            let weeks = accounts.map { ($0, HistoryPanels.weeks($0, now: now)) }.filter { !$0.1.collecting }
            if !weeks.isEmpty {
                PastWeeksHeading().padding(.top, 8)
                ForEach(weeks.indices, id: \.self) { i in
                    PastWeeksCard(model: weeks[i].1, title: title(weeks[i].0, in: accounts))
                }
                PastWeeksLegend()
            }
        }
    }

    /// The provider's name, or the account's short label when two accounts share a provider.
    private func title(_ a: MergedAccount, in all: [MergedAccount]) -> String {
        all.filter { $0.provider == a.provider }.count > 1 ? a.shortLabel : a.provider.displayName
    }

    /// The whole range across every account, one slice per provider.
    private func summary(_ accounts: [MergedAccount], presenter: ActivityPresenter) -> ActivitySummaryModel {
        let providers = Array(Set(accounts.map(\.provider))).sorted()
        let cards = providers.map { p in
            presenter.card(p, aggregates: accounts.filter { $0.provider == p }.flatMap(\.aggregates), range: range, selection: nil)
        }
        return presenter.summary(cards, range: range, mode: mode)
    }
}

/// 24H · 7D · 30D, as the Mac's control row draws it.
struct RangeControl: View {
    @Binding var rangeRaw: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 2) {
            ForEach(ActivityRange.allCases, id: \.rawValue) { r in
                let on = r.rawValue == rangeRaw
                Button {
                    rangeRaw = r.rawValue
                } label: {
                    Text(r.label)
                        .font(.footnote.weight(on ? .bold : .semibold).monospacedDigit())
                        .foregroundStyle(on ? p.ink : p.muted)
                        .frame(width: 46, height: 28)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.dark ? Color.white.opacity(0.12) : .white)
                                    .shadow(color: .black.opacity(p.dark ? 0 : 0.08), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)))
    }
}

// MARK: - Summary

/// The API value of the range across every account, the "Include cached reads" switch and the
/// split between Claude and Codex in 20 meter cells (redesign §5).
struct SummaryCard: View {
    var summary: ActivitySummaryModel
    @Binding var includeCached: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let money = NumberFormat.dollars(micros: summary.micros, style: .precise)
        let (whole, cents) = Self.split(money)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(summary.eyebrow.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(p.muted).lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Toggle("Include cached reads", isOn: $includeCached).toggleStyle(InkSwitchStyle())
            }
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    let centsText = Text(cents ?? "").font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(p.ink.opacity(0.55))
                    Text("\(Text(whole).font(.system(size: 40, weight: .bold).monospacedDigit()).tracking(-1.8).foregroundStyle(p.ink))\(centsText)")
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("what this would cost at API rates").font(.footnote.weight(.medium)).foregroundStyle(p.muted).lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(NumberFormat.tokens(summary.tokens)).font(.system(size: 18, weight: .bold).monospacedDigit()).foregroundStyle(p.ink)
                    Text(summary.tokensCaption).font(.caption.weight(.medium)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            .padding(.top, 10)
            if summary.showsSplit, let first = summary.slices.first, let last = summary.slices.last {
                let n = ActivitySummaryModel.splitCells, k = summary.leadingCells(n)
                HStack(spacing: 2) {
                    ForEach(0..<n, id: \.self) { i in
                        UnevenRoundedRectangle(topLeadingRadius: i == 0 ? 5 : 2.5, bottomLeadingRadius: i == 0 ? 5 : 2.5,
                                               bottomTrailingRadius: i == n - 1 ? 5 : 2.5, topTrailingRadius: i == n - 1 ? 5 : 2.5)
                            .fill(p.providerTone(i < k ? first.provider : last.provider, 0.92))
                    }
                }
                .frame(height: 10)
                .padding(.top, 13)
                .accessibilityHidden(true)
                HStack {
                    legend(first, p: p)
                    Spacer(minLength: 6)
                    legend(last, p: p)
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .signatureCard(nil)
    }

    private func legend(_ slice: ActivitySummaryModel.Slice, p: Palette) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(p.providerTone(slice.provider, 0.92)).frame(width: 7, height: 7)
            BrandTile(provider: slice.provider, size: 16)
            let pct = Text(" \(Int((slice.share * 100).rounded()))%").foregroundStyle(p.ink.opacity(0.55))
            Text("\(Text("\(slice.provider.displayName) \(NumberFormat.dollars(micros: slice.micros, style: .precise))").foregroundStyle(p.ink))\(pct)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// "$218.19" → ("$218", ".19"); amounts without cents ("$12.3K") stay whole.
    static func split(_ money: String) -> (String, String?) {
        guard let dot = money.lastIndex(of: "."), money.distance(from: dot, to: money.endIndex) == 3,
              money[money.index(after: dot)...].allSatisfy(\.isNumber) else { return (money, nil) }
        return (String(money[..<dot]), String(money[dot...]))
    }
}

/// A switch drawn in Headroom ink when on (not iOS green), with its label before it.
struct InkSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let p = Palette(scheme), on = configuration.isOn
        Button {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 7) {
                configuration.label.font(.caption.weight(.semibold)).foregroundStyle(p.muted).lineLimit(1)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? p.tone(.onPace).text : (p.dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)))
                    Circle().fill(on && p.dark ? Color(red: 0.075, green: 0.078, blue: 0.094) : .white)
                        .shadow(color: .black.opacity(on ? 0.2 : 0.3), radius: 1, y: 1)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

// MARK: - One account

struct ActivityCard: View {
    var account: MergedAccount
    var title: String
    var range: ActivityRange
    var mode: ActivityMode
    var now: Date
    @State private var selected: ClosedRange<Date>?
    @Environment(\.colorScheme) private var scheme

    init(account: MergedAccount, title: String, range: ActivityRange, mode: ActivityMode, now: Date, initialSelection: Range<Int>? = nil) {
        self.account = account; self.title = title; self.range = range; self.mode = mode; self.now = now
        if let sel = initialSelection {
            let starts = ActivityPresenter(now: now, calendar: .current, locale: .current).bins(for: range).starts
            if starts.indices.contains(sel.lowerBound), starts.indices.contains(sel.upperBound - 1) {
                _selected = State(initialValue: starts[sel.lowerBound]...starts[sel.upperBound - 1].addingTimeInterval(60))
            }
        }
    }

    var body: some View {
        let p = Palette(scheme)
        let presenter = ActivityPresenter(now: now, calendar: .current, locale: .current)
        let whole = presenter.card(account.provider, aggregates: account.aggregates, range: range, selection: nil)
        let card = presenter.card(account.provider, aggregates: account.aggregates, range: range, selection: Self.selection(selected, bars: whole.bars))
        let parts = card.composition(mode)
        VStack(alignment: .leading, spacing: 12) {
            header(card, p: p)
            chart(card, p: p)
            VStack(alignment: .leading, spacing: 8) {
                CompositionBar(parts: parts, provider: account.provider)
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(parts.prefix(3).enumerated()), id: \.offset) { _, part in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(p.providerTone(account.provider, part.kind.toneStrength)).frame(width: 7, height: 7)
                                Text(part.label).font(.caption2.weight(.medium)).foregroundStyle(p.muted).lineLimit(1)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(NumberFormat.tokens(part.tokens)).font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(p.ink)
                                Text(NumberFormat.percent(part.share)).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(p.ink.opacity(0.5))
                            }
                            .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let rows = card.breakdown[.model], !rows.isEmpty {
                Rectangle().fill(p.separator).frame(height: 0.5)
                VStack(spacing: 8) {
                    HStack {
                        Text("By model").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                        Spacer()
                        Text("incl. cached reads").font(.caption.weight(.medium)).foregroundStyle(p.muted2)
                    }
                    ForEach(rows.prefix(6), id: \.name) { row in
                        HStack(spacing: 8) {
                            Text(row.name).font(.footnote.weight(.medium)).foregroundStyle(p.ink).lineLimit(1).frame(width: 96, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(p.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)).overlay(alignment: .leading) {
                                    Capsule().fill(p.providerTone(account.provider, ProviderTone.modelBar))
                                        .frame(width: max(2, g.size.width * min(max(row.share, 0), 1)))
                                }
                            }
                            .frame(height: 5)
                            Text(NumberFormat.dollars(micros: row.micros, style: .precise)).font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(p.ink).frame(minWidth: 58, alignment: .trailing)
                            Text("\(Int((row.share * 100).rounded()))%").font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(p.ink.opacity(0.5)).frame(width: 32, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let note = card.footnote { Text(note).font(.caption).foregroundStyle(p.muted2) }
        }
        .padding(16)
        .signatureCard(account.provider)
        .onChange(of: range) { selected = nil }
    }

    private func header(_ card: ActivityCardModel, p: Palette) -> some View {
        HStack(alignment: .top, spacing: 9) {
            BrandTile(provider: account.provider, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(NumberFormat.tokens(card.shownTokens(mode)) + (mode.includesCachedReads ? " tokens" : " new tokens"))
                        .font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(p.muted).lineLimit(1)
                    if card.isSubRange {
                        Button {
                            selected = nil
                        } label: {
                            HStack(spacing: 5) {
                                Text(card.spanLabel).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(p.ink.opacity(0.6))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(card.spanLong). Show the whole range")
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(NumberFormat.dollars(micros: card.micros, style: .precise)).font(.system(size: 19, weight: .bold).monospacedDigit())
                    .tracking(-0.4).foregroundStyle(p.ink)
                Text("at API rates").font(.caption2.weight(.medium)).foregroundStyle(p.muted)
            }
        }
    }

    private func chart(_ card: ActivityCardModel, p: Palette) -> some View {
        let sel = card.selection
        let marks = Self.stacks(card, mode: mode)
        let domain: ClosedRange<Date> = (card.bars.first?.start ?? now)...(card.bars.last?.end ?? now)
        let colors: [Color] = marks.map { p.providerTone(account.provider, $0.part.kind.toneStrength).opacity(sel.contains($0.index) ? 1 : 0.42) }
        // A label too near the right edge would be cut short by the token axis.
        let ticks: [Date] = card.axisLabels.compactMap { $0.index < card.bars.count - card.bars.count / 12 ? card.bars[$0.index].start : nil }
        let names: [Date: String] = Dictionary(card.axisLabels.compactMap { l in
            card.bars.indices.contains(l.index) ? (card.bars[l.index].start, l.text) : nil
        }, uniquingKeysWith: { a, _ in a })
        return Chart(marks, id: \.id) { (m: Stack) in
            RectangleMark(xStart: .value("Start", m.start), xEnd: .value("End", m.end),
                    yStart: .value("Tokens", m.low), yEnd: .value("Tokens", m.high))
                .foregroundStyle(colors[m.id])
        }
        .chartXScale(domain: domain)
        .chartXSelection(range: $selected)
        .chartYAxis { yAxis(p) }
        .chartXAxis { xAxis(ticks: ticks, names: names, p: p) }
        .frame(height: 160)
        .accessibilityLabel("\(account.provider.displayName) tokens, \(card.spanLong)")
    }

    private func yAxis(_ p: Palette) -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { (v: AxisValue) in
            AxisGridLine().foregroundStyle(p.chartGrid)
            AxisValueLabel {
                if let n = v.as(Int64.self) { Text(NumberFormat.tokens(n)).foregroundStyle(p.chartLabel) }
            }
        }
    }

    private func xAxis(ticks: [Date], names: [Date: String], p: Palette) -> some AxisContent {
        AxisMarks(values: ticks) { (v: AxisValue) in
            AxisValueLabel(anchor: .topLeading) {
                if let d = v.as(Date.self), let text = names[d] { Text(text).foregroundStyle(p.chartLabel) }
            }
        }
    }

    struct Stack {
        var id: Int
        var index: Int
        var start: Date
        var end: Date
        var low: Int64
        var high: Int64
        var part: TokenPart
    }

    /// Each bar's parts stacked bottom up (output, then new input, then cached reads or cache
    /// writes on top), the bar inset a little from its bin's edges.
    static func stacks(_ card: ActivityCardModel, mode: ActivityMode) -> [Stack] {
        var out: [Stack] = []
        for (i, bar) in card.bars.enumerated() {
            let inset = bar.end.timeIntervalSince(bar.start) * 0.16
            var low: Int64 = 0
            for part in TokenPart.parts(bar.tokens, mode: mode).reversed() where part.tokens > 0 {
                out.append(Stack(id: out.count, index: i, start: bar.start.addingTimeInterval(inset), end: bar.end.addingTimeInterval(-inset),
                                 low: low, high: low + part.tokens, part: part))
                low += part.tokens
            }
        }
        return out
    }

    /// The bars a dragged date range covers, as the presenter's index range; nil for none.
    static func selection(_ dates: ClosedRange<Date>?, bars: [ActivityBar]) -> Range<Int>? {
        guard let dates else { return nil }
        let hit = bars.indices.filter { bars[$0].end > dates.lowerBound && bars[$0].start < dates.upperBound }
        guard let lo = hit.first, let hi = hit.last else { return nil }
        return lo..<(hi + 1)
    }
}

/// One 6 pt bar split into the card's three classes of tokens, in the tone ramp.
struct CompositionBar: View {
    var parts: [TokenPart]
    var provider: Provider
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let shown = parts.filter { $0.tokens > 0 }
        GeometryReader { g in
            let gaps = CGFloat(max(shown.count - 1, 0)) * 2
            let ws = Self.widths(shown.map(\.share), avail: g.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, part in
                    Rectangle().fill(p.providerTone(provider, part.kind.toneStrength)).frame(width: ws[i])
                }
            }
            .frame(width: g.size.width, alignment: .leading)
            .background(p.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    /// Widths for parts sharing `avail` points: each part with tokens gets at least `minimum`, taken from the widest.
    static func widths(_ shares: [Double], avail: CGFloat, minimum: CGFloat = 4) -> [CGFloat] {
        var widths = shares.map { $0 > 0 ? max(minimum, CGFloat($0) * avail) : 0 }
        let excess = widths.reduce(0, +) - avail
        if excess > 0, let big = widths.indices.max(by: { widths[$0] < widths[$1] }) { widths[big] = max(0, widths[big] - excess) }
        return widths
    }
}
