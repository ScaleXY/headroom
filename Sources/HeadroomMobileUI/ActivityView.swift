import Charts
import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// Tokens by hour for the last day, week or month, and what they would have cost at API prices.
/// Drag across the bars to price any stretch; break it down by model. Every Mac reporting an
/// account adds up here. Projects never leave the Mac, so there's no project breakdown.
struct ActivityView: View {
    var model: MobileModel
    @SceneStorage("activity.account") private var accountID: String?
    @SceneStorage("activity.range") private var rangeRaw = ActivityRange.day.rawValue
    @State private var selected: ClosedRange<Date>?
    @Environment(\.colorScheme) private var scheme

    var range: ActivityRange { ActivityRange(rawValue: rangeRaw) ?? .day }

    var body: some View {
        let p = Palette(scheme)
        let accounts = model.orderedAccounts
        let account = accounts.first { $0.id == accountID } ?? accounts.first
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let state = EmptyState.current(model) {
                    EmptyStateView(model: model, state: state)
                } else if let account {
                    if accounts.count > 1 {
                        Picker("Account", selection: Binding(get: { account.id }, set: { accountID = $0 })) {
                            ForEach(accounts) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Range", selection: $rangeRaw) {
                        ForEach(ActivityRange.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    ActivityCard(account: account, range: range, now: model.reader.now, selected: $selected)
                    HistoryPanels(model: model, account: account)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(p.pageBackground)
        .navigationTitle("Activity")
        .onChange(of: rangeRaw) { selected = nil }
        .onChange(of: accountID) { selected = nil }
    }
}

struct ActivityCard: View {
    var account: MergedAccount
    var range: ActivityRange
    var now: Date
    @Binding var selected: ClosedRange<Date>?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let presenter = ActivityPresenter(now: now, calendar: .current, locale: .current)
        let card = presenter.card(account.provider, aggregates: account.aggregates, range: range, selection: nil)
        let tone = p.tone(.plenty)
        let inSelection = selected.map { r in card.bars.filter { $0.start >= r.lowerBound && $0.start < r.upperBound } } ?? card.bars
        let tokens = inSelection.reduce(Int64(0)) { $0 + $1.tokens.total }
        let micros = inSelection.reduce(Int64(0)) { $0 + $1.micros }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NumberFormat.tokens(tokens)).font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink)
                    Text(selected == nil ? card.spanLong : selectionLabel).font(.caption).foregroundStyle(p.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(NumberFormat.dollars(micros: micros)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tone.text)
                    Text("at API prices").font(.caption).foregroundStyle(p.muted)
                }
            }
            Chart(Array(card.bars.enumerated()), id: \.offset) { _, bar in
                BarMark(x: .value("Time", bar.start, unit: unit), y: .value("Tokens", bar.tokens.total))
                    .foregroundStyle(selected.map { bar.start >= $0.lowerBound && bar.start < $0.upperBound } ?? true ? tone.text : tone.text.opacity(0.3))
                    .cornerRadius(2)
            }
            .chartXSelection(range: $selected)
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int64.self) { Text(NumberFormat.tokens(n)) } } } }
            .frame(height: 180)
            if let rows = card.breakdown[.model], !rows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(rows.prefix(6), id: \.name) { row in
                        HStack {
                            Text(row.name).font(.footnote.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                            Spacer()
                            Text(NumberFormat.dollars(micros: row.micros)).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink)
                        }
                        GeometryReader { g in
                            Capsule().fill(p.meterTrack).overlay(alignment: .leading) {
                                Capsule().fill(tone.text).frame(width: g.size.width * min(max(row.share, 0), 1))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            if let note = card.footnote { Text(note).font(.caption).foregroundStyle(p.muted2) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
    }

    var unit: Calendar.Component {
        switch range {
        case .day: .hour
        case .week: .hour
        case .month: .day
        }
    }

    var selectionLabel: String {
        guard let s = selected else { return "" }
        let copy = Copy(now: now)
        return "\(copy.when(s.lowerBound)) – \(copy.when(s.upperBound))"
    }
}
