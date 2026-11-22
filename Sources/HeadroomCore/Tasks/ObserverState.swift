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
    /// Question and plan tool calls waiting for their results, by tool-use (or Codex call) id.
    /// Optional, like every field added after version 1, so older saved state still decodes.
    var calls: [String: CallRec]?
    /// Codex session indexes, keyed by path, including titles for rollouts not yet seen.
    var codexIndexes: [String: CodexSessionIndex]?

    var pendingCalls: [String: CallRec] {
        get { calls ?? [:] }
        set { calls = newValue.isEmpty ? nil : newValue }
    }
}

struct CodexSessionIndex: Codable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int64 = 0
    var offset: UInt64 = 0
    var titles: [String: String] = [:]
}

/// A harness tool call whose result the observer waits for.
struct CallRec: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A question to a person (`AskUserQuestion`, `ExitPlanMode`, Codex `request_user_input`).
        case question
        /// Codex `request_user_input_async`: answered by the person's next message, not its output.
        case asyncQuestion
        /// Claude Code `TaskCreate`: the new item's id comes back in the result.
        case planCreate
    }
    var kind: Kind
    /// `session:<id>` or an attempt key.
    var owner: String
    var session: String
    var at: Double
    /// `TaskCreate`: the item's title, held until its id is known.
    var title: String?
}

/// A question the harness put to a person, until its answer has been written out.
struct PendingQuestion: Codable, Sendable, Hashable {
    /// The tool call's id.
    var id: String
    var text: String
    var options: [String]
    var at: Double
    /// When the result came back.
    var answeredAt: Double?
}

/// One entry of a session's mirrored plan list.
struct PlanEntry: Codable, Sendable, Hashable {
    var id: String
    var title: String
    var status: TaskPlanItem.Status
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
    /// Older cursors need one pass over the consumed lines for run metadata only.
    var readRunMetadata: Bool?
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
    /// The question whose `task.wait` was written and not yet cleared.
    var question: String?
    /// The usage-limit line last written as a `task.wait`.
    var limitAt: Double?
    /// The plan list last written (`plan.mirror`), as a key.
    var plan: String?
    /// The `run.meta` fields last written, as a key.
    var meta: String?
    /// Reuse the first metadata timestamp so even earlier transcript activity leaves updates in order.
    var metaAt: Double?
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
    /// Activity times not yet written, and where sampling counts from (`ActivityTrail`).
    var trail: [Double]?
    var trailFrom: Double?
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
    /// The working folder (Claude lines' `cwd`, Codex `session_meta`). Written to `run.meta` only.
    var cwd: String?
    /// Claude's automatic title or the latest title from the Codex index.
    var sessionTitle: String?
    var customTitle: String?
    var repo: String?
    var branch: String?
    /// The app it runs in, when the transcript says (the Claude desktop app's bundle id).
    var host: String?
    /// Codex: the last turn was aborted by the person (`turn_aborted` with reason `interrupted`).
    var interrupted: Bool?
    /// The harness's question waiting on a person.
    var question: PendingQuestion?
    /// The latest usage-limit line and its note.
    var limitAt: Double?
    var limitNote: String?
    /// The harness's own plan list for the session, as last seen.
    var plan: [PlanEntry]?
    var planTool: String?
    var planAt: Double?
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
    /// Activity times not yet written, and where sampling counts from (`ActivityTrail`).
    var trail: [Double]?
    var trailFrom: Double?
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
    /// A question it put to a person (a subagent's own question tool call).
    var question: PendingQuestion?
    /// Its latest usage-limit line and note.
    var limitAt: Double?
    var limitNote: String?
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
    /// When its result came back. An `Agent` call without one is still running in the foreground.
    var resultAt: Double?
}

/// When work happened between two writes. Activity is written at most every 30 s of wall time,
/// with the latest time only, so a catch-up scan (launch, after sleep) would see hours of work as
/// one moment and the fold would count no working time. The trail keeps the transcript's own
/// times instead: the end of each stretch before a gap, the start of the next, and one time every
/// `step` within a stretch. Written as plain activity before the latest time.
enum ActivityTrail {
    static let step: Double = 240
    static let cap = 2000

    static func note(_ trail: inout [Double]?, _ anchor: inout Double?, from last: Double, to at: Double) {
        guard last > 0, at > last else { return }
        var t = trail ?? []
        let base = anchor ?? last
        if at - last > step {
            // A gap: the stretch before it ended at `last`, a new one starts at `at`.
            if t.last != last { t.append(last) }
            t.append(at)
        } else if at - (t.last ?? base) >= step {
            t.append(at)
        }
        if anchor == nil { anchor = base }
        if t.count > cap { t.removeFirst(t.count - cap) }
        trail = t
    }
}
