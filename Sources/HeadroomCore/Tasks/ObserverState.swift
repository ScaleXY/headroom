import Foundation
import HeadroomKit

/// What the task observer knows, saved to `tasks/observer.plist`: kept apart from `state.plist`
/// and `ingest.plist` so nothing here can ever stop those decoding. Times are seconds since 1970.
/// Holds no prompt text: a delegate's brief is kept only as a hash (`Fingerprint`).
struct ObserverState: Codable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    /// Keyed by path.
    var files: [String: TranscriptFile] = [:]
    /// Keyed by session id.
    var sessions: [String: SessionRec] = [:]
    /// Keyed by attempt key (`agent:<id>`, `delegate:<toolUseId>`, `workflow:<runId>`).
    var attempts: [String: AttemptRec] = [:]
    /// Spawning tool calls by tool-use id, until they're a day old.
    var spawns: [String: SpawnRec] = [:]
    /// T3 Code task id → delegate attempt key.
    var delegateTasks: [String: String] = [:]
    /// Runs already given their `run.meta`.
    var metaRuns: Set<String> = []
    var prunedAt: Double = 0
}

/// Read position and per-file parse state of one transcript.
struct TranscriptFile: Codable, Sendable {
    enum Role: String, Codable, Sendable { case session, agent, workflowAgent, codex }
    var role: Role
    /// Claude: from the path. Codex: from `session_meta`.
    var session: String?
    /// The attempt an agent transcript feeds.
    var agent: String?
    var inode: UInt64 = 0
    var offset: Int64 = 0
    var mtime: Double = 0
    /// Hashes of the message keys last counted: Claude Code repeats a message's usage on each of
    /// its lines, one after another.
    var recentKeys: [UInt64] = []
    /// The first message has been looked at (for delegate matching).
    var sawText = false
}

/// What was last written for an attempt, so only changes are written.
struct Emitted: Codable, Sendable, Hashable {
    var run: String?
    var spec: String?
    var activityAt: Double?
    var tokens: Int64?
    /// Wall-clock time of the last activity event, for the throttle.
    var wall: Double?
    var endedAt: Double?
    var outcome: TaskAttemptOutcome?
    var waitAt: Double?
}

struct SessionRec: Codable, Sendable {
    var id: String
    var harness: String
    var project: String?
    var model: String?
    /// Claude: `<project>/<session>`, where its subagents and workflows live.
    var dir: String?
    var startedAt: Double
    var lastAt: Double
    var tokens: Int64 = 0
    /// The turn ended and nothing has happened since.
    var stoppedAt: Double?
    var stopKey: String?
    /// Codex: the last turn was aborted.
    var aborted = false
    /// Hashes of its first message, while it might still turn out to be a delegate's child.
    var candidates: [UInt64]?
    /// The delegate attempt it works for.
    var boundTo: String?
    /// Something it spawned is tracked in its own run.
    var spawned = false
    var out = Emitted()
    var outStopped: Bool?
}

struct AttemptRec: Codable, Sendable {
    var key: String
    var kind: TaskAttemptKind
    /// The session whose files it was seen in.
    var session: String
    /// The transcript key that spawned it: `session:<id>`, an agent's or a workflow's key.
    var spawner: String?
    var toolUseID: String?
    /// `RUN:PATH` from a `[hr:RUN:PATH]` tag.
    var tag: String?
    var title: String?
    var agentType: String?
    var model: String?
    var provider: String?
    var startedAt: Double
    var lastAt: Double
    var tokens: Int64 = 0
    var endedAt: Double?
    var outcome: TaskAttemptOutcome?
    /// Delegates: the brief's fingerprint until bound, then the child session.
    var brief: UInt64?
    var child: String?
    /// Delegates: when the child last asked a question.
    var waitAt: Double?
    /// `agent-<id>.meta.json`, while worth re-reading.
    var meta: String?
    /// Workflows: `<session>/workflows/<runId>.json`, written when it ends.
    var workflowFile: String?
    var out = Emitted()
}

/// A spawning tool call, held until the attempt it made is known.
struct SpawnRec: Codable, Sendable {
    var tool: ClaudeTranscript.Tool
    var spawner: String
    var session: String
    var at: Double
    var title: String?
    var agentType: String?
    var model: String?
    var tag: String?
    var statusTaskID: String?
    var attempt: String?
    /// An end reported before the attempt was known.
    var endedAt: Double?
    var outcome: TaskAttemptOutcome?
}
