import Foundation

/// Folds task events into runs: a pure function of the events, the clock, the stale threshold
/// and the token calibration.
///
/// Leaf states, in order of precedence:
/// 1. A declared terminal state (done, failed, skipped, cancelled) wins over liveness. A new
///    attempt, or a `start`, after it reopens the task and counts a retry.
/// 2. Any active attempt makes the leaf `running`, unless a wait declared after that attempt
///    started holds. A wait for `input` is cleared by any later activity on the task or its attempts.
/// 3. With every attempt ended and nothing declared since: the last attempt's `error` gives
///    `failed`, anything else `done`, both flagged unconfirmed.
/// 4. Otherwise the declared mark: planned, running (`start`, `progress`) or waiting.
///
/// Parents are always derived from their children (a terminal op on a parent closes its open
/// descendants instead). An agent nobody tagged gets an implicit `~` task under the task its
/// spawning attempt works on. Once any task is declared such helpers are shown but never count,
/// so they can't dilute a declared plan; in a run with nothing declared they are the plan, and an
/// agent that spawned others counts as one unit beside them (finished agents over spawned agents).
/// A `session` attempt is the orchestrator itself: it adds activity and tokens to the run but no
/// task, so the agents it spawns sit at the top.
public enum TaskFold {
    public static let defaultStaleAfter: TimeInterval = 15 * 60
    /// How far back the forecast looks for the recent rate.
    public static let forecastWindow: TimeInterval = 45 * 60

    /// Every run in `events`, most recently updated first. Events apply in timestamp order, ties in
    /// the order given (pass the journal before the observed file).
    public static func fold(_ events: [TaskEvent], now: Date, staleAfter: TimeInterval = defaultStaleAfter,
                            tokensPerEffortUnit: Double? = nil) -> [TaskRun] {
        var byRun: [String: [TaskEvent]] = [:]
        for e in events { byRun[e.run, default: []].append(e) }
        return byRun.map { run, list in fold(run: run, list, now: now, staleAfter: staleAfter, tokensPerEffortUnit: tokensPerEffortUnit) }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
    }

    /// Folds twice: first to learn tokens per effort unit from the finished leaves, then with it.
    public static func foldCalibrated(_ events: [TaskEvent], now: Date, staleAfter: TimeInterval = defaultStaleAfter) -> [TaskRun] {
        let first = fold(events, now: now, staleAfter: staleAfter)
        guard let tpu = tokensPerEffortUnit(first) else { return first }
        return fold(events, now: now, staleAfter: staleAfter, tokensPerEffortUnit: tpu)
    }

    /// Median of tokens ÷ effort over done leaves that spent tokens.
    public static func tokensPerEffortUnit(_ runs: [TaskRun]) -> Double? {
        let rates = runs.flatMap(\.nodes).filter { $0.leaf && $0.counted && $0.state == .done && $0.tokens > 0 && $0.effort > 0 }
            .map { Double($0.tokens) / $0.effort }.sorted()
        guard !rates.isEmpty else { return nil }
        let mid = rates.count / 2
        return rates.count % 2 == 1 ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2
    }

    static func fold(run: String, _ events: [TaskEvent], now: Date, staleAfter: TimeInterval, tokensPerEffortUnit: Double?) -> TaskRun {
        let ordered = events.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        var b = RunBuilder(id: run, at: ordered.first?.at ?? now)
        // The forecast needs `done` at one moment, the start of its window: sample it on the way past.
        b.windowStart = max(now.addingTimeInterval(-forecastWindow), b.startedAt)
        for e in ordered {
            if b.doneAtWindowStart == nil, e.at > b.windowStart { b.doneAtWindowStart = b.derive(now: e.at, staleAfter: .infinity, tpu: nil).root.node.progress.done }
            b.apply(e)
        }
        return b.result(now: now, staleAfter: staleAfter, tpu: tokensPerEffortUnit)
    }
}

// MARK: - Builder

struct RunBuilder {
    enum Mark: Equatable {
        case planned, started
        case waiting(TaskWaitReason)
        case terminal(TaskState)
    }

    struct Rec {
        var id: String
        var title: String
        var effort = TaskEffort.defaultWeight
        var importance = TaskImportance.normal
        var declared: Bool
        /// Set for the implicit task of an untagged attempt: placed by that attempt's parent.
        var ownerAttempt: String?
        var steps: TaskSteps?
        var fraction: Double?
        var note: String?
        var waitNote: String?
        var evidence: String?
        var failure: String?
        var mark = Mark.planned
        var markAt: Date
        var attemptKeys: [String] = []
        var retries = 0
        var startedAt: Date?
        var lastActivity: Date
    }

    struct Att {
        var attempt: TaskAttempt
        var task: String
    }

    let id: String
    var title: String?
    var project: String?
    var harness: String?
    var startedAt: Date
    var updatedAt: Date
    var tasks: [String: Rec] = [:]
    var order: [String] = []
    var attempts: [String: Att] = [:]
    var stoppedAt: Date?
    var runWait: (reason: TaskWaitReason, at: Date)?
    var firstStart: Date?
    var scopeChanges = 0
    var lastActivity: Date
    var windowStart: Date
    /// `done` just before the first event after `windowStart`; nil while every event is at or before it.
    var doneAtWindowStart: Double?

    init(id: String, at: Date) {
        self.id = id; startedAt = at; updatedAt = at; lastActivity = at; windowStart = at
    }

    // MARK: Applying events

    mutating func apply(_ e: TaskEvent) {
        updatedAt = max(updatedAt, e.at)
        startedAt = min(startedAt, e.at)
        if e.source == .agent || e.source == .user, e.op.task != nil { workResumed(at: e.at) }
        switch e.op {
        case .meta(let t, let p, let h, _, _):
            // Contract: `host` and `cwd` go on the run (engine workstream).
            if let t, !t.isEmpty { title = t }
            if let p, !p.isEmpty { project = p }
            if let h, !h.isEmpty { harness = h }
        case .add(let spec):
            let existed = tasks[spec.id] != nil
            guard ensure(spec.id, at: e.at, declared: true) else { return }
            let effort = spec.effort.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if firstStart != nil, !existed || (effort != nil && effort != tasks[spec.id]?.effort) { scopeChanges += 1 }
            update(spec.id, at: e.at) { r in
                if let t = spec.title, !t.isEmpty { r.title = t }
                if let effort { r.effort = effort }
                if let imp = spec.importance { r.importance = imp }
                if let n = spec.steps, n > 0 { r.steps = TaskSteps(done: min(r.steps?.done ?? 0, n), total: n) }
            }
        case .start(let t):
            guard ensure(t, at: e.at, declared: true) else { return }
            update(t, at: e.at) { r in
                if case .terminal = r.mark { r.retries += 1 }
                r.mark = .started; r.markAt = e.at
                r.startedAt = r.startedAt ?? e.at
            }
            firstStart = firstStart ?? e.at
        case .progress(let t, let step, let total, let fraction, let note):
            guard ensure(t, at: e.at, declared: true) else { return }
            update(t, at: e.at) { r in
                if let total, total > 0 { r.steps = TaskSteps(done: r.steps?.done ?? 0, total: total) }
                if let step, step >= 0 { r.steps = TaskSteps(done: step, total: max(step, r.steps?.total ?? step)) }
                if let fraction, fraction.isFinite { r.fraction = min(1, max(0, fraction)) }
                if let note, !note.isEmpty { r.note = note }
                if r.mark == .planned || r.mark == .waiting(.input) { r.mark = .started; r.markAt = e.at }
                r.startedAt = r.startedAt ?? e.at
            }
            firstStart = firstStart ?? e.at
        case .wait(let t, let key, let reason, let note, _):
            // An unknown agent asking for input still means the run needs a person.
            guard let target = t ?? key.flatMap({ attempts[$0]?.task }).flatMap({ $0.isEmpty ? nil : $0 }) else {
                runWait = (reason, e.at)
                return
            }
            // Only agents and people declare; a hook or the observer waiting on a task doesn't.
            guard ensure(target, at: e.at, declared: e.source == .agent || e.source == .user) else { return }
            update(target, at: e.at) { r in
                if case .terminal = r.mark { return }
                r.mark = .waiting(reason); r.markAt = e.at
                r.waitNote = note
            }
        case .done(let t, let evidence):
            close(t, as: .done, at: e.at) { $0.evidence = evidence ?? $0.evidence }
            firstStart = firstStart ?? e.at
        case .fail(let t, let reason):
            close(t, as: .failed, at: e.at) { $0.failure = reason ?? $0.failure }
            firstStart = firstStart ?? e.at
        case .skip(let t, let reason):
            close(t, as: .skipped, at: e.at) { $0.note = reason ?? $0.note }
        case .cancel(let t, let reason):
            close(t, as: .cancelled, at: e.at) { $0.note = reason ?? $0.note }
        case .attempt(let spec):
            upsert(spec, at: e.at)
        case .activity(let key, let at, let tokens):
            if attempts[key] == nil { upsert(TaskEvent.AttemptSpec(key: key), at: e.at) }
            let when = at ?? e.at
            attempts[key]!.attempt.lastActivityAt = max(attempts[key]!.attempt.lastActivityAt, when)
            if let tokens { attempts[key]!.attempt.tokens = max(attempts[key]!.attempt.tokens, tokens) }
            activity(onAttempt: key, at: when)
        case .attemptEnd(let key, let outcome):
            // An end for an agent never seen starting is one of the harness's own (prompt
            // suggestions, side questions): nothing to show.
            guard attempts[key] != nil else { return }
            attempts[key]!.attempt.endedAt = e.at
            attempts[key]!.attempt.outcome = outcome
            attempts[key]!.attempt.lastActivityAt = max(attempts[key]!.attempt.lastActivityAt, e.at)
            touch(attempts[key]!.task, at: e.at)
        case .stop(let blocked):
            // A Stop hook that sent the agent back to work didn't stop anything.
            if !blocked { stoppedAt = e.at }
        case .resume:
            stoppedAt = nil
            runWait = nil
        case .end:
            stoppedAt = e.at
            runWait = nil
            // Nothing outlives the session: close what is still open.
            for (k, a) in attempts where a.attempt.isActive { attempts[k]!.attempt.endedAt = e.at }
        case .planMirror, .hide, .abandon:
            // Contract only: the engine workstream implements these.
            break
        }
    }

    /// The orchestrator is working again: the run is no longer stopped or waiting on a person.
    mutating func workResumed(at: Date) {
        stoppedAt = nil
        if let w = runWait, w.reason == .input, at > w.at { runWait = nil }
    }

    /// Creates `path` and any missing ancestors (as implicit groups). False for an invalid path.
    @discardableResult
    mutating func ensure(_ path: String, at: Date, declared: Bool, title: String? = nil) -> Bool {
        guard TaskPath.isValid(path) else { return false }
        for ancestor in TaskPath.ancestors(path) where tasks[ancestor] == nil {
            insert(Rec(id: ancestor, title: TaskPath.last(ancestor), declared: false, markAt: at, lastActivity: at))
        }
        if tasks[path] == nil {
            insert(Rec(id: path, title: title ?? TaskPath.last(path), declared: declared, markAt: at, lastActivity: at))
        } else if declared {
            tasks[path]!.declared = true
        }
        return true
    }

    mutating func insert(_ r: Rec) {
        tasks[r.id] = r
        order.append(r.id)
    }

    mutating func update(_ path: String, at: Date, _ change: (inout Rec) -> Void) {
        guard tasks[path] != nil else { return }
        change(&tasks[path]!)
        touch(path, at: at)
    }

    mutating func touch(_ path: String, at: Date) {
        if let last = tasks[path]?.lastActivity { tasks[path]!.lastActivity = max(last, at) }
        lastActivity = max(lastActivity, at)
    }

    /// A terminal op closes the task and every open task beneath it.
    mutating func close(_ path: String, as state: TaskState, at: Date, extra: (inout Rec) -> Void) {
        guard ensure(path, at: at, declared: true) else { return }
        update(path, at: at, extra)
        let prefix = path + "/"
        for id in order where id == path || id.hasPrefix(prefix) || isPlaced(id, under: path) {
            update(id, at: at) { r in
                if case .terminal = r.mark, r.id != path { return }
                r.mark = .terminal(state); r.markAt = at
            }
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
        if var existing = attempts[spec.key] {
            var a = existing.attempt
            a.kind = spec.kind
            a.agentType = spec.agentType ?? a.agentType
            a.model = spec.model ?? a.model
            a.provider = spec.provider ?? a.provider
            a.title = spec.title ?? a.title
            a.parentKey = spec.parentKey ?? a.parentKey
            a.lastActivityAt = max(a.lastActivityAt, at)
            var resumed = false
            if let end = a.endedAt, at > end { a.endedAt = nil; a.outcome = nil; resumed = true }
            existing.attempt = a
            if let tagged, !existing.task.isEmpty, tagged != existing.task, ensure(tagged, at: at, declared: false, title: spec.title) {
                // The tag arrived after the attempt was first seen (a hook fires before the observer
                // reads the prompt): move it, and drop the implicit task it leaves empty.
                let old = existing.task
                tasks[old]?.attemptKeys.removeAll { $0 == spec.key }
                if let o = tasks[old], o.ownerAttempt == spec.key, o.attemptKeys.isEmpty, !order.contains(where: { parent(of: $0) == old }) {
                    tasks[old] = nil
                    order.removeAll { $0 == old }
                }
                existing.task = tagged
                attempts[spec.key] = existing
                attach(spec.key, to: tagged, at: at)
            } else {
                attempts[spec.key] = existing
                // A label arriving later (the observer after a hook) names the agent's own task.
                if let t = spec.title, !t.isEmpty, tasks[existing.task]?.ownerAttempt == spec.key { tasks[existing.task]?.title = t }
                if resumed { reopen(existing.task, at: at) }
                activity(onAttempt: spec.key, at: at)
            }
            if spec.kind == .session { workResumed(at: at) }
            return
        }
        if spec.kind == .session {
            // The orchestrator: tracked for activity and tokens, never a task of its own.
            attempts[spec.key] = Att(attempt: TaskAttempt(key: spec.key, kind: .session, agentType: spec.agentType, model: spec.model, provider: spec.provider,
                                                          title: spec.title, parentKey: spec.parentKey, startedAt: at), task: "")
            touch("", at: at)
            workResumed(at: at)
            return
        }
        let task: String
        if let tagged, ensure(tagged, at: at, declared: false, title: spec.title) {
            task = tagged
        } else {
            task = TaskPath.implicit(forAttempt: spec.key)
            if tasks[task] == nil {
                var r = Rec(id: task, title: spec.title ?? spec.agentType ?? spec.key, declared: false, markAt: at, lastActivity: at)
                r.ownerAttempt = spec.key
                insert(r)
            }
        }
        attempts[spec.key] = Att(attempt: TaskAttempt(key: spec.key, kind: spec.kind, agentType: spec.agentType, model: spec.model, provider: spec.provider,
                                                      title: spec.title, parentKey: spec.parentKey, startedAt: at), task: task)
        attach(spec.key, to: task, at: at)
        if spec.kind == .session { workResumed(at: at) }
    }

    mutating func attach(_ key: String, to task: String, at: Date) {
        let hadAttempts = !(tasks[task]?.attemptKeys.isEmpty ?? true)
        tasks[task]?.attemptKeys.append(key)
        if hadAttempts { tasks[task]?.retries += 1 }
        reopen(task, at: at, counted: hadAttempts)
        update(task, at: at) { r in r.startedAt = r.startedAt ?? at }
        activity(onAttempt: key, at: at)
        firstStart = firstStart ?? at
    }

    /// A new attempt after a terminal state reopens the task.
    mutating func reopen(_ task: String, at: Date, counted: Bool = false) {
        guard let r = tasks[task], case .terminal = r.mark, at > r.markAt else { return }
        tasks[task]!.mark = .started
        tasks[task]!.markAt = at
        if !counted { tasks[task]!.retries += 1 }
    }

    /// Activity clears a wait for input on the attempt's task.
    mutating func activity(onAttempt key: String, at: Date) {
        guard let task = attempts[key]?.task else { return }
        if let r = tasks[task], r.mark == .waiting(.input), at > r.markAt {
            tasks[task]!.mark = .started
            tasks[task]!.markAt = at
        }
        touch(task, at: at)
    }

    // MARK: Deriving the tree

    /// The parent of a task: its path parent, or for an implicit task the task its spawning
    /// attempt works on (root when unknown, or when that would make a cycle).
    func parent(of id: String) -> String? {
        guard let r = tasks[id] else { return nil }
        guard r.ownerAttempt != nil else { return TaskPath.parent(id) }
        guard let target = spawnerTask(of: id), tasks[target] != nil else { return nil }
        // Refuse a placement that would put the task beneath itself.
        var seen: Set<String> = [id]
        var cur: String? = target
        while let c = cur {
            guard seen.insert(c).inserted else { return nil }
            cur = tasks[c]?.ownerAttempt != nil ? spawnerTask(of: c) : TaskPath.parent(c)
        }
        return target
    }

    /// The task the spawning attempt of an implicit task's attempt works on.
    func spawnerTask(of id: String) -> String? {
        tasks[id]?.ownerAttempt.flatMap { attempts[$0]?.attempt.parentKey }.flatMap { attempts[$0]?.task }
    }

    struct Calc {
        var node: TaskNode
        var doneLeaves = 0
        var critical = TaskMustHaves(done: 0, total: 0)
    }

    struct Derived {
        var root: Calc
        var nodes: [TaskNode]
    }

    func derive(now: Date, staleAfter: TimeInterval, tpu: Double?) -> Derived {
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in order {
            if let p = parent(of: id), tasks[p] != nil { children[p, default: []].append(id) } else { roots.append(id) }
        }
        var calcs: [String: Calc] = [:]

        /// Implicit tasks of untagged agents, once anything is declared: shown, but they never make
        /// a parent's state or progress, and at the top only count when nothing else is there.
        let undeclared = !hasDeclaredTasks
        func isHelper(_ id: String) -> Bool { !undeclared && tasks[id]?.ownerAttempt != nil }

        func compute(_ id: String, depth: Int) -> Calc {
            let r = tasks[id]!
            let kids = children[id] ?? []
            let kidCalcs = kids.map { compute($0, depth: depth + 1) }
            let counted = kidCalcs.filter { !isHelper($0.node.id) }
            let atts = r.attemptKeys.compactMap { attempts[$0]?.attempt }
            let ownTokens = atts.reduce(Int64(0)) { $0 + $1.tokens }
            let allTokens = ownTokens + kidCalcs.reduce(Int64(0)) { $0 + $1.node.tokens }
            var lastActive = atts.map { max($0.lastActivityAt, $0.endedAt ?? .distantPast) }.max() ?? r.lastActivity
            lastActive = max(lastActive, r.lastActivity)
            for k in kidCalcs { if let l = k.node.lastActivityAt { lastActive = max(lastActive, l) } }
            let last = atts.max { $0.startedAt < $1.startedAt }
            let summary = TaskAttemptsSummary(count: atts.count, active: atts.filter(\.isActive).count, retries: r.retries, last: last)

            var node = TaskNode(id: id, title: r.title, parent: parent(of: id).flatMap { tasks[$0] != nil ? $0 : nil }, depth: depth,
                                state: .planned, waitReason: nil, stale: false, progress: .zero, effort: r.effort, importance: r.importance,
                                declared: r.declared, confirmed: true, leaf: counted.isEmpty, counted: true, steps: r.steps, fraction: r.fraction,
                                note: r.note, waitNote: r.waitNote, evidence: r.evidence, failure: r.failure, attempts: summary, tokens: allTokens,
                                startedAt: r.startedAt, endedAt: nil, lastActivityAt: lastActive)
            var calc = Calc(node: node)
            if counted.isEmpty {
                let (state, reason, confirmed, ended) = leafState(r, atts)
                node.state = state; node.waitReason = reason; node.confirmed = confirmed; node.endedAt = ended
                node.counted = !(state == .skipped || (r.importance == .optional && (state == .failed || state == .cancelled)))
                node.progress = leafProgress(state: state, r: r, tokens: allTokens, tpu: tpu)
                if node.counted, state == .done { calc.doneLeaves = 1 }
                if r.importance == .critical, state != .skipped { calc.critical = TaskMustHaves(done: state == .done ? 1 : 0, total: 1) }
            } else {
                var parts = counted.map(\.node)
                var ownDone = 0
                if undeclared, r.ownerAttempt != nil, !atts.isEmpty {
                    // An undeclared agent that spawned agents is one unit of work beside them.
                    var own = node
                    let (state, reason, confirmed, ended) = leafState(r, atts)
                    own.state = state; own.waitReason = reason; own.confirmed = confirmed; own.endedAt = ended
                    own.progress = leafProgress(state: state, r: r, tokens: ownTokens, tpu: tpu)
                    if state == .done { ownDone = 1 }
                    parts.append(own)
                }
                let (state, reason) = parentState(parts)
                node.state = state; node.waitReason = reason
                if atts.contains(where: \.isActive), state != .running, state != .waiting { node.state = .running; node.waitReason = nil }
                node.startedAt = ([r.startedAt] + counted.map(\.node.startedAt)).compactMap { $0 }.min()
                if node.state.isTerminal { node.endedAt = parts.compactMap(\.endedAt).max() }
                let weighed = parts.filter(\.counted)
                node.counted = !weighed.isEmpty && !(r.importance == .optional && (node.state == .failed || node.state == .cancelled))
                node.progress = weightedMean(weighed)
                calc.doneLeaves = counted.reduce(ownDone) { $0 + $1.doneLeaves }
                calc.critical = counted.reduce(TaskMustHaves(done: 0, total: 0)) { TaskMustHaves(done: $0.done + $1.critical.done, total: $0.total + $1.critical.total) }
            }
            node.stale = node.state == .running && now.timeIntervalSince(lastActive) > staleAfter
            calc.node = node
            calcs[id] = calc
            return calc
        }

        let rootCalcs = roots.map { compute($0, depth: 0) }
        let declaredRoots = rootCalcs.filter { !isHelper($0.node.id) }
        // Helpers at the top only count when nothing was declared.
        let top = declaredRoots.isEmpty ? rootCalcs : declaredRoots
        if declaredRoots.isEmpty == false {
            for c in rootCalcs where isHelper(c.node.id) { calcs[c.node.id]?.node.counted = false }
        }
        var root = TaskNode(id: "", title: title ?? id, parent: nil, depth: -1, state: .planned, waitReason: nil, stale: false, progress: .zero,
                            effort: 1, importance: .normal, declared: true, confirmed: true, leaf: top.isEmpty, counted: true, attempts: TaskAttemptsSummary(),
                            tokens: attempts.values.reduce(Int64(0)) { $0 + $1.attempt.tokens })
        if !top.isEmpty {
            (root.state, root.waitReason) = parentState(top.map(\.node))
            root.progress = weightedMean(top.map(\.node).filter(\.counted))
        }
        var rootCalc = Calc(node: root)
        rootCalc.doneLeaves = top.reduce(0) { $0 + $1.doneLeaves }
        rootCalc.critical = top.reduce(TaskMustHaves(done: 0, total: 0)) { TaskMustHaves(done: $0.done + $1.critical.done, total: $0.total + $1.critical.total) }

        // Display order: depth first, children in the order they appeared.
        var nodes: [TaskNode] = []
        func walk(_ id: String) {
            guard let c = calcs[id] else { return }
            var n = c.node
            if n.parent != nil, isHelper(id) { n.counted = false }
            nodes.append(n)
            for k in children[id] ?? [] { walk(k) }
        }
        for r in roots { walk(r) }
        return Derived(root: rootCalc, nodes: nodes)
    }

    func leafState(_ r: Rec, _ atts: [TaskAttempt]) -> (TaskState, TaskWaitReason?, Bool, Date?) {
        if case .terminal(let s) = r.mark { return (s, nil, true, r.markAt) }
        let active = atts.filter(\.isActive)
        if let newest = active.map(\.startedAt).max() {
            if case .waiting(let reason) = r.mark, r.markAt >= newest { return (.waiting, reason, true, nil) }
            return (.running, nil, true, nil)
        }
        if let lastEnd = atts.compactMap(\.endedAt).max() {
            switch r.mark {
            case .waiting(let reason) where r.markAt >= lastEnd: return (.waiting, reason, true, nil)
            case .started where r.markAt > lastEnd: return (.running, nil, true, nil)
            default:
                let last = atts.max { $0.startedAt < $1.startedAt }
                return (last?.outcome == .error ? .failed : .done, nil, false, lastEnd)
            }
        }
        switch r.mark {
        case .planned: return (.planned, nil, true, nil)
        case .started: return (.running, nil, true, nil)
        case .waiting(let reason): return (.waiting, reason, true, nil)
        case .terminal(let s): return (s, nil, true, r.markAt)
        }
    }

    func leafProgress(state: TaskState, r: Rec, tokens: Int64, tpu: Double?) -> TaskProgress {
        switch state {
        case .done: return .complete
        case .running, .waiting:
            let done = r.steps.map(\.fraction) ?? r.fraction ?? 0
            var estimate = done
            if let tpu, tpu > 0, r.effort > 0 { estimate = max(done, min(0.9, Double(tokens) / (tpu * r.effort))) }
            return TaskProgress(done: done, inFlight: 1 - done, estimate: estimate)
        default: return .zero
        }
    }

    /// Any running child: running. Any waiting: waiting, for the most urgent reason. All finished:
    /// failed when a critical child failed or was cancelled, partial when a normal one did (or a
    /// child ended partial), skipped when all were skipped, else done. Optional children never
    /// block. Otherwise planned if nothing started, parked if some finished.
    func parentState(_ kids: [TaskNode]) -> (TaskState, TaskWaitReason?) {
        if kids.contains(where: { $0.state == .running }) { return (.running, nil) }
        if let reason = kids.filter({ $0.state == .waiting }).compactMap({ $0.waitReason ?? .dependency }).min() { return (.waiting, reason) }
        if kids.allSatisfy(\.state.isTerminal) {
            let lost: Set<TaskState> = [.failed, .cancelled]
            if kids.contains(where: { $0.importance == .critical && lost.contains($0.state) }) { return (.failed, nil) }
            if kids.contains(where: { $0.importance != .optional && (lost.contains($0.state) || $0.state == .partial) }) { return (.partial, nil) }
            if kids.allSatisfy({ $0.state == .skipped }) { return (.skipped, nil) }
            return (.done, nil)
        }
        if kids.allSatisfy({ $0.state == .planned || $0.state == .skipped }) { return (.planned, nil) }
        return (.parked, nil)
    }

    func weightedMean(_ nodes: [TaskNode]) -> TaskProgress {
        let total = nodes.reduce(0) { $0 + $1.effort }
        guard total > 0 else { return .zero }
        func mean(_ f: (TaskProgress) -> Double) -> Double { min(1, max(0, nodes.reduce(0) { $0 + f($1.progress) * $1.effort } / total)) }
        return TaskProgress(done: mean(\.done), inFlight: mean(\.inFlight), estimate: mean(\.estimate))
    }

    /// An agent or a person declared at least one task.
    var hasDeclaredTasks: Bool { tasks.values.contains(where: \.declared) }

    // MARK: Result

    func result(now: Date, staleAfter: TimeInterval, tpu: Double?) -> TaskRun {
        let d = derive(now: now, staleAfter: staleAfter, tpu: tpu)
        let root = d.root.node
        let anyActive = attempts.values.contains { $0.attempt.isActive }
        var state: TaskRunState
        var reason: TaskWaitReason?
        if d.nodes.isEmpty {
            state = stoppedAt != nil ? .stopped : .running
        } else {
            switch root.state {
            case .running: state = stoppedAt != nil && !anyActive ? .stopped : .running
            case .waiting: state = .waiting; reason = root.waitReason
            case .planned, .parked: state = stoppedAt != nil && !anyActive ? .stopped : .running
            case .done, .skipped: state = .done
            case .partial, .cancelled: state = .partial
            case .failed: state = .failed
            }
        }
        // The orchestrator itself waiting on a person, while work remains.
        if let w = runWait, !state.isTerminal, state != .waiting || w.reason < (reason ?? .dependency) {
            state = .waiting; reason = w.reason
        }
        let stale = state == .running && now.timeIntervalSince(lastActivity) > staleAfter
        return TaskRun(id: id, title: title ?? id, project: project, harness: harness, startedAt: startedAt, updatedAt: updatedAt, state: state,
                       waitReason: reason, stale: stale, progress: root.progress, mustHaves: d.root.critical,
                       etaSeconds: state.isTerminal ? nil : forecast(now: now, doneLeaves: d.root.doneLeaves, progress: root.progress),
                       tokens: root.tokens, scopeChanges: scopeChanges, warning: nil, hasDeclaredTasks: hasDeclaredTasks, nodes: d.nodes)
    }

    /// Seconds to finish: what's left of the estimate over the gain in `done` across the last
    /// 45 minutes (or since the start, if sooner), falling back to the whole-run rate. Nothing
    /// in the first minute: a plan marked off in one burst would forecast seconds.
    func forecast(now: Date, doneLeaves: Int, progress: TaskProgress) -> Double? {
        guard doneLeaves >= 2, now.timeIntervalSince(startedAt) >= 60 else { return nil }
        let from = windowStart
        var rate = 0.0
        if now > from { rate = (progress.done - (doneAtWindowStart ?? progress.done)) / now.timeIntervalSince(from) }
        if !(rate > 0), now > startedAt { rate = progress.done / now.timeIntervalSince(startedAt) }
        guard rate > 0, rate.isFinite else { return nil }
        return max(0, (1 - progress.estimate) / rate)
    }
}
