#if os(iOS)
import AppIntents
import HeadroomKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

// Home Screen, Today View and StandBy widgets for iPhone and iPad: the Mac's three desktop widgets
// plus Accounts and Activity, each configurable per account.

struct PaceHomeWidget: Widget {
    var body: some WidgetConfiguration { home(.pace, relevance: FeedTimeline.paceRelevance) }
}

struct BurnHomeWidget: Widget {
    var body: some WidgetConfiguration { home(.burn, relevance: FeedTimeline.burnRelevance) }
}

struct SessionHomeWidget: Widget {
    var body: some WidgetConfiguration { home(.session, relevance: FeedTimeline.sessionRelevance) }
}

struct ActivityHomeWidget: Widget {
    var body: some WidgetConfiguration { home(.activity, relevance: FeedTimeline.lowRelevance) }
}

struct AccountsHomeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HeadroomWidgetKind.accounts.kind, intent: AccountsWidgetIntent.self, provider: AccountsTimelineProvider()) { entry in
            HomeEntryView(kind: .accounts, entry: entry.base, filter: entry.filter, includeInactive: entry.includeInactive)
        }
        .configurationDisplayName(HeadroomWidgetKind.accounts.title)
        .description(HeadroomWidgetKind.accounts.summary)
        .supportedFamilies(HeadroomWidgetKind.accounts.families)
        .contentMarginsDisabled()
        .disfavoredLocations([.iPhoneWidgetsOnMac], for: HeadroomWidgetKind.accounts.families)
    }
}

@MainActor
private func home(_ kind: HeadroomWidgetKind, relevance: @escaping @Sendable (WidgetProvider?, Date) -> TimelineEntryRelevance?) -> some WidgetConfiguration {
    AppIntentConfiguration(kind: kind.kind, intent: SelectAccountIntent.self, provider: AccountTimelineProvider(relevance: relevance)) { entry in
        HomeEntryView(kind: kind, entry: entry)
    }
    .configurationDisplayName(kind.title)
    .description(kind.summary)
    .supportedFamilies(kind.families)
    .contentMarginsDisabled()
    // The Mac has its own, fresher, desktop widgets.
    .disfavoredLocations([.iPhoneWidgetsOnMac], for: kind.families)
}

struct HomeEntryView: View {
    var kind: HeadroomWidgetKind
    var entry: FeedEntry
    var filter: AccountsFilter = .all
    var includeInactive = false
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.showsWidgetContainerBackground) private var hasBackground

    var body: some View {
        HeadroomWidgetView(kind: kind, family: family, feed: entry.feed, now: entry.date, account: entry.account,
                           filter: filter, includeInactive: includeInactive, trackButton: trackButton)
            .environment(\.accessoryTint, mode == .fullColor ? .color : .mono)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .containerBackground(for: .widget) {
                // Tinted and clear Home Screens, and StandBy, draw their own background.
                if mode == .fullColor && hasBackground {
                    HeadroomWidgetView.surface(kind: kind, feed: entry.feed, account: entry.account)
                } else {
                    Color.clear
                }
            }
            .widgetURL(URL(string: kind == .activity ? "headroom://activity" : "headroom://account/\(entry.account ?? entry.feed?.focus?.key ?? "")"))
    }

    /// The large 5-hour widget's Track button: starts or stops the Live Activity.
    private var trackButton: AnyView? {
        guard kind == .session, family == .systemLarge, let feed = entry.feed,
              let p = entry.account.flatMap(feed.account) ?? feed.focus(for: .session),
              p.session.map({ !$0.isIdle }) == true else { return nil }
        return AnyView(
            Button(intent: TrackSessionIntent(accountID: p.key)) {
                Label("Track", systemImage: "livephoto").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        )
    }
}

// MARK: - Accounts

struct AccountsEntry: TimelineEntry {
    var base: FeedEntry
    var filter: AccountsFilter
    var includeInactive: Bool
    var date: Date { base.date }
    var relevance: TimelineEntryRelevance? { base.relevance }
}

struct AccountsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AccountsEntry {
        AccountsEntry(base: FeedEntry(date: Date(), feed: WidgetSamples.feed(.both), account: nil, relevance: nil), filter: .all, includeInactive: false)
    }

    func snapshot(for configuration: AccountsWidgetIntent, in context: Context) async -> AccountsEntry {
        AccountsEntry(base: FeedEntry(date: Date(), feed: FeedTimeline.galleryFeed(context), account: nil, relevance: nil),
                      filter: AccountsFilter(rawValue: configuration.provider.rawValue) ?? .all, includeInactive: configuration.includeInactive)
    }

    func timeline(for configuration: AccountsWidgetIntent, in context: Context) async -> Timeline<AccountsEntry> {
        let now = Date()
        let filter = AccountsFilter(rawValue: configuration.provider.rawValue) ?? .all
        let entries = FeedTimeline.entries(feed: FeedFile.read(), account: nil, now: now, relevance: FeedTimeline.lowRelevance)
            .map { AccountsEntry(base: $0, filter: filter, includeInactive: configuration.includeInactive) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(FeedTimeline.horizon)))
    }
}
#endif
