import Foundation

/// Folds task events into runs: a pure function of the events, the clock, the stale and abandon
/// thresholds and the token calibration.
///
/// Leaf states, in order of precedence:
/// 1. A declared terminal state (done, failed, skipped, cancelled) wins over liveness. A new
///    attempt, or a `start`, after it reopens the task and counts a retry.
/// 2. Any active attempt makes the leaf `running`, unless a wait declared after that attempt
///    started holds. A wait is cleared by a later `start` or `progress`, or by later activity on
///    the task's attempts; a wait an agent or a person declared only by activity a minute after it
///    (the call that declared it shows up as activity of its own).
/// 3. With every attempt ended and nothing declared since: the last attempt's `error` gives
///    `failed`, `interrupted` gives `parked` (cut short: the session ended, or the agent was silent
///    for `abandonAfter`), anything else `done`; all three flagged unconfirmed.
/// 4. Otherwise the declared mark: planned, running (`start`, `progress`) or waiting. A task the
///    orchestrator was doing itself is `parked` once the session has ended or gone silent.
///
/// Parents are always derived from their children (a terminal op on a parent closes its open
/// descendants instead). A parent weighs what its counted children weigh together, unless an
/// effort was declared for it. An agent nobody tagged gets an implicit `~` task under the task its
/// spawning attempt works on; once there is a plan such helpers are shown but never count, so they
/// can't dilute it. In a run with no plan the agents are the plan, and an agent that spawned others
/// counts as one unit beside them. A `session` attempt is the orchestrator itself: it adds activity
/// to the run, and its tokens and working time go to the tasks it is doing itself (running, with no
/// agent on them), split by effort.
///
/// The plan is what an agent or a person declared; failing that, the harness's own plan list
/// (`plan.mirror`), one task per item under `~plan/`, until anything is declared. Agents seen before
/// the first declaration keep counting, grouped under `~earlier` beside the plan, so declaring late
/// doesn't throw away what they did. A tag naming a task the plan doesn't have makes a helper
/// under the deepest task it does have.
///
/// `progress.done` is closed work with a confirmed outcome, plus the steps or fraction agents
/// reported on open tasks. `progress.estimate` is the best guess: it adds agents that ended without
/// a word (inferred done) and partial credit for running tasks from, in order of trust, reported
/// progress, tokens against the calibrated tokens per effort unit, and working time against what
/// the run's finished tasks took per unit of effort, capped at `maxGuess`.
public enum TaskFold {
    /// How soon after a failure that says it's going another way the next task added is taken as
    /// its replacement.
    public static let pivotWindow: TimeInterval = 120

    /// A failure reason that says the agent is working around it ("…, doing X instead").
    public static func pivots(_ reason: String?) -> Bool {
        guard let r = reason?.lowercased() else { return false }
        return ["instead", "workaround", "work around", "worked around", "fallback", "fall back", "falling back", "alternative",
                "switching to", "switched to", "rather than", "replaced by", "replacing it", "pivot"].contains { r.contains($0) }
    }

    public static let defaultStaleAfter: TimeInterval = 15 * 60
    /// With no activity for this long an agent counts as cut short, and the run as stopped.
    public static let defaultAbandonAfter: TimeInterval = 2 * 3600
    /// How much working time the forecast's recent rate looks back over.
    public static let forecastWindow: TimeInterval = 45 * 60
    /// Activity closer together than this is one stretch of work.
    public static let workingGap: TimeInterval = 5 * 60
    /// How much working time the recent token rate looks back over…
    public static let recentWindow: TimeInterval = 30 * 60
    /// …and never further back than this on the clock.
    public static let recentLookback: TimeInterval = 3 * 3600
    /// An agent's or a person's own wait isn't cleared by activity sooner than this after it.
    public static let waitGrace: TimeInterval = 60
    /// Partial credit for a running task never goes past this without a report saying so.
    public static let maxGuess = 0.9
    /// A run that isn't finished never reads as all done.
    static let openCap = 0.99
    /// The group holding agents that worked before anything was declared.
    public static let earlierID = "~earlier"
    public static let earlierTitle = "Earlier work"
    /// Mirrored plan items: `~plan/<item id made path-safe>`. Never created as a node of its own.
    public static let planPrefix = "~plan/"

    /// Every run in `events`, most recently updated first. Events apply in timestamp order, ties in
    /// the order given (pass the journal before the observed file).
    public static func fold(_ events: [TaskEvent], now: Date, staleAfter: TimeInterval = defaultStaleAfter,
                            tokensPerEffortUnit: Double? = nil, abandonAfter: TimeInterval = defaultAbandonAfter) -> [TaskRun] {
        var byRun: [String: [TaskEvent]] = [:]
        for e in events { byRun[e.run, default: []].append(e) }
        return byRun.map { run, list in
            fold(run: run, list, now: now, staleAfter: staleAfter, tokensPerEffortUnit: tokensPerEffortUnit, abandonAfter: abandonAfter)
        }.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
    }

    /// Folds twice: first to learn tokens per effort unit from the finished leaves, then with it.
    public static func foldCalibrated(_ events: [TaskEvent], now: Date, staleAfter: TimeInterval = defaultStaleAfter,
                                      abandonAfter: TimeInterval = defaultAbandonAfter) -> [TaskRun] {
        let first = fold(events, now: now, staleAfter: staleAfter, abandonAfter: abandonAfter)
        guard let tpu = tokensPerEffortUnit(first) else { return first }
        return fold(events, now: now, staleAfter: staleAfter, tokensPerEffortUnit: tpu, abandonAfter: abandonAfter)
    }

    /// Median of tokens ÷ effort over done leaves that spent tokens.
    public static func tokensPerEffortUnit(_ runs: [TaskRun]) -> Double? {
        median(runs.flatMap(\.nodes).filter { $0.leaf && $0.counted && $0.state == .done && $0.tokens > 0 && $0.effort > 0 }
            .map { Double($0.tokens) / $0.effort })
    }

    static func median(_ values: [Double]) -> Double? {
        let v = values.sorted()
        guard !v.isEmpty else { return nil }
        let mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    static func fold(run: String, _ events: [TaskEvent], now: Date, staleAfter: TimeInterval, tokensPerEffortUnit: Double?,
                     abandonAfter: TimeInterval) -> TaskRun {
        let ordered = events.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        var b = RunBuilder(id: run, at: ordered.first?.at ?? now, abandonAfter: abandonAfter)
        for e in ordered { b.apply(e) }
        b.flushSessionTokens()
        return b.result(now: now, staleAfter: staleAfter, tpu: tokensPerEffortUnit)
    }
}

// MARK: - Spans

/// A stretch of time, `start…end`.
struct Span: Hashable {
    var start: Date
    var end: Date
    var length: Double { max(0, end.timeIntervalSince(start)) }
}

extension Array where Element == Span {
    /// Activity at `t`: extends the last stretch when within `gap` of its end, else starts a new
    /// one. A time before the last end is inside work already seen.
    mutating func mark(_ t: Date, gap: TimeInterval) {
        if let last = last {
            if t <= last.end { return }
            if t.timeIntervalSince(last.end) <= gap { self[count - 1].end = t; return }
        }
        append(Span(start: t, end: t))
    }
}

/// Sets of time as sorted, disjoint stretches.
enum Spans {
    static func normalized(_ s: [Span]) -> [Span] {
        guard s.count > 1 else { return s }
        var out: [Span] = []
        for x in s.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let l = out.last, x.start <= l.end { out[out.count - 1].end = Swift.max(l.end, x.end) } else { out.append(x) }
        }
        return out
    }

    static func measure(_ s: [Span]) -> Double { s.reduce(0) { $0 + $1.length } }

    static func clip(_ s: [Span], from: Date, to: Date) -> [Span] {
        s.compactMap { x in
            let a = Swift.max(x.start, from), b = Swift.min(x.end, to)
            return a < b ? Span(start: a, end: b) : nil
        }
    }

    /// `a` without `b`; both normalized.
    static func subtract(_ a: [Span], _ b: [Span]) -> [Span] {
        guard !b.isEmpty else { return a }
        var out: [Span] = []
        var j = 0
        for x in a {
            var start = x.start
            while j < b.count, b[j].end <= start { j += 1 }
            var k = j
            while k < b.count, b[k].start < x.end {
                if b[k].start > start { out.append(Span(start: start, end: b[k].start)) }
                start = Swift.max(start, b[k].end)
                k += 1
            }
            if start < x.end { out.append(Span(start: start, end: x.end)) }
        }
        return out
    }
}

// MARK: - Builder

struct RunBuilder {
    enum Mark: Equatable {
        case planned, started
        case waiting(TaskWaitReason)
        case terminal(TaskState)
    }

    /// A task as the events left it. A class: the fold touches one for nearly every event, and
    /// reading a field out of a dictionary of large structs copies the whole struct.
    final class Rec {
        let id: String
        var title: String
        var effort = TaskEffort.defaultWeight
        /// An effort was declared for it (a group's own weight then wins over its children's).
        var effortSet = false
        var importance = TaskImportance.normal
        var declared: Bool
        /// Set for the implicit task of an untagged attempt: placed by that attempt's parent.
        var ownerAttempt: String?
        /// Where a helper sits regardless of its spawner: a task id, or "" for the top.
        var anchor: String?
        /// An item of the harness's plan list.
        var mirrored = false
        var createdAt: Date
        var steps: TaskSteps?
        /// A step reported while no total was known: shown once one is.
        var pendingStep: Int?
        var stepsAt: Date?
        var fraction: Double?
        var fractionAt: Date?
        var note: String?
        var waitNote: String?
        var waitOptions: [String] = []
        /// Activity clears the wait only after this.
        var waitClearAfter: Date
        var evidence: String?
        var failure: String?
        /// The task that took over from this one after it failed.
        var replacedBy: String?
        var mark = Mark.planned
        var markAt: Date
        var attemptKeys: [String] = []
        var retries = 0
        /// A `start` reopened it and counted the retry: the agent that picks it up is that retry.
        var restarted = false
        var startedAt: Date?
        var lastActivity: Date
        /// The orchestrator's tokens spent while it was doing this task itself.
        var sessionTokens: Int64 = 0
        var stretches: [Span] = []

        init(id: String, title: String, declared: Bool, at: Date) {
            self.id = id; self.title = title; self.declared = declared
            createdAt = at; markAt = at; lastActivity = at; waitClearAfter = at
        }
    }

    final class Att {
        var attempt: TaskAttempt
        /// "" for the orchestrator's own session.
        var task: String
        init(attempt: TaskAttempt, task: String) { self.attempt = attempt; self.task = task }
    }

    struct RunWait {
        var reason: TaskWaitReason
        var at: Date
        var clearAfter: Date
        var note: String?
        var options: [String]
    }

    let id: String
    let abandonAfter: TimeInterval
    var title: String?
    var project: String?
    var harness: String?
    var host: String?
    var cwd: String?
    var sessionTitle: String?
    var repo: String?
    var branch: String?
    var startedAt: Date
    var updatedAt: Date
    var tasks: [String: Rec] = [:]
    var order: [String] = []
    /// Children by path parent, for telling leaves apart while applying.
    var childCount: [String: Int] = [:]
    var attempts: [String: Att] = [:]
    var stoppedAt: Date?
    /// The session ended (`run.end`), until it works again.
    var endedAt: Date?
    var runWait: RunWait?
    var firstStart: Date?
    var scopeChanges = 0
    var lastActivity: Date
    var lastSessionActivity: Date?
    /// A failure whose reason says the agent is going another way: the next task it adds, soon
    /// after, is taken as the one replacing it.
    var lastPivot: (task: String, at: Date)?
    var hidden = false
    var abandoned = false
    /// An agent or a person declared a task, and when that first happened.
    var declaredAny = false
    var firstDeclaredAt: Date?
    var mirrorCount = 0
    /// Tasks whose mark is `started`, and how many wait for each reason (by urgency).
    var startedSet: Set<String> = []
    var waitCounts = [0, 0, 0]
    /// Where the run's time went: activity stretches, and spans waiting for input or a limit.
    var runStretches: [Span] = []
    var inputSpans: [Span] = []
    var limitSpans: [Span] = []
    var inputOpen: Date?
    var limitOpen: Date?
    /// Token growth as it was seen, for the recent rate.
    var tokenSamples: [(at: Date, tokens: Int64)] = []
    /// Session tokens not yet given to the tasks the orchestrator is doing.
    var pendingSessionTokens: Int64 = 0
    /// `orchestratorTasks()` as of the last event that could change it.
    var ownedCache: [String]?

    init(id: String, at: Date, abandonAfter: TimeInterval = TaskFold.defaultAbandonAfter) {
        self.id = id; self.abandonAfter = abandonAfter
        startedAt = at; updatedAt = at; lastActivity = at
    }

    /// The harness's plan list is the plan.
    var mirrorActive: Bool { !declaredAny && mirrorCount > 0 }
    /// Something besides the agents makes the plan: helpers then never count.
    var hasPlan: Bool { declaredAny || mirrorActive }

    // MARK: Applying events

    mutating func apply(_ e: TaskEvent) {
        // Activity of an attempt already seen and still open is the one kind of event that changes
        // nothing but times and token totals, so session tokens can pile up across it.
        var plain = false
        if case .activity(let key, _, _) = e.op, let a = attempts[key] { plain = a.attempt.isActive }
        if !plain { flushSessionTokens(); ownedCache = nil }
        defer { noteWaits(at: e.at) }
        if case .hide = e.op {} else { updatedAt = max(updatedAt, e.at) }
        startedAt = min(startedAt, e.at)
        let byAgent = e.source == .agent, byPerson = e.source == .user
        if byAgent || byPerson, e.op.task != nil {
            // A person acting on a task is back at the run; an agent reporting is working.
            if byPerson { stoppedAt = nil; endedAt = nil; runWait = nil } else if byAgent { clearRunWait(at: e.at) }
        }
        switch e.op {
        case .meta(let t, let p, let h, let host, let cwd, let sessionTitle, let repo, let branch):
            if let t = TaskText.title(t) { title = t }
            if let p = TaskText.title(p) { project = p }
            if let h = TaskText.title(h) { harness = h }
            if let host = TaskText.clean(host, limit: 400) { self.host = host }
            if let cwd = TaskText.clean(cwd, limit: 2048) { self.cwd = cwd }
            if let sessionTitle = TaskText.title(sessionTitle) { self.sessionTitle = sessionTitle }
            if let repo = TaskText.clean(repo, limit: 400) { self.repo = repo }
            if let branch = TaskText.clean(branch, limit: 400) { self.branch = branch }
        case .add(let spec):
            let existed = tasks[spec.id] != nil
            guard ensure(spec.id, at: e.at, declared: true) else { return }
            let effort = spec.effort.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if firstStart != nil, !existed || (effort != nil && effort != tasks[spec.id]?.effort) { scopeChanges += 1 }
            let r = tasks[spec.id]!
            if !existed, byAgent, let p = lastPivot, e.at.timeIntervalSince(p.at) <= TaskFold.pivotWindow, spec.id != p.task,
               !spec.id.hasPrefix(p.task + "/"), let failed = tasks[p.task], failed.replacedBy == nil {
                failed.replacedBy = spec.id
                lastPivot = nil
            }
            // Taking over from a must-have makes it one.
            if spec.importance == nil, tasks.values.contains(where: { $0.replacedBy == spec.id && $0.importance == .critical }) { r.importance = .critical }
            if let t = TaskText.title(spec.title) { r.title = t }
            if let effort { r.effort = effort; r.effortSet = true }
            if let imp = spec.importance { r.importance = imp }
            if let n = spec.steps, n > 0 {
                r.steps = TaskSteps(done: min(r.steps?.done ?? r.pendingStep ?? 0, n), total: n)
                r.pendingStep = nil
            }
            touch(spec.id, at: e.at, work: false)
        case .start(let t):
            guard ensure(t, at: e.at, declared: true) else { return }
            if case .terminal = tasks[t]!.mark { tasks[t]!.retries += 1; tasks[t]!.restarted = true }
            // Back on it: nothing replaces it any more.
            tasks[t]!.replacedBy = nil
            setMark(t, .started, at: e.at)
            tasks[t]!.startedAt = tasks[t]!.startedAt ?? e.at
            touch(t, at: e.at)
            firstStart = firstStart ?? e.at
        case .progress(let t, let step, let total, let fraction, let note):
            guard ensure(t, at: e.at, declared: true) else { return }
            let r = tasks[t]!
            let known = total.flatMap { $0 > 0 ? $0 : nil } ?? r.steps?.total
            if let step, step >= 0 {
                // With no total known, a step says how far but not how far along.
                r.stepsAt = e.at
                if let known { r.steps = TaskSteps(done: step, total: max(step, known)); r.pendingStep = nil } else { r.pendingStep = step }
            } else if let total, total > 0 {
                r.steps = TaskSteps(done: r.steps?.done ?? r.pendingStep ?? 0, total: total)
                r.pendingStep = nil
            }
            if let fraction, fraction.isFinite { r.fraction = min(1, max(0, fraction)); r.fractionAt = e.at }
            if let note = TaskText.note(note) { r.note = note }
            r.startedAt = r.startedAt ?? e.at
            switch r.mark {
            case .planned, .waiting: setMark(t, .started, at: e.at)
            default: break
            }
            touch(t, at: e.at)
            firstStart = firstStart ?? e.at
        case .wait(let t, let key, let reason, let note, let options):
            let note = TaskText.note(note), options = TaskText.options(options)
            let clearAfter = e.at.addingTimeInterval(byAgent || byPerson ? TaskFold.waitGrace : 0)
            // An unknown agent asking for input still means the run needs a person.
            guard let target = t ?? key.flatMap({ attempts[$0]?.task }).flatMap({ $0.isEmpty ? nil : $0 }) else {
                runWait = RunWait(reason: reason, at: e.at, clearAfter: clearAfter, note: note, options: options)
                return
            }
            // Only agents and people declare; a hook or the observer waiting on a task doesn't.
            guard ensure(target, at: e.at, declared: byAgent || byPerson) else { return }
            if case .terminal = tasks[target]!.mark { touch(target, at: e.at, work: false); return }
            let working = inWork(target)
            setMark(target, .waiting(reason), at: e.at)
            tasks[target]!.waitNote = note
            tasks[target]!.waitOptions = options
            tasks[target]!.waitClearAfter = clearAfter
            touch(target, at: e.at, work: working)
        case .done(let t, let evidence):
            // Done after all: an earlier failure and its replacement no longer describe it.
            close(t, as: .done, at: e.at) { r in if let v = TaskText.note(evidence) { r.evidence = v }; r.failure = nil; r.replacedBy = nil }
            firstStart = firstStart ?? e.at
        case .fail(let t, let reason, let instead):
            close(t, as: .failed, at: e.at) { r in if let v = TaskText.note(reason) { r.failure = v } }
            if let instead, TaskPath.isValid(instead), instead != t, let r = tasks[t] {
                r.replacedBy = instead
                if r.importance == .critical, let next = tasks[instead], next.importance == .normal { next.importance = .critical }
            } else if byAgent, TaskFold.pivots(reason) {
                lastPivot = (t, e.at)
            }
            firstStart = firstStart ?? e.at
        case .skip(let t, let reason):
            close(t, as: .skipped, at: e.at) { r in if let v = TaskText.note(reason) { r.note = v } }
        case .cancel(let t, let reason):
            close(t, as: .cancelled, at: e.at) { r in if let v = TaskText.note(reason) { r.note = v } }
        case .attempt(let spec):
            upsert(spec, at: e.at)
        case .activity(let key, let at, let tokens):
            if attempts[key] == nil { upsert(TaskEvent.AttemptSpec(key: key), at: e.at) }
            let a = attempts[key]!
            let when = at ?? e.at
            a.attempt.lastActivityAt = max(a.attempt.lastActivityAt, when)
            var gained: Int64 = 0
            if let tokens, tokens > a.attempt.tokens { gained = tokens - a.attempt.tokens; a.attempt.tokens = tokens }
            if gained > 0 { tokenSamples.append((when, gained)) }
            if a.task.isEmpty {
                // The orchestrator: its time and tokens go to what it is doing itself.
                pendingSessionTokens += gained
                orchestratorActive(at: when)
                if ownedCache == nil { ownedCache = orchestratorTasks() }
                for id in ownedCache! { tasks[id]?.stretches.mark(when, gap: TaskFold.workingGap) }
                touchRun(when)
            } else {
                activity(onAttempt: key, at: when)
            }
        case .attemptEnd(let key, let outcome):
            // An end for an agent never seen starting is one of the harness's own (prompt
            // suggestions, side questions): nothing to show.
            guard let a = attempts[key] else { return }
            a.attempt.endedAt = e.at
            a.attempt.outcome = outcome
            a.attempt.lastActivityAt = max(a.attempt.lastActivityAt, e.at)
            touch(a.task, at: e.at)
        case .stop(let blocked):
            // A Stop hook that sent the agent back to work didn't stop anything.
            if !blocked { stoppedAt = e.at }
        case .resume:
            stoppedAt = nil
            endedAt = nil
            runWait = nil
            abandoned = false
        case .end:
            stoppedAt = e.at
            endedAt = e.at
            runWait = nil
            // Nothing outlives the session: what is still open was cut short.
            interruptActive(at: e.at)
        case .planMirror(let items, _):
            if !declaredAny { mirror(items, at: e.at) }
        case .hide(let h):
            hidden = h
        case .abandon(let reason):
            abandon(reason: reason, at: e.at)
        }
    }

    /// The orchestrator did something: a stop or end before it is over, and a run-level wait
    /// before it (past its grace) is answered.
    mutating func orchestratorActive(at: Date) {
        lastSessionActivity = max(lastSessionActivity ?? at, at)
        if let s = stoppedAt, at > s { stoppedAt = nil }
        if let e = endedAt, at > e { endedAt = nil }
        clearRunWait(at: at)
    }

    mutating func clearRunWait(at: Date) {
        if let w = runWait, at > w.clearAfter { runWait = nil }
    }

    /// Creates `path` and any missing ancestors (as implicit groups). False for an invalid path.
    @discardableResult
    mutating func ensure(_ path: String, at: Date, declared: Bool, title: String? = nil) -> Bool {
        guard TaskPath.isValid(path) else { return false }
        if declared { declare(at: at) }
        for ancestor in TaskPath.ancestors(path) where tasks[ancestor] == nil {
            insert(Rec(id: ancestor, title: TaskPath.last(ancestor), declared: false, at: at))
        }
        if tasks[path] == nil {
            insert(Rec(id: path, title: title ?? TaskPath.last(path), declared: declared, at: at))
        } else if declared {
            tasks[path]!.declared = true
        }
        return true
    }

    /// The first declaration replaces a mirrored plan.
    mutating func declare(at: Date) {
        guard !declaredAny else { return }
        declaredAny = true
        firstDeclaredAt = at
        for id in order where tasks[id]?.mirrored == true { remove(id) }
        mirrorCount = 0
    }

    mutating func insert(_ r: Rec) {
        tasks[r.id] = r
        order.append(r.id)
        childCount[TaskPath.parent(r.id) ?? "", default: 0] += 1
        if r.mark == .started { startedSet.insert(r.id) }
    }

    mutating func remove(_ id: String) {
        guard let r = tasks[id] else { return }
        if case .waiting(let reason) = r.mark { waitCounts[reason.urgency] -= 1 }
        startedSet.remove(id)
        childCount[TaskPath.parent(id) ?? "", default: 0] -= 1
        tasks[id] = nil
        order.removeAll { $0 == id }
    }

    mutating func setMark(_ id: String, _ m: Mark, at: Date) {
        guard let old = tasks[id]?.mark else { return }
        if case .waiting(let r) = old { waitCounts[r.urgency] -= 1 }
        if old == .started { startedSet.remove(id) }
        if case .waiting(let r) = m { waitCounts[r.urgency] += 1 }
        if m == .started { startedSet.insert(id) }
        tasks[id]!.mark = m
        tasks[id]!.markAt = at
    }

    /// Opens or closes the spans waiting for input and for a limit.
    mutating func noteWaits(at: Date) {
        let input = runWait?.reason == .input || waitCounts[TaskWaitReason.input.urgency] > 0
        let limit = runWait?.reason == .limit || waitCounts[TaskWaitReason.limit.urgency] > 0
        if input, inputOpen == nil { inputOpen = at } else if !input, let s = inputOpen { inputSpans.append(Span(start: s, end: at)); inputOpen = nil }
        if limit, limitOpen == nil { limitOpen = at } else if !limit, let s = limitOpen { limitSpans.append(Span(start: s, end: at)); limitOpen = nil }
    }

    /// Something happened on `path`; `work` when it was work on it (not declaring or closing a
    /// task nobody had started), which counts toward its working time.
    mutating func touch(_ path: String, at: Date, work: Bool = true) {
        if let r = tasks[path] {
            r.lastActivity = max(r.lastActivity, at)
            if work { r.stretches.mark(at, gap: TaskFold.workingGap) }
        }
        touchRun(at)
    }

    /// Started, waiting after a start, or with an agent on it.
    func inWork(_ id: String) -> Bool {
        guard let r = tasks[id] else { return false }
        switch r.mark {
        case .started: return true
        case .waiting: return r.startedAt != nil || !r.attemptKeys.isEmpty
        default: return !r.attemptKeys.isEmpty && r.attemptKeys.contains { attempts[$0]?.attempt.isActive == true }
        }
    }

    mutating func touchRun(_ at: Date) {
        lastActivity = max(lastActivity, at)
        runStretches.mark(at, gap: TaskFold.workingGap)
    }

    /// A terminal op closes the task and every open task beneath it.
    mutating func close(_ path: String, as state: TaskState, at: Date, extra: (inout Rec) -> Void) {
        guard ensure(path, at: at, declared: true) else { return }
        extra(&tasks[path]!)
        let prefix = path + "/"
        for id in order where id == path || id.hasPrefix(prefix) || isPlaced(id, under: path) {
            if id != path, case .terminal = tasks[id]!.mark { continue }
            let working = inWork(id)
            setMark(id, .terminal(state), at: at)
            touch(id, at: at, work: working)
        }
    }

    /// Whether an implicit task sits (through attempt parents) beneath `path`.
    func isPlaced(_ id: String, under path: String) -> Bool {
        var seen: Set<String> = [id]
        var cur = id
        while let p = parent(of: cur), seen.insert(p).inserted {
            if p == path || p.hasPrefix(path + "/") { return true }
            cur = p
        }
        return false
    }

    mutating func upsert(_ spec: TaskEvent.AttemptSpec, at: Date) {
        let tagged = spec.taggedPath
        let title = TaskText.title(spec.title)
        if let existing = attempts[spec.key] {
            var a = existing.attempt
            a.kind = spec.kind
            a.agentType = spec.agentType ?? a.agentType
            a.model = spec.model ?? a.model
            a.provider = spec.provider ?? a.provider
            a.title = title ?? a.title
            a.parentKey = spec.parentKey ?? a.parentKey
            a.lastActivityAt = max(a.lastActivityAt, at)
            var resumed = false
            if let end = a.endedAt, at > end { a.endedAt = nil; a.outcome = nil; resumed = true }
            existing.attempt = a
            if existing.task.isEmpty {
                if a.kind == .session { orchestratorActive(at: at) }
                touchRun(at)
                return
            }
            if let tagged, tagged != existing.task {
                if let dest = bindTarget(tagged, at: at, title: title) {
                    if dest != existing.task {
                        // The tag arrived after the attempt was first seen (a hook fires before the
                        // observer reads the prompt): move it, and drop the implicit task it leaves empty.
                        let old = existing.task
                        tasks[old]?.attemptKeys.removeAll { $0 == spec.key }
                        if let o = tasks[old], o.ownerAttempt == spec.key, o.attemptKeys.isEmpty, !order.contains(where: { parent(of: $0) == old }) { remove(old) }
                        existing.task = dest
                        attach(spec.key, to: dest, at: at)
                        return
                    }
                } else if tasks[existing.task]?.ownerAttempt == spec.key {
                    tasks[existing.task]!.anchor = anchor(forMistyped: tagged)
                }
            }
            // A label arriving later (the observer after a hook) names the agent's own task.
            if let t = title, tasks[existing.task]?.ownerAttempt == spec.key { tasks[existing.task]!.title = t }
            if resumed, reopen(existing.task, at: at) { tasks[existing.task]!.retries += 1 }
            activity(onAttempt: spec.key, at: at)
            return
        }
        if spec.kind == .session {
            // The orchestrator: tracked for activity and tokens, never a task of its own.
            attempts[spec.key] = Att(attempt: TaskAttempt(key: spec.key, kind: .session, agentType: spec.agentType, model: spec.model, provider: spec.provider,
                                                          title: title, parentKey: spec.parentKey, startedAt: at), task: "")
            touchRun(at)
            orchestratorActive(at: at)
            return
        }
        let task: String
        if let tagged, let dest = bindTarget(tagged, at: at, title: title) {
            task = dest
        } else {
            task = TaskPath.implicit(forAttempt: spec.key)
            if tasks[task] == nil {
                let r = Rec(id: task, title: title ?? TaskText.title(spec.agentType) ?? spec.key, declared: false, at: at)
                r.ownerAttempt = spec.key
                if let tagged {
                    r.anchor = anchor(forMistyped: tagged)
                } else if mirrorActive, spec.parentKey.map({ attempts[$0]?.attempt.kind == .session }) ?? true, let only = singleMirrorInProgress() {
                    // Spawned while the orchestrator works on one plan item: helping with it.
                    r.anchor = only
                }
                insert(r)
            }
        }
        attempts[spec.key] = Att(attempt: TaskAttempt(key: spec.key, kind: spec.kind, agentType: spec.agentType, model: spec.model, provider: spec.provider,
                                                      title: title, parentKey: spec.parentKey, startedAt: at), task: task)
        attach(spec.key, to: task, at: at)
    }

    /// The task a tag binds an agent to: one that exists, or (with no plan yet) one it creates.
    /// Nil once there is a plan and the tag names a task it doesn't have.
    mutating func bindTarget(_ tagged: String, at: Date, title: String?) -> String? {
        if tasks[tagged] != nil { return tagged }
        if hasPlan { return nil }
        return ensure(tagged, at: at, declared: false, title: title) ? tagged : nil
    }

    /// Where a helper with a mistyped tag sits: the deepest task of that path the run has.
    func anchor(forMistyped path: String) -> String {
        if let a = TaskPath.ancestors(path).reversed().first(where: { tasks[$0] != nil }) { return a }
        return mirrorActive ? singleMirrorInProgress() ?? "" : ""
    }

    func singleMirrorInProgress() -> String? {
        let ids = startedSet.filter { tasks[$0]?.mirrored == true }
        return ids.count == 1 ? ids.first : nil
    }

    mutating func attach(_ key: String, to task: String, at: Date) {
        // Agents working side by side aren't retries: only one that starts after the others ended is.
        let prior = tasks[task]?.attemptKeys.compactMap { attempts[$0]?.attempt } ?? []
        let afterEnd = !prior.isEmpty && prior.allSatisfy { a in a.endedAt.map { $0 <= at } ?? (at.timeIntervalSince(a.lastActivityAt) > abandonAfter) }
        tasks[task]?.attemptKeys.append(key)
        let restarted = tasks[task]?.restarted ?? false
        tasks[task]?.restarted = false
        let reopened = reopen(task, at: at)
        if tasks[task] != nil {
            if (afterEnd && !restarted) || reopened { tasks[task]!.retries += 1 }
            tasks[task]!.startedAt = tasks[task]!.startedAt ?? at
        }
        activity(onAttempt: key, at: at)
        firstStart = firstStart ?? at
    }

    /// A new attempt after a terminal state reopens the task.
    mutating func reopen(_ task: String, at: Date) -> Bool {
        guard let r = tasks[task], case .terminal = r.mark, at > r.markAt else { return false }
        setMark(task, .started, at: at)
        return true
    }

    /// Activity clears a wait on the attempt's task (past its grace).
    mutating func activity(onAttempt key: String, at: Date) {
        guard let task = attempts[key]?.task, let r = tasks[task] else { touchRun(at); return }
        if case .waiting = r.mark, at > r.waitClearAfter { setMark(task, .started, at: at) }
        touch(task, at: at)
    }

    /// Ends every open agent as cut short.
    mutating func interruptActive(at: Date) {
        for (k, a) in attempts where a.attempt.isActive && !a.task.isEmpty {
            attempts[k]!.attempt.endedAt = at
            attempts[k]!.attempt.outcome = .interrupted
        }
    }

    /// Running tasks the orchestrator is doing itself: leaves with no agent on them.
    func orchestratorTasks() -> [String] {
        guard !startedSet.isEmpty else { return [] }
        return startedSet.filter { id in
            guard let r = tasks[id], r.ownerAttempt == nil, childCount[id, default: 0] == 0 else { return false }
            return r.attemptKeys.allSatisfy { attempts[$0]?.attempt.isActive != true }
        }
    }

    /// Gives the session tokens seen since the last change to the tasks the orchestrator is doing,
    /// split by effort. Done in whole tokens, the remainder to the first task, so splitting a
    /// stretch of activity differently never changes the result.
    mutating func flushSessionTokens() {
        guard pendingSessionTokens > 0 else { return }
        let pool = pendingSessionTokens
        pendingSessionTokens = 0
        let owners = orchestratorTasks().sorted()
        guard !owners.isEmpty else { return }
        let weights = owners.map { max(tasks[$0]!.effort, 0) }
        let total = weights.reduce(0, +)
        var given: Int64 = 0
        var shares = [Int64](repeating: 0, count: owners.count)
        for i in owners.indices {
            // Efforts are any positive number: a share that isn't a count (the weights overflowed) is none.
            shares[i] = total > 0 ? Int64(exactly: (Double(pool) * weights[i] / total).rounded(.down)).map { max(0, min($0, pool)) } ?? 0 : (i == 0 ? pool : 0)
            given += shares[i]
        }
        shares[0] += pool - given
        for (i, id) in owners.enumerated() { tasks[id]!.sessionTokens += shares[i] }
    }

    /// Mirrors the harness's plan list: one task per item, items no longer listed dropped.
    mutating func mirror(_ items: [TaskPlanItem], at: Date) {
        var keep: Set<String> = []
        for (i, item) in items.enumerated() {
            var base = TaskRunID.clean(item.id, limit: 120)
            if base.isEmpty { base = "item-\(i + 1)" }
            var id = TaskFold.planPrefix + base
            var n = 2
            while keep.contains(id) { id = TaskFold.planPrefix + base + "-\(n)"; n += 1 }
            keep.insert(id)
            let title = TaskText.title(item.title) ?? base
            let mark: Mark = switch item.status {
            case .pending: .planned
            case .inProgress: .started
            case .completed: .terminal(.done)
            case .cancelled: .terminal(.cancelled)
            }
            if tasks[id] == nil {
                let r = Rec(id: id, title: title, declared: false, at: at)
                r.mirrored = true
                insert(r)
                mirrorCount += 1
            } else {
                tasks[id]!.title = title
            }
            if tasks[id]!.mark != mark {
                let working = mark == .started || tasks[id]!.mark == .started
                setMark(id, mark, at: at)
                if mark == .started { tasks[id]!.startedAt = tasks[id]!.startedAt ?? at }
                touch(id, at: at, work: working)
            }
        }
        for id in order where tasks[id]?.mirrored == true && !keep.contains(id) {
            remove(id)
            mirrorCount -= 1
        }
        touchRun(at)
    }

    /// A person gave up: every open task is cancelled and every open agent cut short.
    mutating func abandon(reason: String?, at: Date) {
        abandoned = true
        let why = TaskText.note(reason) ?? "Abandoned"
        for id in order {
            let r = tasks[id]!
            let (state, _, _, _) = leafState(r, r.attemptKeys.compactMap { attempts[$0]?.attempt }, gone: false)
            guard !state.isTerminal else { continue }
            setMark(id, .terminal(.cancelled), at: at)
            tasks[id]!.note = why
        }
        interruptActive(at: at)
        runWait = nil
    }

    // MARK: Deriving the tree

    /// The parent of a task: its anchor, its path parent, or for an implicit task the task its
    /// spawning attempt works on (root when unknown, or when that would make a cycle).
    func parent(of id: String) -> String? {
        guard tasks[id] != nil, let target = rawParent(of: id) else { return nil }
        guard tasks[id]!.ownerAttempt != nil || tasks[id]!.anchor != nil else { return target }
        guard tasks[target] != nil else { return nil }
        // Refuse a placement that would put the task beneath itself.
        var seen: Set<String> = [id]
        var cur: String? = target
        while let c = cur {
            guard seen.insert(c).inserted else { return nil }
            cur = rawParent(of: c)
        }
        return target
    }

    func rawParent(of id: String) -> String? {
        guard let r = tasks[id] else { return nil }
        if let a = r.anchor { return a.isEmpty ? nil : a }
        if r.ownerAttempt != nil { return spawnerTask(of: id) }
        return TaskPath.parent(id)
    }

    /// The task the spawning attempt of an implicit task's attempt works on.
    func spawnerTask(of id: String) -> String? {
        tasks[id]?.ownerAttempt.flatMap { attempts[$0]?.attempt.parentKey }.flatMap { attempts[$0]?.task }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// An attempt as of `now`: one silent for longer than `abandonAfter` was cut short.
    func effective(_ a: TaskAttempt, now: Date) -> TaskAttempt {
        guard a.endedAt == nil, now.timeIntervalSince(a.lastActivityAt) > abandonAfter else { return a }
        var b = a
        b.endedAt = a.lastActivityAt
        b.outcome = .interrupted
        return b
    }

    /// The undeclared spawner's own unit of work, beside the agents it spawned.
    struct Own {
        var node: TaskNode
        var working: Double
    }

    struct Calc {
        var node: TaskNode
        var kids: [String] = []
        /// Children that make this node's state and progress.
        var parts: [String] = []
        var own: Own?
        var doneLeaves = 0
        var critical = TaskMustHaves(done: 0, total: 0)
        var spans: [Span] = []
        /// The latest sign of life beneath it, the orchestrator's included for tasks it does itself.
        var liveAt: Date
    }

    struct Derived {
        var root: Calc
        var nodes: [TaskNode]
    }

    func derive(now: Date, staleAfter: TimeInterval, tpu: Double?) -> Derived {
        let gone = endedAt != nil || now.timeIntervalSince(lastActivity) > abandonAfter
        let planned = hasPlan
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in order {
            if let p = parent(of: id), tasks[p] != nil { children[p, default: []].append(id) } else { roots.append(id) }
        }

        // Work from before the first declaration: top-level tasks nobody declared, with nothing
        // declared beneath them.
        var earlier: [String] = []
        if declaredAny, let first = firstDeclaredAt {
            var declaredBelow: Set<String> = []
            for id in order where tasks[id]!.declared { for a in TaskPath.ancestors(id) { declaredBelow.insert(a) } }
            earlier = roots.filter { id in
                let r = tasks[id]!
                return !r.declared && !r.mirrored && !declaredBelow.contains(id) && r.createdAt < first
            }
        }
        let earlierSet = Set(earlier)
        let earlierRec = Rec(id: TaskFold.earlierID, title: TaskFold.earlierTitle, declared: false, at: firstDeclaredAt ?? startedAt)

        var calcs: [String: Calc] = [:]
        var spePerUnit: [Double] = []

        /// Helpers never count once there is a plan, except among the earlier work.
        func isHelper(_ id: String, inEarlier: Bool) -> Bool { planned && !inEarlier && tasks[id]?.ownerAttempt != nil }

        func compute(_ id: String, parent: String?, depth: Int, inEarlier: Bool) -> Calc {
            let synthetic = id == TaskFold.earlierID
            let r = synthetic ? earlierRec : tasks[id]!
            let kids = synthetic ? earlier : (children[id] ?? [])
            let kidsEarlier = inEarlier || synthetic
            let kidCalcs = kids.map { compute($0, parent: id, depth: depth + 1, inEarlier: kidsEarlier) }
            let parts = kidCalcs.filter { !isHelper($0.node.id, inEarlier: kidsEarlier) }
            let atts = r.attemptKeys.compactMap { attempts[$0]?.attempt }.map { effective($0, now: now) }
            let ownTokens = atts.reduce(Int64(0)) { $0 + $1.tokens } + r.sessionTokens
            let tokens = ownTokens + kidCalcs.reduce(Int64(0)) { $0 + $1.node.tokens }
            var lastActive = max(atts.map { max($0.lastActivityAt, $0.endedAt ?? .distantPast) }.max() ?? r.lastActivity, r.lastActivity)
            var liveAt = lastActive
            for k in kidCalcs {
                if let l = k.node.lastActivityAt { lastActive = max(lastActive, l) }
                liveAt = max(liveAt, k.liveAt)
            }
            let spans = Spans.normalized(r.stretches + kidCalcs.flatMap(\.spans))
            let active = atts.filter(\.isActive)
            let summary = TaskAttemptsSummary(count: atts.count, active: active.count, retries: r.retries, last: atts.max { $0.startedAt < $1.startedAt })

            var node = TaskNode(id: id, title: r.title, parent: parent, depth: depth, state: .planned, waitReason: nil, stale: false, progress: .zero,
                                effort: r.effort, importance: r.importance, declared: r.declared, confirmed: true, leaf: parts.isEmpty, counted: true,
                                steps: r.steps, fraction: r.fraction, note: r.note, waitNote: r.waitNote, evidence: r.evidence, failure: r.failure,
                                attempts: summary, tokens: tokens, startedAt: r.startedAt, endedAt: nil, lastActivityAt: lastActive,
                                workingSeconds: Spans.measure(spans))
            var calc = Calc(node: node, kids: kids, parts: parts.map(\.node.id), spans: spans, liveAt: liveAt)
            let lost: Set<TaskState> = [.failed, .cancelled, .partial]
            if parts.isEmpty {
                let (state, reason, confirmed, ended) = leafState(r, atts, gone: gone)
                node.state = state; node.waitReason = reason; node.confirmed = confirmed; node.endedAt = ended
                let replaced = state == .failed && replacement(of: r) != nil
                if replaced { node.replacedBy = r.replacedBy }
                // Skipped and cancelled work was set aside on purpose (the plan changed): it leaves the
                // percent, as a failure an agent worked around does.
                node.counted = !(state == .skipped || (state == .cancelled && r.importance != .critical) || replaced
                                 || (r.importance == .optional && lost.contains(state))) && !isHelper(id, inEarlier: inEarlier)
                if node.counted, state == .done {
                    calc.doneLeaves = 1
                    if node.workingSeconds > 0, r.effort > 0 { spePerUnit.append(node.workingSeconds / r.effort) }
                }
                if r.importance == .critical, state != .skipped, !replaced { calc.critical = TaskMustHaves(done: state == .done ? 1 : 0, total: 1) }
                // A task the orchestrator does itself is as alive as the orchestrator.
                if state == .running, active.isEmpty, let s = lastSessionActivity { calc.liveAt = max(calc.liveAt, s) }
            } else {
                var states = parts.map(\.node)
                var ownDone = 0
                if !planned || inEarlier, r.ownerAttempt != nil, !atts.isEmpty {
                    // An undeclared agent that spawned agents is one unit of work beside them.
                    var own = node
                    let (state, reason, confirmed, ended) = leafState(r, atts, gone: gone)
                    own.state = state; own.waitReason = reason; own.confirmed = confirmed; own.endedAt = ended
                    own.effort = TaskEffort.defaultWeight; own.leaf = true
                    own.counted = state != .skipped
                    own.tokens = ownTokens
                    if own.counted, state == .done { ownDone = 1 }
                    states.append(own)
                    calc.own = Own(node: own, working: Spans.measure(Spans.normalized(r.stretches)))
                }
                let (state, reason) = parentState(states)
                node.state = state; node.waitReason = reason
                if !active.isEmpty, state != .running, state != .waiting { node.state = .running; node.waitReason = nil }
                node.startedAt = ([r.startedAt] + parts.map(\.node.startedAt)).compactMap { $0 }.min()
                if node.state.isTerminal { node.endedAt = states.compactMap(\.endedAt).max() }
                let weighed = states.filter(\.counted)
                let sum = weighed.reduce(0) { $0 + $1.effort }
                node.effort = r.effortSet || sum <= 0 ? r.effort : sum
                node.counted = !weighed.isEmpty && !(r.importance == .optional && lost.contains(node.state))
                calc.doneLeaves = parts.reduce(ownDone) { $0 + $1.doneLeaves }
                calc.critical = parts.reduce(TaskMustHaves(done: 0, total: 0)) { TaskMustHaves(done: $0.done + $1.critical.done, total: $0.total + $1.critical.total) }
            }
            if isHelper(id, inEarlier: inEarlier) { node.counted = false }
            node.stale = node.state == .running && now.timeIntervalSince(calc.liveAt) > staleAfter
            calc.node = node
            calcs[id] = calc
            return calc
        }

        var rootIDs = roots.filter { !earlierSet.contains($0) }
        if !earlier.isEmpty { rootIDs.insert(TaskFold.earlierID, at: 0) }
        let rootCalcs = rootIDs.map { compute($0, parent: nil, depth: 0, inEarlier: false) }
        let spe = TaskFold.median(spePerUnit)

        /// Progress bottom-up, now that the run's own seconds per effort unit are known.
        func progress(_ id: String) -> TaskProgress {
            let c = calcs[id]!
            let kidProgress = Dictionary(uniqueKeysWithValues: c.kids.map { ($0, progress($0)) })
            let p: TaskProgress
            if c.parts.isEmpty {
                let r = id == TaskFold.earlierID ? earlierRec : tasks[id]!
                p = leafProgress(c.node.state, r, confirmed: c.node.confirmed, tokens: c.node.tokens, working: c.node.workingSeconds,
                                 effort: c.node.effort, tpu: tpu, spe: spe)
            } else {
                var items = c.parts.compactMap { k -> (TaskProgress, Double)? in
                    let n = calcs[k]!.node
                    return n.counted ? (kidProgress[k]!, n.effort) : nil
                }
                if var own = c.own, own.node.counted {
                    own.node.progress = leafProgress(own.node.state, tasks[id]!, confirmed: own.node.confirmed, tokens: own.node.tokens,
                                                     working: own.working, effort: own.node.effort, tpu: tpu, spe: spe)
                    calcs[id]!.own = own
                    items.append((own.node.progress, own.node.effort))
                }
                p = weightedMean(items)
            }
            calcs[id]!.node.progress = p
            return p
        }

        /// Shares top-down: each counted node's part of the whole run's weight.
        func assign(_ id: String, _ share: Double) {
            calcs[id]!.node.share = calcs[id]!.node.counted ? share : 0
            let c = calcs[id]!
            let weighed = c.parts.filter { calcs[$0]!.node.counted }
            let total = weighed.reduce(0) { $0 + calcs[$1]!.node.effort } + (c.own.map { $0.node.counted ? $0.node.effort : 0 } ?? 0)
            for k in c.kids {
                assign(k, total > 0 && weighed.contains(k) ? share * calcs[k]!.node.effort / total : 0)
            }
        }

        for c in rootCalcs { _ = progress(c.node.id) }
        let declaredRoots = rootCalcs.filter { !isHelper($0.node.id, inEarlier: false) }
        let top = (declaredRoots.isEmpty ? rootCalcs : declaredRoots).map { calcs[$0.node.id]! }
        let topWeight = top.filter(\.node.counted).reduce(0) { $0 + $1.node.effort }
        let topIDs = Set(top.map(\.node.id))
        for c in rootCalcs {
            let n = calcs[c.node.id]!.node
            assign(n.id, topWeight > 0 && n.counted && topIDs.contains(n.id) ? n.effort / topWeight : 0)
        }

        var root = TaskNode(id: "", title: title ?? id, parent: nil, depth: -1, state: .planned, waitReason: nil, stale: false, progress: .zero,
                            effort: 1, importance: .normal, declared: true, confirmed: true, leaf: top.isEmpty, counted: true, attempts: TaskAttemptsSummary(),
                            tokens: attempts.values.reduce(Int64(0)) { $0 + $1.attempt.tokens }, share: 1,
                            workingSeconds: Spans.measure(Spans.normalized(runStretches)))
        if !top.isEmpty {
            (root.state, root.waitReason) = parentState(top.map(\.node))
            root.progress = weightedMean(top.map(\.node).filter(\.counted).map { ($0.progress, $0.effort) })
        }
        var rootCalc = Calc(node: root, liveAt: lastActivity)
        rootCalc.doneLeaves = top.reduce(0) { $0 + $1.doneLeaves }
        rootCalc.critical = top.reduce(TaskMustHaves(done: 0, total: 0)) { TaskMustHaves(done: $0.done + $1.critical.done, total: $0.total + $1.critical.total) }

        // Display order: depth first, children in the order they appeared.
        var nodes: [TaskNode] = []
        func walk(_ id: String) {
            guard let c = calcs[id] else { return }
            nodes.append(c.node)
            for k in c.kids { walk(k) }
        }
        for r in rootIDs { walk(r) }
        return Derived(root: rootCalc, nodes: nodes)
    }

    func leafState(_ r: Rec, _ atts: [TaskAttempt], gone: Bool) -> (TaskState, TaskWaitReason?, Bool, Date?) {
        if case .terminal(let s) = r.mark { return (s, nil, true, r.markAt) }
        let active = atts.filter(\.isActive)
        if let newest = active.map(\.startedAt).max() {
            if case .waiting(let reason) = r.mark, r.markAt >= newest { return (.waiting, reason, true, nil) }
            return (.running, nil, true, nil)
        }
        if let lastEnd = atts.compactMap(\.endedAt).max() {
            switch r.mark {
            case .waiting(let reason) where r.markAt >= lastEnd: return (.waiting, reason, true, nil)
            case .started where r.markAt > lastEnd: return (gone ? .parked : .running, nil, true, nil)
            default:
                switch atts.max(by: { $0.startedAt < $1.startedAt })?.outcome {
                case .error: return (.failed, nil, false, lastEnd)
                case .interrupted: return (.parked, nil, false, nil)
                default: return (.done, nil, false, lastEnd)
                }
            }
        }
        switch r.mark {
        case .planned: return (.planned, nil, true, nil)
        case .started: return (gone ? .parked : .running, nil, true, nil)
        case .waiting(let reason): return (.waiting, reason, true, nil)
        case .terminal(let s): return (s, nil, true, r.markAt)
        }
    }

    /// The steps or fraction last reported, whichever came later (steps on a tie); a step with no
    /// total known says nothing about how far along.
    func reportedFraction(_ r: Rec) -> Double? {
        let steps = r.steps.flatMap { s in r.stepsAt.map { (at: $0, value: s.fraction) } }
        let frac = r.fraction.flatMap { f in r.fractionAt.map { (at: $0, value: f) } }
        switch (steps, frac) {
        case let (s?, f?): return f.at > s.at ? f.value : s.value
        case let (s?, nil): return s.value
        case let (nil, f?): return f.value
        default: return nil
        }
    }

    func leafProgress(_ state: TaskState, _ r: Rec, confirmed: Bool, tokens: Int64, working: Double, effort: Double,
                      tpu: Double?, spe: Double?) -> TaskProgress {
        switch state {
        case .done:
            // Inferred from an agent ending: the best guess, not closed work.
            return confirmed ? .complete : TaskProgress(done: 0, inFlight: 1, estimate: 1)
        case .running, .waiting, .parked:
            let reported = reportedFraction(r)
            let done = reported ?? 0
            var guess = done
            if reported == nil, effort > 0 {
                if let tpu, tpu > 0, tokens > 0 {
                    guess = min(TaskFold.maxGuess, Double(tokens) / (tpu * effort))
                } else if let spe, spe > 0, working > 0 {
                    guess = min(TaskFold.maxGuess, working / (spe * effort))
                }
            }
            return TaskProgress(done: done, inFlight: state == .parked ? 0 : 1 - done, estimate: max(done, guess))
        default:
            return .zero
        }
    }

    /// Any running child: running. Any waiting: waiting, for the most urgent reason. All finished:
    /// failed when a critical child failed or was cancelled, partial when a normal one did (or a
    /// child ended partial), skipped when all were skipped, else done. Optional children never
    /// block. Otherwise planned if nothing started, parked if some finished or were cut short.
    /// The task that took over from a failed one, while it hasn't failed (or been cancelled) itself.
    func replacement(of r: Rec) -> Rec? {
        guard let id = r.replacedBy, let next = tasks[id] else { return nil }
        if case .terminal(let s) = next.mark, s == .failed || s == .cancelled { return nil }
        return next
    }

    func parentState(_ all: [TaskNode]) -> (TaskState, TaskWaitReason?) {
        // A failure something else took over from reads as set aside, like a skip.
        let kids = all.map { n -> TaskNode in var n = n; if n.replacedBy != nil { n.state = .skipped }; return n }
        if kids.contains(where: { $0.state == .running }) { return (.running, nil) }
        if let reason = kids.filter({ $0.state == .waiting }).compactMap({ $0.waitReason ?? .dependency }).min() { return (.waiting, reason) }
        if kids.allSatisfy(\.state.isTerminal) {
            // A must-have that failed fails it; one dropped when the plan changed leaves it short.
            // Other cancelled work was set aside on purpose, like a skip: no failure.
            if kids.contains(where: { $0.importance == .critical && $0.state == .failed }) { return (.failed, nil) }
            if kids.contains(where: { $0.importance == .critical && $0.state == .cancelled }) { return (.partial, nil) }
            if kids.contains(where: { $0.importance != .optional && ($0.state == .failed || $0.state == .partial) }) { return (.partial, nil) }
            if kids.allSatisfy({ $0.state == .skipped }) { return (.skipped, nil) }
            return (.done, nil)
        }
        if kids.allSatisfy({ $0.state == .planned || $0.state == .skipped }) { return (.planned, nil) }
        return (.parked, nil)
    }

    func weightedMean(_ items: [(TaskProgress, Double)]) -> TaskProgress {
        let total = items.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return .zero }
        func mean(_ f: (TaskProgress) -> Double) -> Double { min(1, max(0, items.reduce(0) { $0 + f($1.0) * $1.1 } / total)) }
        return TaskProgress(done: mean(\.done), inFlight: mean(\.inFlight), estimate: mean(\.estimate))
    }

    // MARK: Result

    func result(now: Date, staleAfter: TimeInterval, tpu: Double?) -> TaskRun {
        let d = derive(now: now, staleAfter: staleAfter, tpu: tpu)
        let root = d.root.node
        let gone = endedAt != nil
        let silent = now.timeIntervalSince(lastActivity) > abandonAfter
        let agents = attempts.values.filter { !$0.task.isEmpty }.map { effective($0.attempt, now: now) }
        let anyActive = agents.contains(where: \.isActive)
        let lastAgentEnd = agents.compactMap(\.endedAt).max() ?? .distantPast
        // The orchestrator isn't working: its turn ended (or the session did) with no agent left, or
        // nothing has happened for `abandonAfter`.
        let quiet = (stoppedAt != nil || gone) && !anyActive || silent
        let mapped: TaskRunState? = switch root.state {
        case .done, .skipped: .done
        case .partial, .cancelled: .partial
        case .failed: .failed
        default: nil
        }
        var state: TaskRunState
        var reason: TaskWaitReason?
        if d.nodes.isEmpty {
            state = stoppedAt != nil || gone || silent ? .stopped : .running
        } else if let mapped {
            // With no plan the agents are the plan, and the orchestrator may spawn more: finished
            // only once its turn ended after the last of them, or the session is over.
            let finished = hasPlan || gone || silent || (stoppedAt.map { $0 >= lastAgentEnd } ?? false)
            state = finished ? mapped : .running
        } else if root.state == .waiting {
            let r = root.waitReason ?? .dependency
            if gone || (silent && r == .dependency) { state = .stopped } else { state = .waiting; reason = r }
        } else {
            state = quiet ? .stopped : .running
        }
        // The orchestrator itself waiting on a person, while work remains.
        if let w = runWait, !state.isTerminal, !gone, !(silent && w.reason == .dependency), state != .waiting || w.reason < (reason ?? .dependency) {
            state = .waiting; reason = w.reason
        }
        // Given up on: never "done", whatever its tasks say.
        if abandoned { state = mapped == nil || mapped == .done ? .partial : mapped!; reason = nil }

        var progress = root.progress
        if state == .done {
            progress = .complete
        } else if !state.isTerminal {
            progress.done = min(progress.done, TaskFold.openCap)
            progress.estimate = min(progress.estimate, TaskFold.openCap)
        }
        let stale = state == .running && now.timeIntervalSince(lastActivity) > staleAfter

        var question: TaskQuestion?
        if state == .waiting, reason == .input {
            if let w = runWait, w.reason == .input {
                question = TaskQuestion(text: w.note ?? "", options: w.options, task: nil, askedAt: w.at)
            } else if let n = d.nodes.first(where: { $0.leaf && $0.state == .waiting && $0.waitReason == .input }), let r = tasks[n.id] {
                question = TaskQuestion(text: r.waitNote ?? "", options: r.waitOptions, task: n.id, askedAt: r.markAt)
            }
        }

        // Where the time went: waiting on a person first, then on a limit, then working, then idle.
        let live = !state.isTerminal && state != .stopped
        let end = live ? max(now, updatedAt) : updatedAt
        let input = Spans.clip(Spans.normalized(inputSpans + (inputOpen.map { [Span(start: $0, end: end)] } ?? [])), from: startedAt, to: end)
        let limit = Spans.clip(Spans.normalized(limitSpans + (limitOpen.map { [Span(start: $0, end: end)] } ?? [])), from: startedAt, to: end)
        let work = Spans.clip(Spans.normalized(runStretches), from: startedAt, to: end)
        let working = Spans.subtract(work, Spans.normalized(input + limit))
        var time = TaskTimeSplit(working: Spans.measure(working), waitingInput: Spans.measure(input),
                                 waitingLimit: Spans.measure(Spans.subtract(limit, input)))
        time.idle = max(0, end.timeIntervalSince(startedAt) - time.working - time.waitingInput - time.waitingLimit)

        var eta: (mid: Double, low: Double, high: Double)?
        if state == .running {
            let closed = d.nodes.filter { $0.leaf && $0.counted && $0.state == .done }.compactMap { n in n.endedAt.map { (at: $0, share: n.share) } }
            eta = forecast(working: working, closed: closed, doneLeaves: d.root.doneLeaves, progress: progress)
        }

        var byModel: [String: Int64] = [:]
        for a in attempts.values where a.attempt.tokens > 0 { byModel[a.attempt.model ?? "unknown", default: 0] += a.attempt.tokens }

        var tokensToFinish: Int64?
        if !state.isTerminal {
            if let tpu, tpu > 0 {
                let left = d.nodes.filter { $0.leaf && $0.counted && !$0.state.isTerminal }.reduce(0.0) { $0 + tpu * $1.effort * (1 - $1.progress.estimate) }
                // No figure when a declared effort puts it past what a count holds.
                tokensToFinish = Int64(exactly: left.rounded())
            } else if progress.estimate >= 0.1, root.tokens > 0 {
                tokensToFinish = Int64(exactly: (Double(root.tokens) * (1 - progress.estimate) / progress.estimate).rounded())
            }
        }

        return TaskRun(id: id, title: title ?? id, project: project, harness: harness, startedAt: startedAt, updatedAt: updatedAt, state: state,
                       waitReason: reason, stale: stale, progress: progress, mustHaves: d.root.critical, etaSeconds: eta?.mid,
                       tokens: root.tokens, scopeChanges: scopeChanges, warning: nil, hasDeclaredTasks: hasPlan, nodes: d.nodes,
                       hidden: hidden, abandoned: abandoned, question: question, time: time, etaLowSeconds: eta?.low, etaHighSeconds: eta?.high,
                       tokensByModel: byModel, recentTokensPerHour: live ? recentRate(working: working, end: end) : nil,
                       tokensToFinish: tokensToFinish, mirrored: mirrorActive, host: host, cwd: cwd,
                       sessionTitle: sessionTitle, repo: repo, branch: branch)
    }

    /// Seconds to finish: what's left of the estimate over the share of the run closed per working
    /// second across the last 45 minutes of working time, falling back to the whole run's rate.
    /// Nothing until two leaves are done or with under a minute of work. The range is wide (half to
    /// double) until five leaves have closed, then narrows, and always spans the other rate's figure.
    func forecast(working: [Span], closed: [(at: Date, share: Double)], doneLeaves: Int, progress: TaskProgress) -> (mid: Double, low: Double, high: Double)? {
        let total = Spans.measure(working)
        guard doneLeaves >= 2, total >= 60 else { return nil }
        // Where each close falls on the working clock.
        var gainedAll = 0.0, gainedRecent = 0.0
        let windowStart = total - TaskFold.forecastWindow
        var i = 0, before = 0.0
        for c in closed.sorted(by: { $0.at < $1.at }) {
            while i < working.count, working[i].end <= c.at { before += working[i].length; i += 1 }
            let pos = before + (i < working.count && working[i].start < c.at ? c.at.timeIntervalSince(working[i].start) : 0)
            gainedAll += c.share
            if pos > windowStart { gainedRecent += c.share }
        }
        let rateAll = gainedAll / total
        let rateRecent = total > TaskFold.forecastWindow ? gainedRecent / TaskFold.forecastWindow : rateAll
        let rate = rateRecent > 0 ? rateRecent : rateAll
        guard rate > 0, rate.isFinite else { return nil }
        let left = max(0, 1 - progress.estimate)
        let mid = left / rate
        let other = rate == rateRecent && rateAll > 0 ? left / rateAll : mid
        let f = doneLeaves < 5 ? 2.0 : max(1.15, 1 + 2.5 / Double(doneLeaves))
        return (mid, min(mid / f, other), max(mid * f, other))
    }

    /// Tokens per hour over the last 30 minutes of working time (looking back at most three hours).
    func recentRate(working: [Span], end: Date) -> Double? {
        let floor = end.addingTimeInterval(-TaskFold.recentLookback)
        var need = TaskFold.recentWindow, got = 0.0
        var from = end
        for s in working.reversed() {
            let start = max(s.start, floor)
            guard s.end > start else { break }
            let len = s.end.timeIntervalSince(start)
            if len >= need { got += need; from = s.end.addingTimeInterval(-need); need = 0; break }
            got += len; need -= len; from = start
        }
        guard got >= 60 else { return nil }
        let tokens = tokenSamples.reduce(Int64(0)) { $0 + ($1.at > from && $1.at <= end ? $1.tokens : 0) }
        return Double(tokens) / (got / 3600)
    }
}
