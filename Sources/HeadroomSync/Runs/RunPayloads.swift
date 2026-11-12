import CryptoKit
import Foundation
import HeadroomKit
import HeadroomPresent

// Agent runs ride along in `DevicePayload.runs`: an optional field, so it needs no CloudKit
// schema change, older readers skip it and older payloads simply lack it. By default only
// structure and state sync. A run's title and its most pressing rows' titles sync only when the
// Mac's "Include task names" is on; project names, notes, failure reasons and evidence never do.

/// One of a run's most pressing rows. Synced only with task names included.
public struct RunRowPayload: Codable, Sendable, Hashable {
    public var title: String
    public var state: TaskState
    public var waitReason: TaskWaitReason?
    public var stale: Bool
    public var depth: Int
    public var steps: TaskSteps?
    public var importance: TaskImportance
    public var quiet: Bool

    public init(_ row: RunDigest.Row) {
        title = row.title; state = row.state; waitReason = row.waitReason; stale = row.stale; depth = row.depth; steps = row.steps
        importance = row.importance; quiet = row.quiet
    }

    public var row: RunDigest.Row {
        RunDigest.Row(title: title, state: state, waitReason: waitReason, stale: stale, depth: depth, steps: steps, importance: importance, quiet: quiet)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        state = c.lenient(.state, .planned)
        waitReason = c.lenient(.waitReason, nil)
        stale = c.lenient(.stale, false)
        depth = min(max(c.lenient(.depth, 0), 0), RunsPresenter.maxDepth)
        steps = c.lenient(.steps, nil)
        importance = c.lenient(.importance, .normal)
        quiet = c.lenient(.quiet, false)
    }
}

/// One run on one Mac.
public struct RunSummaryPayload: Codable, Sendable, Hashable {
    /// A hash of the harness's session ID: stable across updates, and says nothing about the session.
    public var id: String
    public var harness: String?
    public var state: TaskRunState
    public var waitReason: TaskWaitReason?
    public var stale: Bool
    public var progress: TaskProgress
    public var mustHaves: TaskMustHaves
    public var etaSeconds: Double?
    public var tokens: Int64
    /// `TaskLimits`' warning: it names only the provider and times.
    public var limitWarning: String?
    public var hasDeclaredTasks: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var counts: RunCounts
    public var finishedEarlier: Int?
    /// Task names only: the agent's title for the run (never the project).
    public var title: String?
    /// Task names only: the most pressing rows, at most `RunSummaryBuilder.maxRows`.
    public var rows: [RunRowPayload]?
    /// Task names only: rows past the ones sent, and the finished rows folded into "N finished".
    public var moreRows: Int?
    public var finishedRows: Int?

    public init(id: String, harness: String?, state: TaskRunState, waitReason: TaskWaitReason?, stale: Bool, progress: TaskProgress,
                mustHaves: TaskMustHaves, etaSeconds: Double?, tokens: Int64, limitWarning: String?, hasDeclaredTasks: Bool, startedAt: Date,
                updatedAt: Date, counts: RunCounts, finishedEarlier: Int?, title: String? = nil, rows: [RunRowPayload]? = nil, moreRows: Int? = nil,
                finishedRows: Int? = nil) {
        self.id = id; self.harness = harness; self.state = state; self.waitReason = waitReason; self.stale = stale; self.progress = progress
        self.mustHaves = mustHaves; self.etaSeconds = etaSeconds; self.tokens = tokens; self.limitWarning = limitWarning
        self.hasDeclaredTasks = hasDeclaredTasks; self.startedAt = startedAt; self.updatedAt = updatedAt; self.counts = counts
        self.finishedEarlier = finishedEarlier; self.title = title; self.rows = rows; self.moreRows = moreRows; self.finishedRows = finishedRows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        harness = c.lenient(.harness, nil)
        state = c.lenient(.state, .running)
        waitReason = c.lenient(.waitReason, nil)
        stale = c.lenient(.stale, false)
        progress = c.lenient(.progress, .zero)
        mustHaves = c.lenient(.mustHaves, TaskMustHaves(done: 0, total: 0))
        etaSeconds = c.lenient(.etaSeconds, nil)
        tokens = c.lenient(.tokens, 0)
        limitWarning = c.lenient(.limitWarning, nil)
        hasDeclaredTasks = c.lenient(.hasDeclaredTasks, false)
        startedAt = c.lenient(.startedAt, updatedAt)
        counts = c.lenient(.counts, RunCounts())
        finishedEarlier = c.lenient(.finishedEarlier, nil)
        title = c.lenient(.title, nil)
        rows = c.contains(.rows) ? c.lenientArray(.rows) : nil
        moreRows = c.lenient(.moreRows, nil)
        finishedRows = c.lenient(.finishedRows, nil)
    }

    /// Whether a change from `old` is one readers should hear about within a minute: the run
    /// started, finished, failed, needs input, hit a limit, went quiet, or names were switched.
    /// Anything else is progress.
    func sameState(as old: RunSummaryPayload) -> Bool {
        id == old.id && state == old.state && waitReason == old.waitReason && stale == old.stale && limitWarning == old.limitWarning
            && (rows == nil) == (old.rows == nil)
    }

    /// As readers present it, from the Mac named `mac`; `lastSeen` when that Mac went quiet.
    public func digest(deviceID: String, mac: String, lastSeen: Date?) -> RunDigest {
        RunDigest(id: deviceID + ":" + id, mac: mac, harness: harness, state: state, waitReason: waitReason, stale: stale, progress: progress,
                  mustHaves: mustHaves, etaSeconds: etaSeconds, tokens: tokens, warning: limitWarning, hasDeclaredTasks: hasDeclaredTasks,
                  startedAt: startedAt, updatedAt: updatedAt, counts: counts, title: title, rows: rows?.map(\.row), moreRows: moreRows ?? 0,
                  finishedRows: finishedRows ?? 0, finishedEarlier: finishedEarlier ?? 0, lastSeen: state.isTerminal ? nil : lastSeen)
    }
}

/// Builds a Mac's run summaries from its folded runs.
public enum RunSummaryBuilder {
    public static let maxRuns = 8
    public static let maxRows = 30
    /// Finished runs sync this long after they end; readers drop them after it too.
    public static let finishedWindow: TimeInterval = 86400
    /// Titles are labels; anything longer is cut.
    static let maxTitle = 120

    /// Live runs first (most pressing first), then those finished in the last day (newest
    /// first), at most `maxRuns`. Nil when there are none, so the device payload stays as it was.
    public static func summaries(_ runs: [TaskRun], includeNames: Bool, now: Date) -> [RunSummaryPayload]? {
        let live = runs.sortedForDisplay().filter { !$0.state.isTerminal && $0.isActive(now: now) }
        let finished = runs.filter { $0.state.isTerminal && now.timeIntervalSince($0.updatedAt) < finishedWindow }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let chosen = (live + finished).prefix(maxRuns)
        guard !chosen.isEmpty else { return nil }
        let presenter = RunsPresenter(now: now)
        return chosen.map { summary($0, includeNames: includeNames, presenter: presenter) }
    }

    public static func summary(_ r: TaskRun, includeNames: Bool, presenter: RunsPresenter) -> RunSummaryPayload {
        var s = RunSummaryPayload(
            id: hashedID(r.id), harness: r.harness.map { String($0.prefix(40)) }, state: r.state, waitReason: r.waitReason, stale: r.stale,
            progress: r.progress, mustHaves: r.mustHaves, etaSeconds: r.etaSeconds, tokens: r.tokens, limitWarning: r.warning,
            hasDeclaredTasks: r.hasDeclaredTasks, startedAt: r.startedAt, updatedAt: r.updatedAt, counts: RunCounts.of(r),
            finishedEarlier: r.finishedEarlier)
        guard includeNames else { return s }
        let picked = presenter.digestRows(r, cap: maxRows)
        s.title = r.agentTitle.map { String($0.prefix(maxTitle)) }
        s.rows = picked.rows.map {
            var row = RunRowPayload($0)
            row.title = String(row.title.prefix(maxTitle))
            return row
        }
        s.moreRows = picked.more
        s.finishedRows = picked.finished
        return s
    }

    /// The first 16 hex digits of SHA-256 over the run ID.
    public static func hashedID(_ id: String) -> String {
        SHA256.hash(data: Data(("headroom-run:" + id).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds run summaries back so the device record isn't rewritten on every tick: a state change
/// (a run started, finished, failed, needs input, hit a limit) goes out at most once a minute,
/// progress alone at most every 5 minutes. Turning task names off goes out at once.
public struct RunPublishGate: Sendable {
    public static let stateInterval: TimeInterval = 60
    public static let progressInterval: TimeInterval = 300

    public private(set) var published: [RunSummaryPayload]?
    public private(set) var lastWrite = Date.distantPast

    public init() {}

    /// The runs to put in the device payload now, and, when a newer version is being held back,
    /// how long until it may go.
    public mutating func pass(_ fresh: [RunSummaryPayload]?, now: Date, force: Bool = false) -> (runs: [RunSummaryPayload]?, retryAfter: TimeInterval?) {
        guard fresh != published else { return (published, nil) }
        let old = published ?? [], new = fresh ?? []
        let namesRemoved = old.contains { $0.rows != nil } && !new.contains { $0.rows != nil }
        let stateChanged = old.count != new.count || zip(old, new).contains { !$1.sameState(as: $0) }
        let interval = stateChanged ? Self.stateInterval : Self.progressInterval
        let elapsed = now.timeIntervalSince(lastWrite)
        if force || namesRemoved || elapsed >= interval {
            published = fresh
            lastWrite = now
            return (fresh, nil)
        }
        return (published, interval - elapsed)
    }

    /// Picks up what is already in iCloud, so a relaunch doesn't count as a change.
    public mutating func seed(_ runs: [RunSummaryPayload]?, at: Date) {
        published = runs
        lastWrite = at
    }
}
