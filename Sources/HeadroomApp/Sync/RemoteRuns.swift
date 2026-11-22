import Foundation
import HeadroomKit
import HeadroomPresent
import HeadroomSync

/// The other Macs' runs and activity, as this Mac's sync store last imported them.
@MainActor
final class RemoteRuns {
    /// Called when what the other Macs synced changed.
    var onChange: (() -> Void)?

    /// The store changes in bursts during an import, and on every save of this Mac's own.
    static let settle: Duration = .seconds(3)

    private var store: SyncStore?
    private var deviceID = ""
    private(set) var records = OtherMacs()
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
        RunMerge.digests(records.devices, now: now, activity: records.runActivity)
    }

    private func reload(after delay: Duration) {
        guard pending == nil, let store else { return }
        let id = deviceID
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Cleared before the read, so a change that lands during it is read too.
            self?.pending = nil
            let since = Int((Date().timeIntervalSince1970 / 86400).rounded(.down)) - CloudPublisher.activityDays
            guard let fresh = try? await store.otherMacs(than: id, activitySince: since) else { return }
            // Stopped, or started on another store, while reading.
            guard let self, self.store === store, fresh != self.records else { return }
            self.records = fresh
            self.onChange?()
        }
    }
}

extension OtherMacs {
    var aggregates: [HourAggregate] {
        let names = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceID, $0.payload.name) })
        return activity.flatMap { day -> [HourAggregate] in
            guard let provider = day.provider else { return [] }
            let name = names[day.deviceID] ?? "Mac"
            return day.payload.slots.map { $0.aggregate(provider: provider, mac: name) }
        }
    }

    func micros(_ provider: Provider, accountKey: String, from: Date, to: Date) -> Int64 {
        let a = ActivitySlot.slot(for: from), b = ActivitySlot.slot(for: to)
        var micros: Int64 = 0
        for day in activity where day.provider == provider && day.accountKey == accountKey {
            for slot in day.payload.slots where slot.slot >= a && slot.slot < b { micros += slot.micros }
        }
        return micros
    }
}
