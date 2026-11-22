import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// The phone's screens drawn without their scroll views or navigation, at a fixed width, for the
/// PNG renderer (`HeadroomWidgetPreview --mobile`). ImageRenderer can't draw a scroll view's content.
public enum MobileScreenPreview {
    /// The Limits tab: every visible account's card, the tightest first.
    @MainActor public static func limits(_ model: MobileModel, width: CGFloat = 390) -> some View {
        VStack(spacing: 14) {
            ForEach(model.orderedAccounts) { PaceCardView(model: model, account: $0) }
        }
        .padding(16)
        .frame(width: width)
    }

    /// The first account's Limits card in full, as its account page shows it.
    @MainActor public static func limitsDetail(_ model: MobileModel, width: CGFloat = 390) -> some View {
        VStack(spacing: 14) {
            if let a = model.orderedAccounts.first { PaceCardView(model: model, account: a, full: true) }
        }
        .padding(16)
        .frame(width: width)
    }

    /// The Activity tab for a range, with cached reads counted or not.
    /// `selection` selects those bars on every card, to show the span chip.
    @MainActor public static func activity(_ model: MobileModel, range: ActivityRange, mode: ActivityMode, selection: Range<Int>? = nil,
                                           width: CGFloat = 390) -> some View {
        ActivityTabContent(model: model, rangeRaw: .constant(range.rawValue), modeRaw: .constant(mode.rawValue), initialSelection: selection)
            .padding(16)
            .frame(width: width)
    }

    /// Past weeks for every account, as the bottom of the Activity tab draws them.
    @MainActor public static func pastWeeks(_ model: MobileModel, width: CGFloat = 390) -> some View {
        let now = model.reader.now
        let weeks = model.orderedAccounts.map { ($0, HistoryPanels.weeks($0, now: now)) }.filter { !$0.1.collecting }
        return VStack(alignment: .leading, spacing: 14) {
            PastWeeksHeading()
            ForEach(weeks.indices, id: \.self) { i in PastWeeksCard(model: weeks[i].1, title: weeks[i].0.shortLabel) }
            PastWeeksLegend()
        }
        .padding(16)
        .frame(width: width)
    }
}
