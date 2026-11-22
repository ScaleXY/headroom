import Foundation
import HeadroomKit

// The Mac's Runs tab with the user's other Macs on it: this Mac's runs as it folded them, and the
// ones the others synced, in one list.

extension RunsPresenter {
    /// This Mac's `runs` and the `remote` ones its other Macs synced, as one page. Live runs are
    /// most pressing first across both (the order `sortedForDisplay` and `RunMerge.digests` share),
    /// with the runs of a Mac gone quiet after every run still heard from; finished runs are newest
    /// first across both and share the cap. This Mac's runs keep their own rules (hidden never
    /// shows, one waiting on you stays however long); synced runs drop out after a day. A synced
    /// card has no actions: its session isn't on this Mac.
    public func page(_ runs: [TaskRun], remote: [RunDigest], expanded: Set<String> = [], opened: Set<String> = [],
                     allRecent: Bool = false) -> RunsPageModel {
        guard !remote.isEmpty else { return page(runs, expanded: expanded, opened: opened, allRecent: allRecent) }
        struct Entry {
            var id: String
            var title: String
            var updatedAt: Date
            var attention: TaskAttention
            var finished: Bool
            /// Its Mac stopped syncing mid-run.
            var away: Bool
            var card: (_ sayStart: Bool) -> RunCardModel
        }
        var entries: [Entry] = []
        for r in runs where !r.hidden && (now.timeIntervalSince(r.updatedAt) < Self.recentWindow || (!Self.isFinished(r) && r.needsInput)) {
            entries.append(Entry(id: r.id, title: baseTitle(r), updatedAt: r.updatedAt, attention: r.attention, finished: Self.isFinished(r), away: false) {
                card(r, expanded: expanded.contains(r.id), sayStart: $0, opened: opened)
            })
        }
        for d in remote where now.timeIntervalSince(d.updatedAt) < Self.recentWindow {
            entries.append(Entry(id: d.id, title: baseTitle(d), updatedAt: d.updatedAt, attention: d.attention, finished: d.state.isTerminal,
                                 away: d.lastSeen != nil) {
                var c = card(d, expanded: expanded.contains(d.id), sayStart: $0)
                c.mac = d.mac
                return c
            })
        }
        let live = entries.filter { !$0.finished }.sorted { a, b in
            if a.away != b.away { return b.away }
            return (a.attention, b.updatedAt, a.id) < (b.attention, a.updatedAt, b.id)
        }
        let finished = entries.filter(\.finished).sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let recent = Array(finished.prefix(allRecent ? Self.recentExpandedCap : Self.recentCap))
        // Runs with the same name say when they started, whichever Mac they ran on.
        var counts: [String: Int] = [:]
        for e in live + recent { counts[e.title, default: 0] += 1 }
        func make(_ e: Entry) -> RunCardModel { e.card((counts[e.title] ?? 0) > 1) }
        return RunsPageModel(live: live.map(make), recent: recent.map(make), moreRecent: finished.count - recent.count,
                             allRecent: allRecent && finished.count > Self.recentCap)
    }
}
