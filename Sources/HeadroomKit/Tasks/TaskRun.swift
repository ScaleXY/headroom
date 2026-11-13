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
    /// This node's share (0…1) of the whole run's weight, for drawing the run as a map of its
    /// tasks: counted leaves' shares sum to 1. 0 for nodes that don't count. In a run with no plan,
    /// an agent that spawned others is a group that also counts as one unit of its own: that part
    /// is its share less its children's.
    public var share: Double
    /// Seconds of work on this task (its own and its children's activity, gaps excluded).
    public var workingSeconds: Double
    /// A failed task another one took over from (`task.fail --instead`, or a failure whose reason
    /// says so followed at once by a new task): that task's id. It doesn't count against the run
    /// unless its replacement fails too.
    public var replacedBy: String?

    public init(id: String, title: String, parent: String? = nil, depth: Int = 0, state: TaskState, waitReason: TaskWaitReason? = nil, stale: Bool = false,
                progress: TaskProgress = .zero, effort: Double = TaskEffort.defaultWeight, importance: TaskImportance = .normal, declared: Bool = true,
                confirmed: Bool = true, leaf: Bool = true, counted: Bool = true, steps: TaskSteps? = nil, fraction: Double? = nil, note: String? = nil,
                waitNote: String? = nil, evidence: String? = nil, failure: String? = nil, attempts: TaskAttemptsSummary = TaskAttemptsSummary(),
                tokens: Int64 = 0, startedAt: Date? = nil, endedAt: Date? = nil, lastActivityAt: Date? = nil, share: Double = 0, workingSeconds: Double = 0) {
        self.id = id; self.title = title; self.parent = parent; self.depth = depth; self.state = state; self.waitReason = waitReason
        self.stale = stale; self.progress = progress; self.effort = effort; self.importance = importance; self.declared = declared
        self.confirmed = confirmed; self.leaf = leaf; self.counted = counted; self.steps = steps; self.fraction = fraction; self.note = note
        self.waitNote = waitNote; self.evidence = evidence; self.failure = failure; self.attempts = attempts; self.tokens = tokens
        self.startedAt = startedAt; self.endedAt = endedAt; self.lastActivityAt = lastActivityAt; self.share = share; self.workingSeconds = workingSeconds
        self.replacedBy = nil
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
        case share
        case workingSeconds = "working_seconds"
        case replacedBy = "replaced_by"
    }

    /// Older feeds lack `share` and `working_seconds`: they read as 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  parent: try c.decodeIfPresent(String.self, forKey: .parent), depth: try c.decode(Int.self, forKey: .depth),
                  state: try c.decode(TaskState.self, forKey: .state), waitReason: try c.decodeIfPresent(TaskWaitReason.self, forKey: .waitReason),
                  stale: try c.decode(Bool.self, forKey: .stale), progress: try c.decode(TaskProgress.self, forKey: .progress),
                  effort: try c.decode(Double.self, forKey: .effort), importance: try c.decode(TaskImportance.self, forKey: .importance),
                  declared: try c.decode(Bool.self, forKey: .declared), confirmed: try c.decode(Bool.self, forKey: .confirmed),
                  leaf: try c.decode(Bool.self, forKey: .leaf), counted: try c.decode(Bool.self, forKey: .counted),
                  steps: try c.decodeIfPresent(TaskSteps.self, forKey: .steps), fraction: try c.decodeIfPresent(Double.self, forKey: .fraction),
                  note: try c.decodeIfPresent(String.self, forKey: .note), waitNote: try c.decodeIfPresent(String.self, forKey: .waitNote),
                  evidence: try c.decodeIfPresent(String.self, forKey: .evidence), failure: try c.decodeIfPresent(String.self, forKey: .failure),
                  attempts: try c.decode(TaskAttemptsSummary.self, forKey: .attempts), tokens: try c.decode(Int64.self, forKey: .tokens),
                  startedAt: try c.decodeIfPresent(Date.self, forKey: .startedAt), endedAt: try c.decodeIfPresent(Date.self, forKey: .endedAt),
                  lastActivityAt: try c.decodeIfPresent(Date.self, forKey: .lastActivityAt),
                  share: try c.decodeIfPresent(Double.self, forKey: .share) ?? 0,
                  workingSeconds: try c.decodeIfPresent(Double.self, forKey: .workingSeconds) ?? 0)
        replacedBy = try c.decodeIfPresent(String.self, forKey: .replacedBy)
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
    /// Seconds of work to finish at the recent rate (over working time, not waiting or idle); nil
    /// unless running, until two leaves are done, or while nothing moves.
    public var etaSeconds: Double?
    public var tokens: Int64
    /// Tasks added, and efforts changed, after the first task started.
    public var scopeChanges: Int
    /// Free-form, for the app to explain something odd about the run.
    public var warning: String?
    /// There is a plan: something was declared, or the harness's plan list is mirrored. Without
    /// one, the agents seen running are the plan: state and progress read as finished agents over
    /// spawned agents.
    public var hasDeclaredTasks: Bool
    public var nodes: [TaskNode]
    /// Finished leaves `TaskCompaction` dropped from `nodes`; their work is still in the progress,
    /// state and tokens. Nil when nothing was dropped.
    public var finishedEarlier: Int?

    // Added with the second pass on task tracking. Every one is optional on the wire.

    /// A person hid the run from the app (`run.hide`). Surfaces leave hidden runs out.
    public var hidden: Bool
    /// A person gave up on the run (`run.abandon`); its open tasks were cancelled.
    public var abandoned: Bool
    /// What the run is waiting on a person to answer, while it is.
    public var question: TaskQuestion?
    /// Where the run's time went.
    public var time: TaskTimeSplit
    /// The forecast as a range (seconds to finish), while there is one. `etaSeconds` sits inside it.
    public var etaLowSeconds: Double?
    public var etaHighSeconds: Double?
    /// Tokens by model name, for pricing the run.
    public var tokensByModel: [String: Int64]
    /// Tokens per hour over the recent past, while the run is live.
    public var recentTokensPerHour: Double?
    /// Tokens the run is forecast to still need, when there is a basis for it.
    public var tokensToFinish: Int64?
    /// How the run sits against its provider's limit (`TaskLimits.adjust`).
    public var limitOutlook: TaskLimitOutlook?
    /// The plan comes from the harness's own plan list (`plan.mirror`), not from the agent.
    public var mirrored: Bool
    /// The app the session runs in and its working folder (from `run.meta`). Never synced.
    public var host: String?
    public var cwd: String?

    public init(id: String, title: String, project: String? = nil, harness: String? = nil, startedAt: Date, updatedAt: Date, state: TaskRunState,
                waitReason: TaskWaitReason? = nil, stale: Bool = false, progress: TaskProgress = .zero, mustHaves: TaskMustHaves = TaskMustHaves(done: 0, total: 0),
                etaSeconds: Double? = nil, tokens: Int64 = 0, scopeChanges: Int = 0, warning: String? = nil, hasDeclaredTasks: Bool? = nil, nodes: [TaskNode] = [], finishedEarlier: Int? = nil,
                hidden: Bool = false, abandoned: Bool = false, question: TaskQuestion? = nil, time: TaskTimeSplit = .zero, etaLowSeconds: Double? = nil,
                etaHighSeconds: Double? = nil, tokensByModel: [String: Int64] = [:], recentTokensPerHour: Double? = nil, tokensToFinish: Int64? = nil,
                limitOutlook: TaskLimitOutlook? = nil, mirrored: Bool = false, host: String? = nil, cwd: String? = nil) {
        self.id = id; self.title = title; self.project = project; self.harness = harness; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.state = state; self.waitReason = waitReason; self.stale = stale; self.progress = progress; self.mustHaves = mustHaves
        self.etaSeconds = etaSeconds; self.tokens = tokens; self.scopeChanges = scopeChanges; self.warning = warning
        self.hasDeclaredTasks = hasDeclaredTasks ?? nodes.contains(where: \.declared)
        self.nodes = nodes
        self.finishedEarlier = finishedEarlier
        self.hidden = hidden; self.abandoned = abandoned; self.question = question; self.time = time
        self.etaLowSeconds = etaLowSeconds; self.etaHighSeconds = etaHighSeconds; self.tokensByModel = tokensByModel
        self.recentTokensPerHour = recentTokensPerHour; self.tokensToFinish = tokensToFinish; self.limitOutlook = limitOutlook
        self.mirrored = mirrored; self.host = host; self.cwd = cwd
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
        case hidden, abandoned, question, time, mirrored, host, cwd
        case etaLowSeconds = "eta_low_seconds"
        case etaHighSeconds = "eta_high_seconds"
        case tokensByModel = "tokens_by_model"
        case recentTokensPerHour = "recent_tokens_per_hour"
        case tokensToFinish = "tokens_to_finish"
        case limitOutlook = "limit_outlook"
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
                  finishedEarlier: try c.decodeIfPresent(Int.self, forKey: .finishedEarlier),
                  hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
                  abandoned: try c.decodeIfPresent(Bool.self, forKey: .abandoned) ?? false,
                  question: try c.decodeIfPresent(TaskQuestion.self, forKey: .question),
                  time: try c.decodeIfPresent(TaskTimeSplit.self, forKey: .time) ?? .zero,
                  etaLowSeconds: try c.decodeIfPresent(Double.self, forKey: .etaLowSeconds),
                  etaHighSeconds: try c.decodeIfPresent(Double.self, forKey: .etaHighSeconds),
                  tokensByModel: try c.decodeIfPresent([String: Int64].self, forKey: .tokensByModel) ?? [:],
                  recentTokensPerHour: try c.decodeIfPresent(Double.self, forKey: .recentTokensPerHour),
                  tokensToFinish: try c.decodeIfPresent(Int64.self, forKey: .tokensToFinish),
                  limitOutlook: try c.decodeIfPresent(TaskLimitOutlook.self, forKey: .limitOutlook),
                  mirrored: try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false,
                  host: try c.decodeIfPresent(String.self, forKey: .host), cwd: try c.decodeIfPresent(String.self, forKey: .cwd))
    }
}

extension Array where Element == TaskRun {
    /// Most pressing first, then most recently updated.
    public func sortedForDisplay() -> [TaskRun] {
        sorted { ($0.attention, $1.updatedAt, $0.id) < ($1.attention, $0.updatedAt, $1.id) }
    }
}
