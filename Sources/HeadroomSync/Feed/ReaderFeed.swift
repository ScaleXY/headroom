import Foundation
import HeadroomKit
import HeadroomPresent

/// The widget feed an iPhone, iPad or Watch writes for its widgets and complications: the Mac's
/// `WidgetFeedBuilder`, run over merged accounts, plus what only the phone's widgets draw.
@MainActor
public enum ReaderFeed {
    public static func build(_ snapshot: SyncSnapshot, now: Date, calendar: Calendar = .current, includeInactive: Bool = true) -> WidgetFeed {
        let builder = WidgetFeedBuilder(now: now)
        let edges = builder.hourEdges
        let accounts = snapshot.accounts.filter { includeInactive || $0.isActive }
        let providers = accounts.map { a -> WidgetProvider in
            let presenter = Presenter(now: now, calendar: calendar, policy: a.policy)
            let input = a.paceInput(now: now)
            let outages = a.outage.map { [a.provider: $0] } ?? [:]
            var p = builder.build([input], presenter: presenter, hourly: { _ in a.bins(edges: edges) }, outages: outages).providers[0]
            p.account = a.id
            p.email = a.email
            p.shortLabel = a.shortLabel
            p.sourceDevice = a.sourceDevice
            p.isActive = a.isActive
            p.hourlyCostUSD = a.bins(edges: edges).map { ($0.dollars * 100).rounded() / 100 }
            let week = (0...168).map { now.addingTimeInterval(Double($0 - 168) * 3600) }
            p.hourly7d = a.bins(edges: week).map(\.tokens)
            p.topModels = topModels(a, since: now.addingTimeInterval(-7 * 86400), now: now)
            let today = calendar.startOfDay(for: now)
            let days = (0...30).compactMap { calendar.date(byAdding: .day, value: $0 - 29, to: today) }
            p.daily30 = zip(days, a.bins(edges: days)).map { WidgetDay(start: $0, tokens: $1.tokens, costUSD: ($1.dollars * 100).rounded() / 100) }
            p.recentSessions = a.history.recentSessions(now: now).suffix(8).map {
                WidgetSessionSummary(resetsAt: $0.resetsAt, peak: $0.peakUsed, hitLimit: $0.hitLimit)
            }
            p.pastWeeks = a.history.weeks.suffix(6).map { WidgetWeekSummary(end: $0.scheduledEnd, finalUsed: $0.finalUsed, ranOut: $0.ranOut) }
            p.planWeeklyUSD = (a.planMonthlyOverride ?? a.reading?.plan?.monthlyPriceUSD).map { ($0 * 12 / 52 * 100).rounded() / 100 }
            return p
        }
        // Widgets call a feed stale when the Macs have gone quiet, not when this device last wrote.
        return WidgetFeed(generatedAt: snapshot.lastHeard ?? now, providers: providers)
    }

    static func topModels(_ a: MergedAccount, since: Date, now: Date) -> [WidgetModelShare] {
        let lo = ActivitySlot.slot(for: since), hi = ActivitySlot.slot(for: now)
        var byModel: [String: (tokens: Int64, micros: Int64)] = [:]
        for s in a.activity where s.slot >= lo && s.slot <= hi {
            byModel[s.model, default: (0, 0)].tokens += s.tokens.total
            byModel[s.model, default: (0, 0)].micros += s.micros
        }
        return byModel.sorted { $0.value.tokens > $1.value.tokens }.prefix(3).map {
            WidgetModelShare(name: $0.key, tokens: $0.value.tokens, costUSD: (Double($0.value.micros) / 10_000).rounded() / 100)
        }
    }
}
