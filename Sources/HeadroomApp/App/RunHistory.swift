import Foundation
import HeadroomKit
import HeadroomPresent

/// Receipts of finished runs, kept after their event files are pruned, for the Activity tab's
/// recent runs. `TaskTracker` calls `record` after every fold; it writes only when a run finished,
/// changed or aged out, so a fold with nothing new costs a dictionary lookup per finished run.
@MainActor
final class RunHistory {
    static let shared = RunHistory()

    /// Two weeks, at most fifty runs.
    static let keep: TimeInterval = 14 * 86400
    static let cap = 50

    let url: URL
    private var byID: [String: RunRecord]?

    init(directory: URL = SnapshotFile.directory) {
        url = directory.appendingPathComponent("run-history.json")
    }

    /// Every fold's runs; keeps a small summary of each that finished.
    func record(_ runs: [TaskRun], now: Date = Date()) {
        var records = load()
        var changed = false
        for r in runs where RunsPresenter.isFinished(r) {
            // The fold sets `updatedAt` on every change, so an unchanged finished run is skipped here.
            // (Whole seconds on disk, hence the tolerance.)
            if let old = records[r.id], abs(old.endedAt.timeIntervalSince(r.updatedAt)) < 1, old.hidden == r.hidden, old.abandoned == r.abandoned, old.state == r.state,
               old.title == RunRecord(r).title { continue }
            guard now.timeIntervalSince(r.updatedAt) < Self.keep else { continue }
            records[r.id] = RunRecord(r)
            changed = true
        }
        if prune(&records, now: now) { changed = true }
        byID = records
        if changed { save(records) }
    }

    /// Kept runs, newest first, hidden ones included (surfaces leave them out).
    func records(now: Date = Date()) -> [RunRecord] {
        load().values.filter { now.timeIntervalSince($0.endedAt) < Self.keep }.sorted { ($0.endedAt, $1.id) > ($1.endedAt, $0.id) }
    }

    /// Drops runs older than two weeks and all but the newest fifty. True when anything went.
    private func prune(_ records: inout [String: RunRecord], now: Date) -> Bool {
        let before = records.count
        records = records.filter { now.timeIntervalSince($0.value.endedAt) < Self.keep }
        if records.count > Self.cap {
            let keep = Set(records.values.sorted { ($0.endedAt, $1.id) > ($1.endedAt, $0.id) }.prefix(Self.cap).map(\.id))
            records = records.filter { keep.contains($0.key) }
        }
        return records.count != before
    }

    private func load() -> [String: RunRecord] {
        if let byID { return byID }
        var out: [String: RunRecord] = [:]
        if let data = try? Data(contentsOf: url), let list = try? Self.decoder.decode([RunRecord].self, from: data) {
            for r in list { out[r.id] = r }
        }
        byID = out
        return out
    }

    private func save(_ records: [String: RunRecord]) {
        let list = records.values.sorted { ($0.endedAt, $1.id) > ($1.endedAt, $0.id) }
        guard let data = try? Self.encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
