import HeadroomKit
import HeadroomWidgetUI
import SwiftUI

/// The Watch app: one page per account, most urgent first. Each page leads with the 5-hour
/// session (a ring and its countdown), then the week, then the forecast and the graph.
public struct WatchRootView: View {
    var model: WatchModel

    public init(model: WatchModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            if model.accounts.isEmpty {
                WatchEmptyView(waiting: model.reader.loaded)
            } else {
                TabView {
                    ForEach(model.accounts, id: \.key) { p in
                        WatchAccountPage(provider: p, feed: model.feed, now: model.now)
                    }
                }
                #if os(watchOS)
                .tabViewStyle(.verticalPage)
                #endif
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct WatchAccountPage: View {
    var provider: WidgetProvider
    var feed: WidgetFeed
    var now: Date
    #if os(watchOS)
    @Environment(\.isLuminanceReduced) private var dimmed
    #else
    private let dimmed = false
    #endif

    var body: some View {
        let p = Palette(.dark), copy = Copy(now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    MarkShape(provider: provider.id).fill(BrandColors.of(provider.id).light).frame(width: 14, height: 14)
                    Text(provider.shortLabel ?? provider.id.displayName).font(.headline).lineLimit(1)
                    Spacer()
                    if let plan = provider.plan { Text(plan).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                }
                if let s = provider.session, let resetsAt = s.resetsAt, resetsAt > now, !s.isIdle {
                    HStack(spacing: 10) {
                        ZStack {
                            Ring(fraction: s.left, tone: p.session(s), width: 7)
                            VStack(spacing: 0) {
                                if dimmed {
                                    Text(TimeFormat.countdown(resetsAt.timeIntervalSince(now))).font(.system(size: 15, weight: .semibold).monospacedDigit())
                                } else {
                                    Countdown(now: now, to: resetsAt).font(.system(size: 15, weight: .semibold).monospacedDigit())
                                }
                                Text("5H").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .minimumScaleFactor(0.6)
                        }
                        .frame(width: 76, height: 76)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(copy.percent(s.left)) left").font(.title3.weight(.semibold).monospacedDigit())
                            Text(copy.session(s)).font(.caption2).foregroundStyle(s.outlook == .runsOut ? p.session(s).text : .secondary).lineLimit(2)
                        }
                    }
                } else {
                    Label("5-hour session ready", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                }
                if let w = provider.week {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(copy.percent(w.left)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(p.tone(w.state).text)
                            Text(w.caption).font(.caption2).foregroundStyle(.secondary)
                        }
                        CellMeter(state: w.state, cells: w.cells, caret: w.caret, height: 9)
                        Text("\(w.state.word) · \(copy.renews(w.resetsAt))").font(.caption2).foregroundStyle(.secondary)
                        if !w.verdict.isEmpty { Text(w.verdict).font(.caption2).fixedSize(horizontal: false, vertical: true) }
                        if let chart = w.chart, !dimmed {
                            GlideChartView(chart: chart, tone: p.tone(w.state), nowChip: false, labels: false).frame(height: 54)
                        }
                    }
                }
                if let recent = provider.recentSessions, !recent.isEmpty {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(recent, id: \.resetsAt) { r in
                            RoundedRectangle(cornerRadius: 1.5).fill(r.hitLimit ? p.rose : p.azure.opacity(0.7)).frame(width: 7, height: max(2, 22 * r.peak))
                        }
                    }
                    .frame(height: 24, alignment: .bottom)
                }
                Text(now.timeIntervalSince(feed.generatedAt) < 60 ? "Updated just now" : "Updated \(copy.ago(feed.generatedAt))" + (provider.sourceDevice.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct WatchEmptyView: View {
    var waiting: Bool

    var body: some View {
        VStack(spacing: 8) {
            HeadroomMarkView(size: 36)
            Text(waiting ? "Waiting for your Mac" : "Reading from iCloud…").font(.headline).multilineTextAlignment(.center)
            Text("Turn on sync in Headroom on your Mac, under Settings → iPhone & Watch.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
