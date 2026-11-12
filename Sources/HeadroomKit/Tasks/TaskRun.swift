import Foundation

/// One task in a folded run, in display order. Written to `tasks.json`.
public struct TaskNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var parent: String?
    public var depth: Int
    public var state: TaskState
    public var waitReason: TaskWaitReason?
    /// Running with no activity anywhere beneath it for longer than the fold's threshold. An
    /// overlay on `state`, not a state.
    public var stale: Bool
    public var progress: TaskProgress
    public var effort: Double
    public var importance: TaskImportance
    /// The agent named this task; false for implicit groups and for agents nobody declared.
    public var declared: Bool
    /// False when the state was inferred from the agents on it ending, not declared.
    public var confirmed: Bool
    /// Has no children that count, so its own steps, fraction and attempts make its progress.
    public var leaf: Bool
    /// Counts in its parent's progress (skipped tasks, failed optional ones and helper agents under
    /// a declared task don't).
    public var counted: Bool
    public var steps: TaskSteps?
    public var fraction: Double?
    public var note: String?
    public var waitNote: String?
    public var evidence: String?
    public var failure: String?
    public var attempts: TaskAttemptsSummary
    /// Tokens spent on this task, its helpers and its children.
    public var tokens: Int64
    public var startedAt: Date?
    public var endedAt: Date?
    public var lastActivityAt: Date?

    public init(id: String, title: String, parent: String? = nil, depth: Int = 0, state: TaskState, waitReason: TaskWaitReason? = nil, stale: Bool = false,
                progress: TaskProgress = .zero, effort: Double = TaskEffort.defaultWeight, importance: TaskImportance = .normal, declared: Bool = true,
                confirmed: Bool = true, leaf: Bool = true, counted: Bool = true, steps: TaskSteps? = nil, fraction: Double? = nil, note: String? = nil,
                waitNote: String? = nil, evidence: String? = nil, failure: String? = nil, attempts: TaskAttemptsSummary = TaskAttemptsSummary(),
                tokens: Int64 = 0, startedAt: Date? = nil, endedAt: Date? = nil, lastActivityAt: Date? = nil) {
        self.id = id; self.title = title; self.parent = parent; self.depth = depth; self.state = state; self.waitReason = waitReason
        self.stale = stale; self.progress = progress; self.effort = effort; self.importance = importance; self.declared = declared
        self.confirmed = confirmed; self.leaf = leaf; self.counted = counted; self.steps = steps; self.fraction = fraction; self.note = note
        self.waitNote = waitNote; self.evidence = evidence; self.failure = failure; self.attempts = attempts; self.tokens = tokens
        self.startedAt = startedAt; self.endedAt = endedAt; self.lastActivityAt = lastActivityAt
    }

    public var attention: TaskAttention { TaskAttention(state: state, waitReason: waitReason, stale: stale) }

    enum CodingKeys: String, CodingKey {
        case id, title, parent, depth, state, stale, progress, effort, importance, declared, confirmed, leaf, counted
        case steps, fraction, note, evidence, failure, attempts, tokens
        case waitReason = "wait_reason"
        case waitNote = "wait_note"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case lastActivityAt = "last_activity_at"
    }
}

public struct TaskAttemptsSummary: Codable, Sendable, Hashable {
    public var count: Int
    public var active: Int
    /// New attempts after the first, plus reopenings after a terminal state.
    public var retries: Int
    /// The most recently started attempt.
    public var last: TaskAttempt?

    public init(count: Int = 0, active: Int = 0, retries: Int = 0, last: TaskAttempt? = nil) {
        self.count = count; self.active = active; self.retries = retries; self.last = last
    }
}

/// One run folded from its events. Written to `tasks.json`.
public struct TaskRun: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var project: String?
    public var harness: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var state: TaskRunState
    public var waitReason: TaskWaitReason?
    public var stale: Bool
    public var progress: TaskProgress
    public var mustHaves: TaskMustHaves
    /// Seconds to finish at the recent rate; nil until two leaves are done or while nothing moves.
    public var etaSeconds: Double?
    public var tokens: Int64
    /// Tasks added, and efforts changed, after the first task started.
    public var scopeChanges: Int
    /// Free-form, for the app to explain something odd about the run.
    public var warning: String?
    /// Something was declared. Without that, the agents seen running are the plan: state and
    /// progress read as finished agents over spawned agents.
    public var hasDeclaredTasks: Bool
    public var nodes: [TaskNode]
    /// Finished leaves `TaskCompaction` dropped from `nodes`; their work is still in the progress,
    /// state and tokens. Nil when nothing was dropped.
    public var finishedEarlier: Int?

    public init(id: String, title: String, project: String? = nil, harness: String? = nil, startedAt: Date, updatedAt: Date, state: TaskRunState,
                waitReason: TaskWaitReason? = nil, stale: Bool = false, progress: TaskProgress = .zero, mustHaves: TaskMustHaves = TaskMustHaves(done: 0, total: 0),
                etaSeconds: Double? = nil, tokens: Int64 = 0, scopeChanges: Int = 0, warning: String? = nil, hasDeclaredTasks: Bool? = nil, nodes: [TaskNode] = [], finishedEarlier: Int? = nil) {
        self.id = id; self.title = title; self.project = project; self.harness = harness; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.state = state; self.waitReason = waitReason; self.stale = stale; self.progress = progress; self.mustHaves = mustHaves
        self.etaSeconds = etaSeconds; self.tokens = tokens; self.scopeChanges = scopeChanges; self.warning = warning
        self.hasDeclaredTasks = hasDeclaredTasks ?? nodes.contains(where: \.declared)
        self.nodes = nodes
        self.finishedEarlier = finishedEarlier
    }

    public var attention: TaskAttention { TaskAttention(run: state, waitReason: waitReason, stale: stale) }
    public var needsInput: Bool { state == .waiting && waitReason == .input }
    /// Leaves that count and are running.
    public var runningCount: Int { nodes.filter { $0.leaf && $0.counted && $0.state == .running }.count }

    /// Unfinished and touched in the last day, or finished in the last ten minutes: what
    /// `headroom tasks` shows without `--all`.
    public func isActive(now: Date) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return state.isTerminal ? age < 600 : age < 86400
    }

    enum CodingKeys: String, CodingKey {
        case id, title, project, harness, state, stale, progress, tokens, warning, nodes
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case waitReason = "wait_reason"
        case mustHaves = "must_haves"
        case etaSeconds = "eta_seconds"
        case scopeChanges = "scope_changes"
        case hasDeclaredTasks = "has_declared_tasks"
        case finishedEarlier = "finished_earlier"
    }

    /// Feeds written before `has_declared_tasks` existed still decode: it's read off the nodes.
    /// `finished_earlier` is optional for the same reason.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nodes = try c.decode([TaskNode].self, forKey: .nodes)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  project: try c.decodeIfPresent(String.self, forKey: .project), harness: try c.decodeIfPresent(String.self, forKey: .harness),
                  startedAt: try c.decode(Date.self, forKey: .startedAt), updatedAt: try c.decode(Date.self, forKey: .updatedAt),
                  state: try c.decode(TaskRunState.self, forKey: .state), waitReason: try c.decodeIfPresent(TaskWaitReason.self, forKey: .waitReason),
                  stale: try c.decode(Bool.self, forKey: .stale), progress: try c.decode(TaskProgress.self, forKey: .progress),
                  mustHaves: try c.decode(TaskMustHaves.self, forKey: .mustHaves), etaSeconds: try c.decodeIfPresent(Double.self, forKey: .etaSeconds),
                  tokens: try c.decode(Int64.self, forKey: .tokens), scopeChanges: try c.decode(Int.self, forKey: .scopeChanges),
                  warning: try c.decodeIfPresent(String.self, forKey: .warning),
                  hasDeclaredTasks: try c.decodeIfPresent(Bool.self, forKey: .hasDeclaredTasks), nodes: nodes,
                  finishedEarlier: try c.decodeIfPresent(Int.self, forKey: .finishedEarlier))
    }
}

extension Array where Element == TaskRun {
    /// Most pressing first, then most recently updated.
    public func sortedForDisplay() -> [TaskRun] {
        sorted { ($0.attention, $1.updatedAt, $0.id) < ($1.attention, $0.updatedAt, $1.id) }
    }
}
