import Foundation
import HeadroomKit

// The Mac's Runs tab with the user's other Macs on it: this Mac's runs as it folded them, and the
// ones the others synced, in one list.

extension RunsPresenter {
    /// This Mac's `runs` and the `remote` ones its other Macs synced, as one page. Live runs are
    /// ordered by who moves next, then most pressing, across both, with the runs of a Mac gone
    /// quiet after every run still heard from; settled runs are newest first across both and
    /// share the days and their totals. This Mac's runs keep their own rules (hidden never shows,
    /// one waiting on you stays however long); synced runs drop out after a day. A synced card
    /// has no actions: its session isn't on this Mac.
    public func page(_ runs: [TaskRun], remote: [RunDigest], expanded: Set<String> = [], opened: Set<String> = [],
                     allRecent: Bool = false) -> RunsPageModel {
        guard !remote.isEmpty else { return page(runs, expanded: expanded, opened: opened, allRecent: allRecent) }
        var entries = shown(runs).map { entry($0, expanded: expanded, opened: opened) }
        for d in remote where now.timeIntervalSince(d.updatedAt) < Self.recentWindow {
            let phase = Self.phase(d)
            var glyph = Self.look(asRun(d)).0
            if d.lastSeen != nil, phase != .settled { glyph = .stopped }
            entries.append(ListEntry(id: d.id, title: baseTitle(d), updatedAt: d.updatedAt, attention: d.attention, phase: phase,
                                     away: d.lastSeen != nil && phase != .settled, worked: Self.worked(d), cost: d.cost, short: false, glyph: glyph,
                                     percent: d.hasDeclaredTasks || d.mirrored ? headlinePercent(d) : nil) {
                var c = card(d, expanded: expanded.contains(d.id), sayStart: $0)
                c.mac = d.mac
                return c
            })
        }
        return assemble(entries, allRecent: allRecent)
    }
}
