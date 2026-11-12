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
    public static let fallback = TaskAttemptOutcome.ok
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
