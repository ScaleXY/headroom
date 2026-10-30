import HeadroomKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

// The complications: the same kinds, configuration and views on the iPhone and iPad Lock Screen
// and on Apple Watch faces (where corners are added).

struct SessionComplication: Widget {
    var body: some WidgetConfiguration { complication(.session, relevance: FeedTimeline.sessionRelevance) }
}

struct WeekComplication: Widget {
    var body: some WidgetConfiguration { complication(.week, relevance: FeedTimeline.paceRelevance) }
}

struct PaceComplication: Widget {
    var body: some WidgetConfiguration { complication(.pace, relevance: FeedTimeline.paceRelevance) }
}

struct BurnComplication: Widget {
    var body: some WidgetConfiguration { complication(.burn, relevance: FeedTimeline.burnRelevance) }
}

@MainActor
private func complication(_ kind: ComplicationKind, relevance: @escaping @Sendable (WidgetProvider?, Date) -> TimelineEntryRelevance?) -> some WidgetConfiguration {
    AppIntentConfiguration(kind: kind.kind, intent: SelectAccountIntent.self, provider: AccountTimelineProvider(relevance: relevance)) { entry in
        ComplicationEntryView(kind: kind, entry: entry)
    }
    .configurationDisplayName(kind.title)
    .description(kind.summary)
    .supportedFamilies(kind.shapes.compactMap(\.family))
}

extension AccessoryShape {
    var family: WidgetFamily? {
        switch self {
        case .circular: .accessoryCircular
        case .rectangular: .accessoryRectangular
        case .inline: .accessoryInline
        case .corner:
            #if os(watchOS)
            .accessoryCorner
            #else
            nil
            #endif
        }
    }

    init(_ family: WidgetFamily) {
        switch family {
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline: self = .inline
        #if os(watchOS)
        case .accessoryCorner: self = .corner
        #endif
        default: self = .circular
        }
    }
}

struct ComplicationEntryView: View {
    var kind: ComplicationKind
    var entry: FeedEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let feed = entry.feed
        let focus = entry.account.flatMap { feed?.account($0) } ?? feed?.focus
        let second = feed?.providers
            .filter { ($0.week != nil || $0.session != nil) && $0.isActive != false && $0.key != focus?.key }
            .max { ($0.week.map { Double($0.state.rawValue) } ?? 0) < ($1.week.map { Double($0.state.rawValue) } ?? 0) }
        ComplicationView(kind: kind, shape: AccessoryShape(family), provider: focus, second: entry.account == nil ? second : nil,
                         generatedAt: feed?.generatedAt, now: entry.date)
            .environment(\.accessoryTint, mode == .fullColor ? .color : .mono)
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "headroom://account/\(focus?.key ?? "")"))
    }
}
