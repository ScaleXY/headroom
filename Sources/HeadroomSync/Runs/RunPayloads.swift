import CryptoKit
import Foundation
import HeadroomKit
import HeadroomPresent

// Agent runs ride along in `DevicePayload.runs`: an optional field, so it needs no CloudKit
// schema change, older readers skip it and older payloads simply lack it. By default only
// structure and state sync. A run's title and its most pressing rows' titles sync only when the
// Mac's "Include task names" is on, and the wording of a question it waits on only when the Mac
// also shares questions; project names, notes, failure reasons, evidence, the host app and the
// working folder never do. Hidden runs never sync. Every field added since runs first synced is
// optional and left out when empty, so a run with nothing new writes the same bytes as before.

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

/// One block of a run's task map, in short keys (a run sends up to 24). Structure only: no title.
public struct RunSegmentPayload: Codable, Sendable, Hashable {
    /// Share of the run, 0…1, to three places.
    public var w: Double
    /// How far along, 0…1, to two places.
    public var f: Double
    public var s: TaskState
    /// Wait reason, while waiting.
    public var r: TaskWaitReason?
    /// Quiet: only when true.
    public var q: Bool?
    /// Importance: only when not normal.
    public var i: TaskImportance?

    public init(weight: Double, fill: Double, state: TaskState, waitReason: TaskWaitReason? = nil, stale: Bool = false, importance: TaskImportance = .normal) {
        w = (min(max(weight, 0), 1) * 1000).rounded() / 1000
        f = (min(max(fill, 0), 1) * 100).rounded() / 100
        s = state; r = state == .waiting ? waitReason : nil; q = stale ? true : nil; i = importance == .normal ? nil : importance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        w = min(max(c.lenient(.w, 0.0), 0), 1)
        f = min(max(c.lenient(.f, 0.0), 0), 1)
        s = c.lenient(.s, .planned)
        r = c.lenient(.r, nil)
        q = c.lenient(.q, nil)
        i = c.lenient(.i, nil)
    }

    public var segment: RunDigest.Segment {
        RunDigest.Segment(weight: w, fill: f, state: s, waitReason: r, stale: q ?? false, importance: i ?? .normal)
    }
}

/// The question a run waits on: only with task names and question wording both shared.
public struct RunQuestionPayload: Codable, Sendable, Hashable {
    public var text: String
    public var options: [String]?
    /// The asking task's title; nil when the orchestrator asked.
    public var asker: String?

    public static let maxOptions = 4
    public static let maxOption = 60

    public init(text: String, options: [String]?, asker: String?) { self.text = text; self.options = options; self.asker = asker }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = String(try c.decode(String.self, forKey: .text).prefix(TaskQuestion.maxLength))
        options = c.contains(.options) ? c.lenientArray(.options) : nil
        asker = c.lenient(.asker, nil)
    }

    public var question: RunDigest.Question { RunDigest.Question(text: text, options: options ?? [], asker: asker) }
}

/// What a finished run's receipt is built from. Model names and numbers only.
public struct RunReceiptPayload: Codable, Sendable, Hashable {
    /// Start to finish, in seconds.
    public var seconds: Double
    /// Tokens by model, at most `maxModels`, for pricing on the reader.
    public var models: [String: Int64]?
    public var time: TaskTimeSplit?
    public var optionalFailed: Int?
    public var scopeChanges: Int?
    public var retries: Int?

    public static let maxModels = 8

    public init(seconds: Double, models: [String: Int64]?, time: TaskTimeSplit?, optionalFailed: Int?, scopeChanges: Int?, retries: Int?) {
        self.seconds = seconds; self.models = models; self.time = time; self.optionalFailed = optionalFailed
        self.scopeChanges = scopeChanges; self.retries = retries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = max(0, c.lenient(.seconds, 0.0))
        models = c.lenient(.models, nil)
        time = c.lenient(.time, nil)
        optionalFailed = c.lenient(.optionalFailed, nil)
        scopeChanges = c.lenient(.scopeChanges, nil)
        retries = c.lenient(.retries, nil)
    }

    public var receipt: RunDigest.Receipt {
        RunDigest.Receipt(seconds: seconds, tokensByModel: models ?? [:], time: time ?? .zero, optionalFailed: max(0, optionalFailed ?? 0),
                          scopeChanges: max(0, scopeChanges ?? 0), retries: max(0, retries ?? 0))
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
    /// Seconds to finish as the Mac's last fold had it; kept for readers from before `finishAt`.
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

    // Second pass. All optional; nil (and absent from the JSON) when there's nothing to say.

    /// The task map, at most `RunSummaryBuilder.maxSegments` blocks.
    public var segments: [RunSegmentPayload]?
    /// The forecast finish and its range, as clock times rounded to the minute.
    public var finishAt: Date?
    public var finishLow: Date?
    public var finishHigh: Date?
    /// Seconds of work so far.
    public var working: Double?
    /// Only when true.
    public var mirrored: Bool?
    public var abandoned: Bool?
    /// Against the provider's 5-hour window, while live.
    public var limit: TaskLimitOutlook?
    /// Finished runs only.
    public var receipt: RunReceiptPayload?
    /// Task names and question wording only, while the run needs input.
    public var question: RunQuestionPayload?

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
        segments = c.contains(.segments) ? Array((c.lenientArray(.segments) as [RunSegmentPayload]).prefix(RunSummaryBuilder.maxSegments)) : nil
        finishAt = c.lenient(.finishAt, nil)
        finishLow = c.lenient(.finishLow, nil)
        finishHigh = c.lenient(.finishHigh, nil)
        working = c.lenient(.working, nil)
        mirrored = c.lenient(.mirrored, nil)
        abandoned = c.lenient(.abandoned, nil)
        limit = c.lenient(.limit, nil)
        receipt = c.lenient(.receipt, nil)
        question = c.lenient(.question, nil)
    }

    /// Whether a change from `old` (the same run) is one readers should hear about within a
    /// minute: it finished, failed, needs input, hit a limit, went quiet, was given up on, or
    /// names were switched. Anything else is progress.
    func sameState(as old: RunSummaryPayload) -> Bool {
        id == old.id && state == old.state && waitReason == old.waitReason && stale == old.stale && limitWarning == old.limitWarning
            && (rows == nil) == (old.rows == nil) && abandoned == old.abandoned && question == old.question
    }

    /// Needs an answer now.
    var needsInput: Bool { state == .waiting && waitReason == .input }

    /// As readers present it, from the Mac named `mac`; `lastSeen` when that Mac went quiet,
    /// `activeAt` when its user last touched it.
    public func digest(deviceID: String, mac: String, lastSeen: Date?, activeAt: Date? = nil) -> RunDigest {
        var d = RunDigest(id: deviceID + ":" + id, mac: mac, harness: harness, state: state, waitReason: waitReason, stale: stale, progress: progress,
                          mustHaves: mustHaves, etaSeconds: etaSeconds, tokens: tokens, warning: limitWarning, hasDeclaredTasks: hasDeclaredTasks,
                          startedAt: startedAt, updatedAt: updatedAt, counts: counts, title: title, rows: rows?.map(\.row), moreRows: moreRows ?? 0,
                          finishedRows: finishedRows ?? 0, finishedEarlier: finishedEarlier ?? 0, lastSeen: state.isTerminal ? nil : lastSeen)
        d.segments = segments?.map(\.segment) ?? []
        d.finishAt = finishAt; d.finishLow = finishLow; d.finishHigh = finishHigh
        d.workingSeconds = working
        d.mirrored = mirrored ?? false
        d.abandoned = abandoned ?? false
        d.limit = state.isTerminal ? nil : limit
        d.receipt = state.isTerminal ? receipt?.receipt : nil
        d.question = needsInput ? question?.question : nil
        d.macActiveAt = activeAt
        return d
    }
}

/// Builds a Mac's run summaries from its folded runs.
public enum RunSummaryBuilder {
    public static let maxRuns = 8
    public static let maxRows = 30
    public static let maxSegments = 24
    /// Finished runs sync this long after they end; readers drop them after it too.
    public static let finishedWindow: TimeInterval = 86400
    /// Titles are labels; anything longer is cut.
    static let maxTitle = 120

    /// Live runs first (most pressing first), then those finished in the last day (newest
    /// first), at most `maxRuns`. Hidden runs never go. Nil when there are none, so the device
    /// payload stays as it was. `includeQuestion` sends a pending question's wording, and only
    /// counts with `includeNames`.
    public static func summaries(_ runs: [TaskRun], includeNames: Bool, includeQuestion: Bool = false, now: Date) -> [RunSummaryPayload]? {
        let runs = runs.filter { !$0.hidden }
        let live = runs.sortedForDisplay().filter { !$0.state.isTerminal && $0.isActive(now: now) }
        let finished = runs.filter { $0.state.isTerminal && now.timeIntervalSince($0.updatedAt) < finishedWindow }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let chosen = (live + finished).prefix(maxRuns)
        guard !chosen.isEmpty else { return nil }
        let presenter = RunsPresenter(now: now)
        return chosen.map { summary($0, includeNames: includeNames, includeQuestion: includeQuestion, presenter: presenter) }
    }

    public static func summary(_ r: TaskRun, includeNames: Bool, includeQuestion: Bool = false, presenter: RunsPresenter) -> RunSummaryPayload {
        let now = presenter.now
        var s = RunSummaryPayload(
            id: hashedID(r.id), harness: r.harness.map { String($0.prefix(40)) }, state: r.state, waitReason: r.waitReason, stale: r.stale,
            progress: r.progress, mustHaves: r.mustHaves, etaSeconds: r.etaSeconds, tokens: r.tokens, limitWarning: r.warning,
            hasDeclaredTasks: r.hasDeclaredTasks, startedAt: r.startedAt, updatedAt: r.updatedAt, counts: RunCounts.of(r),
            finishedEarlier: r.finishedEarlier)
        s.segments = segments(r)
        if !r.state.isTerminal {
            // Clock times from now, not seconds from the last event, so the finish never reads early.
            s.finishAt = r.etaSeconds.map { minute(now.addingTimeInterval($0)) }
            if let lo = r.etaLowSeconds, let hi = r.etaHighSeconds, hi >= lo {
                s.finishLow = minute(now.addingTimeInterval(lo))
                s.finishHigh = minute(now.addingTimeInterval(hi))
            }
            s.limit = limit(r.limitOutlook)
        }
        if r.time.working > 0 { s.working = r.time.working.rounded() }
        if r.mirrored { s.mirrored = true }
        if r.abandoned { s.abandoned = true }
        if r.state.isTerminal { s.receipt = receipt(r) }
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
        if includeQuestion, r.state == .waiting, r.waitReason == .input, let q = r.question {
            let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let options = q.options.prefix(RunQuestionPayload.maxOptions).map { String($0.prefix(RunQuestionPayload.maxOption)) }
                let asker = q.task.flatMap { id in r.nodes.first { $0.id == id }?.title }.map { String($0.prefix(maxTitle)) }
                s.question = RunQuestionPayload(text: String(text.prefix(TaskQuestion.maxLength)), options: options.isEmpty ? nil : options, asker: asker)
            }
        }
        return s
    }

    /// The task map: counted leaves in plan order, each as wide as its share (its effort when the
    /// fold gave no shares), neighbours merged when there are more than `maxSegments`.
    static func segments(_ r: TaskRun) -> [RunSegmentPayload]? {
        guard r.hasDeclaredTasks else { return nil }
        let leaves = r.nodes.filter { $0.leaf && $0.counted }
        guard !leaves.isEmpty else { return nil }
        let shares = leaves.map { max(0, $0.share) }
        let efforts = leaves.map { $0.effort > 0 ? $0.effort : 1 }
        let raw = shares.reduce(0, +) > 0 ? shares : efforts
        let sum = raw.reduce(0, +)
        let weights = raw.map { $0 / sum }
        func fill(_ n: TaskNode) -> Double {
            switch n.state {
            case .done, .failed, .partial, .skipped, .cancelled: 1
            case .planned: 0
            default: n.fraction ?? n.steps.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 } ?? max(n.progress.done, n.progress.estimate)
            }
        }
        let groups = Int((Double(leaves.count) / Double(maxSegments)).rounded(.up))
        var out: [RunSegmentPayload] = []
        var i = 0
        let size = leaves.count <= maxSegments ? 1 : groups
        while i < leaves.count {
            let range = i..<min(i + size, leaves.count)
            let w = range.reduce(0) { $0 + weights[$1] }
            let f = w > 0 ? range.reduce(0) { $0 + weights[$1] * fill(leaves[$1]) } / w : 0
            // The most pressing member speaks for a merged block.
            let lead = range.min { (leaves[$0].attention, $0) < (leaves[$1].attention, $1) }.map { leaves[$0] }!
            let critical = range.contains { leaves[$0].importance == .critical }
            out.append(RunSegmentPayload(weight: w, fill: f, state: lead.state, waitReason: lead.waitReason, stale: lead.stale,
                                         importance: critical ? .critical : lead.importance))
            i = range.upperBound
        }
        return out
    }

    static func limit(_ l: TaskLimitOutlook?) -> TaskLimitOutlook? {
        guard var l, l.pauseAt != nil || l.finishAt != nil || l.share != nil else { return nil }
        l.pauseAt = l.pauseAt.map(minute); l.resumeAt = l.resumeAt.map(minute); l.finishAt = l.finishAt.map(minute)
        l.share = l.share.map { (min(max($0, 0), 1) * 100).rounded() / 100 }
        l.tokensNeeded = l.tokensNeeded.map { ($0 / 10_000) * 10_000 }
        l.roomTokens = l.roomTokens.map { ($0 / 10_000) * 10_000 }
        return l
    }

    static func receipt(_ r: TaskRun) -> RunReceiptPayload {
        let models = r.tokensByModel.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(RunReceiptPayload.maxModels)
        let optionalFailed = r.nodes.filter { $0.leaf && $0.importance == .optional && ($0.state == .failed || $0.state == .partial) }.count
        let retries = r.nodes.reduce(0) { $0 + $1.attempts.retries }
        return RunReceiptPayload(seconds: max(0, r.updatedAt.timeIntervalSince(r.startedAt)).rounded(),
                                 models: models.isEmpty ? nil : Dictionary(uniqueKeysWithValues: models.map { (String($0.key.prefix(60)), $0.value) }),
                                 time: r.time.total > 0 ? r.time : nil, optionalFailed: optionalFailed > 0 ? optionalFailed : nil,
                                 scopeChanges: r.scopeChanges > 0 ? r.scopeChanges : nil, retries: retries > 0 ? retries : nil)
    }

    /// Rounded to the minute, so a finish that moves by seconds doesn't count as a change.
    static func minute(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60) }

    /// The first 16 hex digits of SHA-256 over the run ID.
    public static func hashedID(_ id: String) -> String {
        SHA256.hash(data: Data(("headroom-run:" + id).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds run summaries back so the device record isn't rewritten on every tick: a state change
/// (a run started, finished, failed, needs input, hit a limit) goes out at most once a minute,
/// progress alone at most every 5 minutes. Turning task names off goes out at once. Runs are
/// matched by ID, so two live runs swapping places is not a change.
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
        let interval = Self.stateChanged(from: old, to: new) ? Self.stateInterval : Self.progressInterval
        let elapsed = now.timeIntervalSince(lastWrite)
        if force || namesRemoved || elapsed >= interval {
            published = fresh
            lastWrite = now
            return (fresh, nil)
        }
        return (published, interval - elapsed)
    }

    /// A run came or went, or one changed state; order alone is not a change.
    static func stateChanged(from old: [RunSummaryPayload], to new: [RunSummaryPayload]) -> Bool {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard Set(before.keys) == Set(new.map(\.id)) else { return true }
        return new.contains { n in before[n.id].map { !n.sameState(as: $0) } ?? true }
    }

    /// Picks up what is already in iCloud, so a relaunch doesn't count as a change.
    public mutating func seed(_ runs: [RunSummaryPayload]?, at: Date) {
        published = runs
        lastWrite = at
    }
}
