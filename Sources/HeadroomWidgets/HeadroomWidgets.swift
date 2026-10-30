import HeadroomKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

/// The desktop widgets. The app writes `widgets.json` and asks WidgetKit to reload when what a
/// widget shows changes; between reloads, the timeline steps every couple of minutes so countdowns
/// and "updated … ago" stay true.
@main
struct HeadroomWidgetBundle: WidgetBundle {
    var body: some Widget {
        BurnometerWidget()
        PaceWidget()
        SessionWidget()
    }
}

struct FeedEntry: TimelineEntry {
    let date: Date
    let feed: WidgetFeed?
}

struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: Date(), feed: WidgetSamples.feed(.busy))
    }

    /// The gallery shows your own numbers when Headroom has them, a sample otherwise.
    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        let live = WidgetFeed.read()
        completion(FeedEntry(date: Date(), feed: live ?? (context.isPreview ? WidgetSamples.feed(.busy) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        let now = Date(), feed = WidgetFeed.read()
        let entries = (0..<15).map { FeedEntry(date: now.addingTimeInterval(Double($0) * 120), feed: feed) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct EntryView: View {
    var kind: HeadroomWidgetKind
    var entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        HeadroomWidgetView(kind: kind, family: family, feed: entry.feed, now: entry.date)
            .containerBackground(for: .widget) { HeadroomWidgetView.surface(kind: kind, feed: entry.feed) }
            .widgetURL(URL(string: "headroom://open"))
    }
}

struct BurnometerWidget: Widget {
    var body: some WidgetConfiguration { configuration(.burn) }
}

struct PaceWidget: Widget {
    var body: some WidgetConfiguration { configuration(.pace) }
}

struct SessionWidget: Widget {
    var body: some WidgetConfiguration { configuration(.session) }
}

@MainActor
private func configuration(_ kind: HeadroomWidgetKind) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.kind, provider: FeedProvider()) { EntryView(kind: kind, entry: $0) }
        .configurationDisplayName(kind.title)
        .description(kind.summary)
        .supportedFamilies(kind.families)
        .contentMarginsDisabled()
}
