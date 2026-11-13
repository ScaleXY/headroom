import Foundation

/// Values the task files store as strings. Decoding an unknown string falls back instead of
/// failing, so a newer writer's value never makes an older reader drop the whole file.
public protocol LenientStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

extension LenientStringEnum {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .fallback
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Who wrote an event.
public enum TaskSource: String, LenientStringEnum {
    /// The agent itself (`headroom task …`, MCP).
    case agent
    /// The app reading harness transcripts.
    case harness
    /// A harness hook (`headroom task hook`).
    case hook
    /// A person, from the app.
    case user
    public static let fallback = TaskSource.agent
}

/// Never enters the percentage: decides how a failure affects the parent and the run, and feeds
/// the must-haves count.
public enum TaskImportance: String, LenientStringEnum, CaseIterable {
    case critical, normal, optional
    public static let fallback = TaskImportance.normal
}

/// Relative effort, compared only among siblings.
public enum TaskEffort {
    public static let sizes: [(name: String, weight: Double)] = [("xs", 1), ("s", 2), ("m", 4), ("l", 8), ("xl", 16)]
    public static let defaultWeight: Double = 4

    /// A size name or a positive number.
    public static func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let size = sizes.first(where: { $0.name == t }) { return size.weight }
        guard let v = Double(t), v.isFinite, v > 0 else { return nil }
        return v
    }

    /// `m` for 4, `3` for 3: the size name when there is one.
    public static func label(_ weight: Double) -> String {
        sizes.first { $0.weight == weight }?.name ?? (weight == weight.rounded() && abs(weight) < 1e15 ? String(Int64(weight)) : String(weight))
    }
}

/// Why a task or run is blocked. Ordered by urgency: input first.
public enum TaskWaitReason: String, LenientStringEnum, CaseIterable, Comparable {
    /// A person has to answer (permission prompt, question).
    case input
    /// A usage limit.
    case limit
    /// Another task or an outside event.
    case dependency
    public static let fallback = TaskWaitReason.dependency

    public static func < (a: Self, b: Self) -> Bool { a.urgency < b.urgency }
    var urgency: Int { switch self { case .input: 0; case .limit: 1; case .dependency: 2 } }
}

/// What a node is doing. Leaves use planned through cancelled; `partial` and `parked` only come
/// from children.
public enum TaskState: String, LenientStringEnum, CaseIterable {
    case planned, running, waiting
    /// Some children finished, others haven't started, and nothing is running.
    case parked
    case done
    /// Every child finished but a normal child failed or was cancelled.
    case partial
    case failed, skipped, cancelled
    public static let fallback = TaskState.running

    public var isTerminal: Bool { [.done, .partial, .failed, .skipped, .cancelled].contains(self) }
}

/// A run as a whole.
public enum TaskRunState: String, LenientStringEnum, CaseIterable {
    case running, waiting
    /// The orchestrator ended its turn or the session closed, nothing is active, and unfinished
    /// tasks remain.
    case stopped
    case done, partial, failed
    public static let fallback = TaskRunState.running

    public var isTerminal: Bool { self == .done || self == .partial || self == .failed }
}

/// Display priority for runs and nodes, most pressing first.
public enum TaskAttention: Int, Comparable, Sendable, CaseIterable {
    case needsInput, failed, stale, limit, running, planned, done
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public init(state: TaskState, waitReason: TaskWaitReason?, stale: Bool) {
        switch state {
        case .waiting where waitReason == .input: self = .needsInput
        case .failed, .partial: self = .failed
        case .running where stale: self = .stale
        case .waiting where waitReason == .limit: self = .limit
        case .running, .waiting: self = .running
        case .planned, .parked: self = .planned
        case .done, .skipped, .cancelled: self = .done
        }
    }

    public init(run: TaskRunState, waitReason: TaskWaitReason?, stale: Bool) {
        switch run {
        case .waiting where waitReason == .input: self = .needsInput
        case .failed, .partial: self = .failed
        case .running where stale: self = .stale
        case .waiting where waitReason == .limit: self = .limit
        case .running, .waiting: self = .running
        case .stopped: self = .planned
        case .done: self = .done
        }
    }
}

/// What ran a task.
public enum TaskAttemptKind: String, LenientStringEnum, CaseIterable {
    case agent, delegate, workflow, session
    public static let fallback = TaskAttemptKind.agent
}

public enum TaskAttemptOutcome: String, LenientStringEnum, CaseIterable {
    case ok, error
    /// Cut short: the session ended, the user interrupted, or it went silent for too long. Never
    /// counts as done.
    case interrupted
    public static let fallback = TaskAttemptOutcome.ok
}

/// A question a run is waiting on a person to answer: the harness's question tool, a permission
/// prompt, a plan waiting for approval, or an agent's `task wait --for input --note`.
public struct TaskQuestion: Codable, Sendable, Hashable {
    /// The question as asked, trimmed to `TaskQuestion.maxLength`.
    public var text: String
    /// The answers offered, when the harness offered some.
    public var options: [String]
    /// The task waiting on it; nil when the orchestrator itself asked.
    public var task: String?
    public var askedAt: Date

    public static let maxLength = 400

    public init(text: String, options: [String] = [], task: String? = nil, askedAt: Date) {
        self.text = text; self.options = options; self.task = task; self.askedAt = askedAt
    }

    enum CodingKeys: String, CodingKey {
        case text, options, task
        case askedAt = "asked_at"
    }
}

/// Where a run's wall-clock time went, in seconds, from its first event to its last (or now while live).
public struct TaskTimeSplit: Codable, Sendable, Hashable {
    /// Something was happening: agent or session activity with no long gap.
    public var working: Double
    /// Waiting on a person (a question, a permission prompt, an input wait).
    public var waitingInput: Double
    /// Waiting on a usage limit.
    public var waitingLimit: Double
    /// Nothing happening and nothing being waited on.
    public var idle: Double

    public init(working: Double = 0, waitingInput: Double = 0, waitingLimit: Double = 0, idle: Double = 0) {
        self.working = working; self.waitingInput = waitingInput; self.waitingLimit = waitingLimit; self.idle = idle
    }

    public static let zero = TaskTimeSplit()
    public var total: Double { working + waitingInput + waitingLimit + idle }

    enum CodingKeys: String, CodingKey {
        case working, idle
        case waitingInput = "waiting_input"
        case waitingLimit = "waiting_limit"
    }
}

/// How a live run sits against the usage limit it spends. Filled by `TaskLimits.adjust`.
public struct TaskLimitOutlook: Codable, Sendable, Hashable {
    public var provider: Provider
    /// When the 5-hour window is forecast to run out while the run still has work, if before it finishes.
    public var pauseAt: Date?
    /// When the window resets, if the run is forecast to pause.
    public var resumeAt: Date?
    /// Forecast finish, counting the pause.
    public var finishAt: Date?
    /// Tokens the run is forecast to still need.
    public var tokensNeeded: Int64?
    /// Tokens the window has room for at the current pace.
    public var roomTokens: Int64?
    /// The run's share (0…1) of what this provider is spending right now.
    public var share: Double?

    public init(provider: Provider, pauseAt: Date? = nil, resumeAt: Date? = nil, finishAt: Date? = nil, tokensNeeded: Int64? = nil,
                roomTokens: Int64? = nil, share: Double? = nil) {
        self.provider = provider; self.pauseAt = pauseAt; self.resumeAt = resumeAt; self.finishAt = finishAt
        self.tokensNeeded = tokensNeeded; self.roomTokens = roomTokens; self.share = share
    }

    enum CodingKeys: String, CodingKey {
        case provider, share
        case pauseAt = "pause_at"
        case resumeAt = "resume_at"
        case finishAt = "finish_at"
        case tokensNeeded = "tokens_needed"
        case roomTokens = "room_tokens"
    }
}

/// One entry of the plan list a harness keeps for a session (Claude Code's todo and task tools,
/// Codex's plan tool), as the observer mirrors it. See `TaskEvent.Op.planMirror`.
public struct TaskPlanItem: Codable, Sendable, Hashable {
    public enum Status: String, LenientStringEnum, CaseIterable {
        case pending, inProgress = "in_progress", completed, cancelled
        public static let fallback = Status.pending
    }

    /// Stable across updates of the same list: the harness's own id when it has one, else the
    /// observer's (position plus title).
    public var id: String
    public var title: String
    public var status: Status

    public init(id: String, title: String, status: Status) { self.id = id; self.title = title; self.status = status }
}

/// Three shares of a node, each 0…1: finished work, work under way, and the best guess of how
/// far along it really is (`done` ≤ `estimate`).
public struct TaskProgress: Codable, Sendable, Hashable {
    public var done: Double
    public var inFlight: Double
    public var estimate: Double

    public init(done: Double, inFlight: Double, estimate: Double) { self.done = done; self.inFlight = inFlight; self.estimate = estimate }
    public static let zero = TaskProgress(done: 0, inFlight: 0, estimate: 0)
    public static let complete = TaskProgress(done: 1, inFlight: 0, estimate: 1)

    /// Not started: whatever is neither done nor in flight.
    public var notStarted: Double { max(0, 1 - done - inFlight) }

    enum CodingKeys: String, CodingKey {
        case done, estimate
        case inFlight = "in_flight"
    }
}

/// Critical leaves done out of critical leaves (skipped ones left out).
public struct TaskMustHaves: Codable, Sendable, Hashable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// Declared steps: `done` of `total`.
public struct TaskSteps: Codable, Sendable, Hashable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
    public var fraction: Double { total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0 }
}

/// One executor working on a task. A retry adds an attempt, not a task.
public struct TaskAttempt: Codable, Sendable, Hashable {
    public var key: String
    public var kind: TaskAttemptKind
    public var agentType: String?
    public var model: String?
    public var provider: String?
    public var title: String?
    /// Key of the attempt that spawned this one.
    public var parentKey: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var lastActivityAt: Date
    public var tokens: Int64
    public var outcome: TaskAttemptOutcome?

    public init(key: String, kind: TaskAttemptKind = .agent, agentType: String? = nil, model: String? = nil, provider: String? = nil, title: String? = nil,
                parentKey: String? = nil, startedAt: Date, endedAt: Date? = nil, lastActivityAt: Date? = nil, tokens: Int64 = 0, outcome: TaskAttemptOutcome? = nil) {
        self.key = key; self.kind = kind; self.agentType = agentType; self.model = model; self.provider = provider; self.title = title
        self.parentKey = parentKey; self.startedAt = startedAt; self.endedAt = endedAt; self.lastActivityAt = lastActivityAt ?? startedAt
        self.tokens = tokens; self.outcome = outcome
    }

    public var isActive: Bool { endedAt == nil }

    enum CodingKeys: String, CodingKey {
        case key, kind, model, provider, title, tokens, outcome
        case agentType = "agent_type"
        case parentKey = "parent_key"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case lastActivityAt = "last_activity_at"
    }
}
