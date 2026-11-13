import Foundation

/// One line of a task event file (`tasks/journal/<run>.jsonl`, `tasks/observed/<run>.jsonl`).
///
/// Wire format, version 1: one flat JSON object per line, snake_case keys, dates as ISO 8601 UTC
/// with milliseconds (`2026-11-12T10:04:05.120Z`; whole seconds also read). Every line carries
/// `v` (format version), `ts`, `run`, `src` (`agent`, `harness`, `hook`, `user`) and `op`:
///
/// | `op` | fields |
/// | :- | :- |
/// | `run.meta` | `title`, `project`, `harness`, `host`, `cwd` (each optional; `host` and `cwd` stay on this Mac, never synced) |
/// | `task.add` | `task`, `title`, `effort` (number), `importance`, `steps` (total); re-adding updates the fields given |
/// | `task.start` | `task` |
/// | `task.progress` | `task`, `step` (done), `steps` (total), `fraction` (0…1), `note` |
/// | `task.wait` | `task` or `attempt` (key), or neither for the run itself; `for` (`input`, `limit`, `dependency`), `note`, `options` (answers offered) |
/// | `task.done` | `task`, `evidence` |
/// | `task.fail` | `task`, `reason`, `instead` (the task that replaces it, when the agent worked around the failure) |
/// | `task.skip`, `task.cancel` | `task`, `reason` |
/// | `attempt.upsert` | `attempt` (key), `kind` (`agent`, `delegate`, `workflow`, `session`), `agent_type`, `model`, `provider`, `tag` (task path, `RUN:PATH` or `[hr:RUN:PATH]`), `parent` (spawning attempt's key), `title` |
/// | `attempt.activity` | `attempt`, `at` (defaults to `ts`), `tokens` (running total) |
/// | `attempt.end` | `attempt`, `outcome` (`ok`, `error`); ignored for an attempt never seen |
/// | `run.stop` | `blocked` (true when an enforcing Stop hook sent the agent back, which leaves the run running) |
/// | `run.resume`, `run.end` | none |
/// | `plan.mirror` | `items` (`[{id, title, status}]`, the whole list each time), `tool` (which plan tool: `todo`, `tasks`, `codex-plan`, `desktop-plan`) |
/// | `run.hide` | `hidden` (default true; false shows it again) |
/// | `run.abandon` | `reason` |
///
/// ```
/// {"op":"task.add","run":"7f3a","src":"agent","task":"api/tests","title":"API tests","effort":8,"importance":"critical","ts":"2026-11-12T10:00:00.000Z","v":1}
/// {"attempt":"agent:a49c1","op":"attempt.upsert","kind":"agent","agent_type":"general-purpose","tag":"api/tests","run":"7f3a","src":"hook","ts":"2026-11-12T10:00:02.310Z","v":1}
/// ```
///
/// Readers ignore keys they don't know. A line with an unknown `op` fails to decode on its own and
/// `TaskJournal.decode` skips it, so a newer writer never costs an older reader the rest of the file.
public struct TaskEvent: Sendable, Hashable {
    public static let version = 1

    public var at: Date
    public var run: String
    public var source: TaskSource
    public var op: Op

    public init(at: Date, run: String, source: TaskSource, op: Op) { self.at = at; self.run = run; self.source = source; self.op = op }

    public enum Op: Sendable, Hashable {
        /// `host` is the app the session runs in (a bundle id such as `com.googlecode.iterm2`, or
        /// `$TERM_PROGRAM`); `cwd` its working folder. Both stay on this Mac.
        case meta(title: String?, project: String?, harness: String?, host: String? = nil, cwd: String? = nil)
        case add(TaskSpec)
        case start(task: String)
        case progress(task: String, step: Int?, total: Int?, fraction: Double?, note: String?)
        /// Neither `task` nor `attempt`: the run itself waits (the orchestrator is asking a person).
        case wait(task: String?, attempt: String?, reason: TaskWaitReason, note: String?, options: [String]? = nil)
        case done(task: String, evidence: String?)
        /// `instead`: the task taking over from this one (another approach to the same end).
        case fail(task: String, reason: String?, instead: String? = nil)
        case skip(task: String, reason: String?)
        case cancel(task: String, reason: String?)
        case attempt(AttemptSpec)
        case activity(attempt: String, at: Date?, tokens: Int64?)
        case attemptEnd(attempt: String, outcome: TaskAttemptOutcome?)
        case stop(blocked: Bool)
        case resume
        case end
        /// The harness's own plan list for the session, mirrored by the observer (source `harness`).
        /// Gives a run a plan when the agent declared none; ignored once anything is declared.
        case planMirror(items: [TaskPlanItem], tool: String?)
        /// A person hid the run (or showed it again) from the app.
        case hide(Bool)
        /// A person gave up on the run from the app: open tasks are cancelled and it ends.
        case abandon(reason: String?)

        public var name: String {
            switch self {
            case .meta: "run.meta"
            case .add: "task.add"
            case .start: "task.start"
            case .progress: "task.progress"
            case .wait: "task.wait"
            case .done: "task.done"
            case .fail: "task.fail"
            case .skip: "task.skip"
            case .cancel: "task.cancel"
            case .attempt: "attempt.upsert"
            case .activity: "attempt.activity"
            case .attemptEnd: "attempt.end"
            case .stop: "run.stop"
            case .resume: "run.resume"
            case .end: "run.end"
            case .planMirror: "plan.mirror"
            case .hide: "run.hide"
            case .abandon: "run.abandon"
            }
        }

        /// The task path the op names directly, if any.
        public var task: String? {
            switch self {
            case .add(let s): s.id
            case .start(let t), .progress(let t, _, _, _, _), .done(let t, _), .fail(let t, _, _), .skip(let t, _), .cancel(let t, _): t
            case .wait(let t, _, _, _, _): t
            default: nil
            }
        }
    }

    /// A declared task. Nil fields leave the current value alone when re-adding.
    public struct TaskSpec: Sendable, Hashable {
        public var id: String
        public var title: String?
        public var effort: Double?
        public var importance: TaskImportance?
        public var steps: Int?
        public init(id: String, title: String? = nil, effort: Double? = nil, importance: TaskImportance? = nil, steps: Int? = nil) {
            self.id = id; self.title = title; self.effort = effort; self.importance = importance; self.steps = steps
        }
    }

    /// An executor seen working. `tag` binds it to a task; without one it gets an implicit task
    /// under whatever its spawning attempt (`parentKey`) works on.
    public struct AttemptSpec: Sendable, Hashable {
        public var key: String
        public var kind: TaskAttemptKind
        public var agentType: String?
        public var model: String?
        public var provider: String?
        public var tag: String?
        public var parentKey: String?
        public var title: String?
        public init(key: String, kind: TaskAttemptKind = .agent, agentType: String? = nil, model: String? = nil, provider: String? = nil,
                    tag: String? = nil, parentKey: String? = nil, title: String? = nil) {
            self.key = key; self.kind = kind; self.agentType = agentType; self.model = model; self.provider = provider
            self.tag = tag; self.parentKey = parentKey; self.title = title
        }

        /// The task path the tag names: a bare path, `RUN:PATH`, or a `[hr:RUN:PATH]` anywhere in it.
        public var taggedPath: String? {
            guard let tag, !tag.isEmpty else { return nil }
            if let ref = TaskRef.firstTag(in: tag) ?? TaskRef(tag) { return ref.path }
            return TaskPath.isValid(tag) ? tag : nil
        }
    }
}

extension TaskEvent: Codable {
    enum Key: String, CodingKey {
        case v, ts, run, src, op, task, title, project, harness, host, cwd, effort, importance, steps, step, fraction, note, options
        case waitFor = "for", evidence, reason, attempt, kind, model, provider, tag, parent, at, tokens, outcome, blocked, items, tool, hidden, instead
        case agentType = "agent_type"
    }

    public struct UnknownOp: Error { public var op: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        at = try c.decode(Date.self, forKey: .ts)
        run = try c.decode(String.self, forKey: .run)
        source = try c.decodeIfPresent(TaskSource.self, forKey: .src) ?? .agent
        func s(_ k: Key) throws -> String? { try c.decodeIfPresent(String.self, forKey: k) }
        func task() throws -> String { try c.decode(String.self, forKey: .task) }
        func attempt() throws -> String { try c.decode(String.self, forKey: .attempt) }
        let name = try c.decode(String.self, forKey: .op)
        switch name {
        case "run.meta": op = .meta(title: try s(.title), project: try s(.project), harness: try s(.harness), host: try s(.host), cwd: try s(.cwd))
        case "task.add":
            op = .add(TaskSpec(id: try task(), title: try s(.title), effort: try c.decodeIfPresent(Double.self, forKey: .effort),
                               importance: try c.decodeIfPresent(TaskImportance.self, forKey: .importance), steps: try c.decodeIfPresent(Int.self, forKey: .steps)))
        case "task.start": op = .start(task: try task())
        case "task.progress":
            op = .progress(task: try task(), step: try c.decodeIfPresent(Int.self, forKey: .step), total: try c.decodeIfPresent(Int.self, forKey: .steps),
                           fraction: try c.decodeIfPresent(Double.self, forKey: .fraction), note: try s(.note))
        case "task.wait":
            op = .wait(task: try s(.task), attempt: try s(.attempt), reason: try c.decodeIfPresent(TaskWaitReason.self, forKey: .waitFor) ?? .dependency, note: try s(.note),
                       options: try c.decodeIfPresent([String].self, forKey: .options))
        case "task.done": op = .done(task: try task(), evidence: try s(.evidence))
        case "task.fail": op = .fail(task: try task(), reason: try s(.reason), instead: try s(.instead))
        case "task.skip": op = .skip(task: try task(), reason: try s(.reason))
        case "task.cancel": op = .cancel(task: try task(), reason: try s(.reason))
        case "attempt.upsert":
            op = .attempt(AttemptSpec(key: try attempt(), kind: try c.decodeIfPresent(TaskAttemptKind.self, forKey: .kind) ?? .agent,
                                      agentType: try s(.agentType), model: try s(.model), provider: try s(.provider), tag: try s(.tag),
                                      parentKey: try s(.parent), title: try s(.title)))
        case "attempt.activity":
            op = .activity(attempt: try attempt(), at: try c.decodeIfPresent(Date.self, forKey: .at), tokens: try c.decodeIfPresent(Int64.self, forKey: .tokens))
        case "attempt.end": op = .attemptEnd(attempt: try attempt(), outcome: try c.decodeIfPresent(TaskAttemptOutcome.self, forKey: .outcome))
        case "run.stop": op = .stop(blocked: try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false)
        case "run.resume": op = .resume
        case "run.end": op = .end
        case "plan.mirror": op = .planMirror(items: try c.decodeIfPresent([TaskPlanItem].self, forKey: .items) ?? [], tool: try s(.tool))
        case "run.hide": op = .hide(try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? true)
        case "run.abandon": op = .abandon(reason: try s(.reason))
        default: throw UnknownOp(op: name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(Self.version, forKey: .v)
        try c.encode(at, forKey: .ts)
        try c.encode(run, forKey: .run)
        try c.encode(source, forKey: .src)
        try c.encode(op.name, forKey: .op)
        switch op {
        case .meta(let title, let project, let harness, let host, let cwd):
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(project, forKey: .project)
            try c.encodeIfPresent(harness, forKey: .harness)
            try c.encodeIfPresent(host, forKey: .host)
            try c.encodeIfPresent(cwd, forKey: .cwd)
        case .add(let spec):
            try c.encode(spec.id, forKey: .task)
            try c.encodeIfPresent(spec.title, forKey: .title)
            try c.encodeIfPresent(spec.effort, forKey: .effort)
            try c.encodeIfPresent(spec.importance, forKey: .importance)
            try c.encodeIfPresent(spec.steps, forKey: .steps)
        case .start(let t):
            try c.encode(t, forKey: .task)
        case .progress(let t, let step, let total, let fraction, let note):
            try c.encode(t, forKey: .task)
            try c.encodeIfPresent(step, forKey: .step)
            try c.encodeIfPresent(total, forKey: .steps)
            try c.encodeIfPresent(fraction, forKey: .fraction)
            try c.encodeIfPresent(note, forKey: .note)
        case .wait(let t, let a, let reason, let note, let options):
            try c.encodeIfPresent(t, forKey: .task)
            try c.encodeIfPresent(a, forKey: .attempt)
            try c.encode(reason, forKey: .waitFor)
            try c.encodeIfPresent(note, forKey: .note)
            if let options, !options.isEmpty { try c.encode(options, forKey: .options) }
        case .done(let t, let evidence):
            try c.encode(t, forKey: .task)
            try c.encodeIfPresent(evidence, forKey: .evidence)
        case .fail(let t, let reason, let instead):
            try c.encode(t, forKey: .task)
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encodeIfPresent(instead, forKey: .instead)
        case .skip(let t, let reason), .cancel(let t, let reason):
            try c.encode(t, forKey: .task)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .attempt(let a):
            try c.encode(a.key, forKey: .attempt)
            try c.encode(a.kind, forKey: .kind)
            try c.encodeIfPresent(a.agentType, forKey: .agentType)
            try c.encodeIfPresent(a.model, forKey: .model)
            try c.encodeIfPresent(a.provider, forKey: .provider)
            try c.encodeIfPresent(a.tag, forKey: .tag)
            try c.encodeIfPresent(a.parentKey, forKey: .parent)
            try c.encodeIfPresent(a.title, forKey: .title)
        case .activity(let a, let at, let tokens):
            try c.encode(a, forKey: .attempt)
            try c.encodeIfPresent(at, forKey: .at)
            try c.encodeIfPresent(tokens, forKey: .tokens)
        case .attemptEnd(let a, let outcome):
            try c.encode(a, forKey: .attempt)
            try c.encodeIfPresent(outcome, forKey: .outcome)
        case .stop(let blocked):
            if blocked { try c.encode(true, forKey: .blocked) }
        case .resume, .end:
            break
        case .planMirror(let items, let tool):
            try c.encode(items, forKey: .items)
            try c.encodeIfPresent(tool, forKey: .tool)
        case .hide(let hidden):
            try c.encode(hidden, forKey: .hidden)
        case .abandon(let reason):
            try c.encodeIfPresent(reason, forKey: .reason)
        }
    }
}
