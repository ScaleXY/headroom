import Foundation
import HeadroomPresent
import HeadroomSync

/// The runs of the user's other Macs, as this Mac's sync store last imported them, for the Runs
/// tab. It only reads: another Mac's records are never written, deduped or deleted from here.
@MainActor
final class RemoteRuns {
    /// Called when what the other Macs synced changed.
    var onChange: (() -> Void)?

    /// A finished run is priced from its Mac's last week of activity (`RunCost.rates`); a day
    /// more covers the day boundary.
    static let activityDays = 8
    /// The store changes in bursts during an import, and on every save of this Mac's own.
    static let settle: Duration = .seconds(3)

    private var store: SyncStore?
    private var deviceID = ""
    private var records = OtherMacs()
    private var pending: Task<Void, Never>?

    /// Reads at once: the store already holds what earlier imports brought.
    func start(store: SyncStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
        reload(after: .zero)
    }

    func stop() {
        pending?.cancel(); pending = nil
        store = nil
        guard !records.isEmpty else { return }
        records = OtherMacs()
        onChange?()
    }

    /// The store changed (an import, or one of this Mac's own saves): read again once it settles.
    func storeChanged() { reload(after: Self.settle) }

    /// The other Macs' runs as of `now`, so a Mac going quiet and the one-day window move with
    /// the clock, not only with new records.
    func digests(now: Date) -> [RunDigest] {
        records.isEmpty ? [] : RunMerge.digests(records.devices, now: now, activity: records.activity)
    }

    private func reload(after delay: Duration) {
        guard pending == nil, let store else { return }
        let id = deviceID
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Cleared before the read, so a change that lands during it is read too.
            self?.pending = nil
            let since = Int((Date().timeIntervalSince1970 / 86400).rounded(.down)) - Self.activityDays
            guard let fresh = try? await store.otherMacs(than: id, activitySince: since) else { return }
            // Stopped, or started on another store, while reading.
            guard let self, self.store === store, fresh != self.records else { return }
            self.records = fresh
            self.onChange?()
        }
    }
}
