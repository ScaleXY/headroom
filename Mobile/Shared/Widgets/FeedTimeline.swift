import AppIntents
import HeadroomKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

/// One moment of a widget: the feed as the app last left it, drawn as of `date`.
struct FeedEntry: TimelineEntry {
    let date: Date
    let feed: WidgetFeed?
    /// The configured account (`WidgetProvider.key`), nil for the most urgent.
    let account: String?
    let relevance: TimelineEntryRelevance?
}

/// Timelines that stay right between syncs: an entry every two minutes for half an hour, plus one
/// at each moment something visibly changes on its own (a reset, a forecast run-out, going stale),
/// so a 5-hour widget says "Back" at the reset even if the Mac is asleep.
enum FeedTimeline {
    static let step: TimeInterval = 120
    static let horizon: TimeInterval = 30 * 60

    static func entries(feed: WidgetFeed?, account: String?, now: Date, relevance: (WidgetProvider?, Date) -> TimelineEntryRelevance?) -> [FeedEntry] {
        var dates = (0..<Int(horizon / step)).map { now.addingTimeInterval(Double($0) * step) }
        if let feed {
            let end = now.addingTimeInterval(horizon)
            var marks: [Date] = [feed.generatedAt.addingTimeInterval(20 * 60), feed.generatedAt.addingTimeInterval(6 * 3600)]
            for p in feed.providers {
                marks += [p.session?.resetsAt, p.session?.runsOutAt, p.week?.resetsAt, p.blockedUntil].compactMap { $0 }
            }
            dates += marks.filter { $0 > now && $0 < end }
        }
        let focus = { (date: Date) in account.flatMap { feed?.account($0) } ?? feed?.focus }
        return Array(Set(dates)).sorted().map { FeedEntry(date: $0, feed: feed, account: account, relevance: relevance(focus($0), $0)) }
    }

    /// Smart Stacks raise the session when it warns or a reset is near.
    static func sessionRelevance(_ p: WidgetProvider?, _ date: Date) -> TimelineEntryRelevance? {
        guard let s = p?.session, let resetsAt = s.resetsAt, resetsAt > date, !s.isIdle else { return TimelineEntryRelevance(score: 0) }
        if s.level >= .amber { return TimelineEntryRelevance(score: 90, duration: resetsAt.timeIntervalSince(date)) }
        if resetsAt.timeIntervalSince(date) < 30 * 60 { return TimelineEntryRelevance(score: 50, duration: resetsAt.timeIntervalSince(date)) }
        return TimelineEntryRelevance(score: 10)
    }

    static func paceRelevance(_ p: WidgetProvider?, _ date: Date) -> TimelineEntryRelevance? {
        guard let w = p?.week else { return TimelineEntryRelevance(score: 0) }
        if w.state >= .tight || w.hourglass { return TimelineEntryRelevance(score: 60) }
        return TimelineEntryRelevance(score: 10)
    }

    static func burnRelevance(_ p: WidgetProvider?, _ date: Date) -> TimelineEntryRelevance? {
        let ratio = [p?.session?.burn.ratio, p?.week?.burn.ratio].compactMap { $0 }.max() ?? 0
        return TimelineEntryRelevance(score: ratio >= 1.6 ? 70 : 10)
    }

    static func lowRelevance(_ p: WidgetProvider?, _ date: Date) -> TimelineEntryRelevance? { TimelineEntryRelevance(score: 5) }

    /// The feed for previews in the widget gallery: the user's own when there is one.
    static func galleryFeed(_ context: TimelineProviderContext) -> WidgetFeed? {
        FeedFile.read() ?? (context.isPreview ? WidgetSamples.feed(.busy) : nil)
    }
}

/// Timelines for widgets configured with an account.
struct AccountTimelineProvider: AppIntentTimelineProvider {
    var relevance: @Sendable (WidgetProvider?, Date) -> TimelineEntryRelevance? = FeedTimeline.lowRelevance

    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: Date(), feed: WidgetSamples.feed(.busy), account: nil, relevance: nil)
    }

    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> FeedEntry {
        FeedEntry(date: Date(), feed: FeedTimeline.galleryFeed(context), account: configuration.account?.id, relevance: nil)
    }

    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<FeedEntry> {
        let now = Date()
        let entries = FeedTimeline.entries(feed: FeedFile.read(), account: configuration.account?.id, now: now, relevance: relevance)
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(FeedTimeline.horizon)))
    }

    func recommendations() -> [AppIntentRecommendation<SelectAccountIntent>] {
        [AppIntentRecommendation(intent: SelectAccountIntent(), description: "Most urgent account")]
    }
}
