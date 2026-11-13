import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// The Watch app: one page per account, most urgent first. Each page leads with the 5-hour
/// session (a ring and its countdown), then the week, then the forecast and the graph. When a
/// Mac syncs agent runs they get a page of their own: first when one needs an answer, else last.
public struct WatchRootView: View {
    var model: WatchModel

    public init(model: WatchModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            let runs = model.reader.runs
            let runsFirst = runs.contains(where: \.needsInput)
            if model.accounts.isEmpty && runs.isEmpty {
                WatchEmptyView(waiting: model.reader.loaded)
            } else {
                TabView {
                    if runsFirst { WatchRunsPage(runs: runs, now: model.now) }
                    ForEach(model.accounts, id: \.key) { p in
                        WatchAccountPage(provider: p, feed: model.feed, now: model.now)
                    }
                    if !runs.isEmpty, !runsFirst { WatchRunsPage(runs: runs, now: model.now) }
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

/// Agent runs from every Mac, compact: the title (or the Mac), the state, and the percent or
/// the agent counts. Live runs first, then the last day's finished ones.
public struct WatchRunsPage: View {
    var runs: [RunDigest]
    var now: Date

    public init(runs: [RunDigest], now: Date) { self.runs = runs; self.now = now }

    public var body: some View {
        ScrollView { WatchRunsList(runs: runs, now: now) }
    }
}

/// The page's content (the PNG renderer draws it without the scroll view).
public struct WatchRunsList: View {
    var runs: [RunDigest]
    var now: Date

    public init(runs: [RunDigest], now: Date) { self.runs = runs; self.now = now }

    public var body: some View {
        let presenter = RunsPresenter(now: now, calendar: .current, locale: .current)
        let page = presenter.page(runs)
        // Whatever needs an answer leads, wherever the presenter put it.
        let cards = (page.live + page.recent).enumerated().sorted { ($0.element.needsInput ? 0 : 1, $0.offset) < ($1.element.needsInput ? 0 : 1, $1.offset) }
            .map(\.element)
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent runs").font(.headline)
            ForEach(cards) { card in
                if let run = runs.first(where: { $0.id == card.id }) {
                    WatchRunRow(card: card, figure: card.declared ? card.headline : presenter.shortFigure(run),
                                progress: card.declared ? run.progress : nil,
                                question: run.question?.text.split(whereSeparator: \.isNewline).first.map(String.init))
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct WatchRunRow: View {
    var card: RunCardModel
    var figure: String
    var progress: TaskProgress?
    /// The first line of the question, when the Mac shares its wording.
    var question: String?

    var body: some View {
        let p = Palette(.dark), hue = RunHue.of(card.tone, glyph: card.glyph)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.title).font(.footnote.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Text(figure).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(card.live ? .white : p.muted)
            }
            if card.live {
                if !card.segments.isEmpty {
                    RunTaskMap(blocks: card.segments.map { RunMapBlock(weight: $0.weight, fill: $0.fill, hue: RunHue.of($0.tone)) }, height: 4, gap: 1.5)
                } else if let progress {
                    RunProgressBar(done: progress.done, inFlight: progress.inFlight, height: 4)
                } else if let hero = card.hero {
                    // Agents counted with no plan: Pace's five cells, as far along as they've got.
                    CellMeter(state: .plenty, cells: Int((min(max(hero.fraction, 0), 1) * 5).rounded()), height: 5)
                }
            }
            if card.needsInput, let question {
                Text(question).font(.caption2).foregroundStyle(.white).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                RunMarkView(RunMark.of(card.glyph), color: p.run(hue), size: 9)
                Text(card.stateText).font(.caption2.weight(.medium)).foregroundStyle(hue == .neutral ? p.muted : p.run(hue)).lineLimit(1)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(card.needsInput ? p.rose.opacity(0.16) : Color.white.opacity(card.live ? 0.10 : 0.05)))
        .accessibilityElement(children: .combine)
    }
}

// The drawing enums share their case names with the presenter's (the iPhone maps them case by case).
extension RunMark {
    static func of(_ g: RunGlyph) -> RunMark { RunMark(rawValue: "\(g)") ?? .running }
}

extension RunHue {
    static func of(_ t: RunTone) -> RunHue { RunHue(rawValue: "\(t)") ?? .quiet }
    /// Rose only for needing you: an alert on anything else (a failure) draws as `failed`.
    static func of(_ t: RunTone, glyph: RunGlyph) -> RunHue { t == .alert && glyph != .needsInput ? .failed : of(t) }
}
