import Darwin
import Foundation
import HeadroomKit

/// Reads harness transcripts for task tracking and appends what it sees to
/// `tasks/observed/<run>.jsonl` (source `harness`). It costs the agents nothing and works when
/// they report nothing.
///
/// Claude Code: `<project>/<session>.jsonl`, its agents in `<session>/subagents/agent-<id>.jsonl`
/// beside `agent-<id>.meta.json`, workflow agents in `subagents/workflows/<runId>/`. Codex:
/// `rollout-*.jsonl`. Only the paths handed over are read, from a saved byte offset.
///
/// A session becomes a run only once it spawns something (Agent, a T3 Code delegate, a Workflow)
/// or the agent has declared tasks in it (a journal file exists). An attempt tagged
/// `[hr:RUN:PATH]` lands in RUN. A delegate's child session, found by its first message
/// matching the brief, works for the delegate: its activity, tokens and end are the delegate's,
/// its agents hang under it, and it is no run of its own.
///
/// Ends: an agent ends on its tool result when it ran in the foreground, on the harness's
/// `<task-notification>` when in the background, on its transcript's final `end_turn`, or when
/// its meta file says `finished`. A workflow agent ends when it calls `StructuredOutput`, a
/// workflow on its notification or its `workflows/<runId>.json`. A delegate ends on T3 Code's
/// "Delegated task … [status]:" message to the parent, a `task_status` result, or its child's turn
/// ending (Codex `task_complete`, `turn_aborted` as an error; Claude Code `end_turn`). An
/// orchestrator's `end_turn` is `run.stop`; its next reply is `run.resume`.
///
/// Nothing anyone typed, no tool input or output and no path is written: only labels agents
/// wrote (descriptions, delegate titles), agent types, models and the project directory's name.
public actor TaskObserver {
    public struct Report: Sendable {
        public var filesRead = 0
        public var bytes: Int64 = 0
        public var events = 0
        public init() {}
    }

    /// Counts over what has been written, for `tasks-scan`.
    public struct Summary: Sendable {
        public var runs = 0
        public var attempts: [TaskAttemptKind: Int] = [:]
        public var delegates = 0
        public var delegatesBound = 0
        public var tagged = 0
    }

    public static let activityInterval: TimeInterval = 30
    /// How far back a first start looks.
    public static let firstLook: TimeInterval = 86400
    static let keep: TimeInterval = 7 * 86400

    public let roots: LogRoots
    public let home: URL
    /// Each root as given and as `realpath` has it: enumerators and FSEvents report `/private/var`
    /// for `/var`.
    private let claudeRoots: [String]
    private let codexRoots: [String]
    /// Root as given → its real path, so a file has one key whichever way it's named.
    private let aliases: [(String, String)]
    private let now: @Sendable () -> Date
    private var state: ObserverState
    private var changed = false
    private var savedAt: Double = 0
    /// The state is written at most this often; `flush()` writes it now.
    static let saveInterval: TimeInterval = 30
    /// Attempts and sessions with throttled activity still to write.
    private var pending: Set<String> = []
    private var touchedAttempts: Set<String> = []
    private var touchedSessions: Set<String> = []

    public init(roots: LogRoots = .standard(), home: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.roots = roots
        self.home = home
        let aliases = (roots.claude + roots.codex).compactMap { u -> (String, String)? in
            guard let r = realpath(u.path, nil) else { return nil }
            defer { free(r) }
            let real = String(cString: r)
            return real == u.path ? nil : (u.path, real)
        }
        func forms(_ urls: [URL]) -> [String] { urls.flatMap { u in [u.path] + aliases.filter { $0.0 == u.path }.map(\.1) } }
        self.aliases = aliases
        claudeRoots = forms(roots.claude)
        codexRoots = forms(roots.codex)
        self.now = now
        let loaded = (try? Data(contentsOf: Self.stateURL(home: home))).flatMap { try? PropertyListDecoder().decode(ObserverState.self, from: $0) }
        state = loaded?.version == ObserverState.currentVersion ? loaded! : ObserverState()
    }

    public static func stateURL(home: URL) -> URL { TaskJournal.directory(home: home).appendingPathComponent("observer.plist") }

    /// Whether the observer has never saved: the first start looks back only `firstLook`.
    public var isFresh: Bool { state.files.isEmpty }

    // MARK: Entry points

    /// Every transcript under the roots modified since `since` (and any known one that grew).
    public func scan(since: Date) -> Report {
        var paths: [String] = []
        let cutoff = since.timeIntervalSince1970
        for root in roots.claude + roots.codex {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    // Tool output and worktrees hold no transcripts.
                    if url.lastPathComponent == "tool-results" || url.lastPathComponent == "scripts" { e.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "jsonl" else { continue }
                let m = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                if m >= cutoff || (state.files[url.path].map { m > $0.mtime } ?? false) { paths.append(url.path) }
            }
        }
        return ingest(paths: paths)
    }

    /// Reads what's new in `paths` (from FSEvents), then writes the events that follow.
    public func ingest(paths: [String]) -> Report {
        var report = Report()
        // Main transcripts first, so spawns are known before the agents they made.
        func rank(_ r: TranscriptFile.Role) -> Int { r == .agent || r == .workflowAgent ? 1 : 0 }
        var work: [(path: String, role: TranscriptFile.Role)] = []
        for p in Set(paths.map(canonical)) { if let r = classify(p) { work.append((p, r)) } }
        work.sort { (rank($0.role), $0.path) < (rank($1.role), $1.path) }
        for (path, role) in work { read(path, as: role, into: &report) }
        refreshMetas(sessions: touchedSessions.union(touchedAttempts.compactMap { state.attempts[$0]?.session }))
        bind()
        report.events = publish()
        save()
        return report
    }

    /// The slow timer: re-reads meta files of unfinished agents and workflow results, and writes
    /// throttled activity that is due. Only needed while `needsPolling`.
    public func poll() -> Report {
        refreshMetas(sessions: nil)
        touchedAttempts.formUnion(pending.filter { state.attempts[$0] != nil })
        touchedSessions.formUnion(pending.filter { state.sessions[$0] != nil })
        var report = Report()
        report.events = publish()
        save()
        return report
    }

    /// Something unfinished whose end only a file the watcher doesn't report (or the throttle) will show.
    public var needsPolling: Bool {
        let recent = now().timeIntervalSince1970 - 6 * 3600
        if !pending.isEmpty { return true }
        return state.attempts.values.contains { a in
            a.lastAt > recent && (a.meta != nil || a.kind == .workflow) && effective(a).end == nil
        }
    }

    /// Sessions that work for a delegate: not runs of their own.
    public var boundChildren: Set<String> { Set(state.sessions.values.filter { $0.boundTo != nil }.map(\.id)) }

    public func summary() -> Summary {
        var s = Summary()
        var runs: Set<String> = []
        for a in state.attempts.values {
            guard let run = a.out.run else { continue }
            runs.insert(run)
            s.attempts[a.kind, default: 0] += 1
            if a.kind == .delegate { s.delegates += 1; if a.child != nil { s.delegatesBound += 1 } }
            if liveTag(a) != nil { s.tagged += 1 }
        }
        for sess in state.sessions.values where sess.out.run != nil && sess.boundTo == nil {
            runs.insert(sess.id)
            s.attempts[.session, default: 0] += 1
        }
        s.runs = runs.count
        return s
    }

    // MARK: Reading files

    func canonical(_ path: String) -> String {
        for (given, real) in aliases where path.hasPrefix(given + "/") { return real + path.dropFirst(given.count) }
        return path
    }

    func classify(_ path: String) -> TranscriptFile.Role? {
        guard path.hasSuffix(".jsonl") else { return nil }
        if codexRoots.contains(where: { path.hasPrefix($0 + "/") }) {
            return (path as NSString).lastPathComponent.hasPrefix("rollout-") ? .codex : nil
        }
        guard let root = claudeRoots.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        switch parts.count {
        case 2: return .session
        case 4 where parts[2] == "subagents" && parts[3].hasPrefix("agent-"): return .agent
        case 6 where parts[2] == "subagents" && parts[3] == "workflows" && parts[5].hasPrefix("agent-"): return .workflowAgent
        default: return nil
        }
    }

    /// The session id, agent key and workflow run a Claude path names.
    func names(_ path: String, _ role: TranscriptFile.Role) -> (session: String, agent: String?, workflow: String?)? {
        guard let root = claudeRoots.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        func stem(_ s: String) -> String { String(s.dropLast(6)) }
        let session: String
        var agent: String?, workflow: String?
        switch role {
        case .session: session = stem(parts[1])
        case .agent: session = parts[1]; agent = "agent:" + stem(parts[3]).dropFirst(6)
        case .workflowAgent: session = parts[1]; workflow = parts[4]; agent = "agent:" + stem(parts[5]).dropFirst(6)
        case .codex: return nil
        }
        guard TaskRunID.sanitize(session) == session else { return nil }
        return (session, agent, workflow)
    }

    private func read(_ path: String, as role: TranscriptFile.Role, into report: inout Report) {
        guard let st = LogFileReader.fileStat(path) else { return }
        let isNew = state.files[path] == nil
        var file = state.files[path] ?? TranscriptFile(role: role)
        if file.inode != st.inode || file.offset > st.size {
            file = TranscriptFile(role: role)
            file.inode = st.inode
        }
        var sessionDir: String?
        if role != .codex {
            guard let n = names(path, role) else { return }
            file.session = n.session
            file.agent = n.agent
            sessionDir = role == .session ? String(path.dropLast(6)) : nil
            if state.sessions[n.session] == nil {
                // Agents can be read before their session's own file; the directory is the same either way.
                let dir = role == .session ? String(path.dropLast(6)) : path.components(separatedBy: "/subagents/").first
                state.sessions[n.session] = SessionRec(id: n.session, harness: "claude-code", dir: dir, startedAt: st.mtime, lastAt: 0)
                changed = true
            }
            if let key = n.agent, isNew {
                if state.attempts[key] == nil {
                    let spawner = n.workflow.map { "workflow:" + $0 } ?? "session:" + n.session
                    state.attempts[key] = AttemptRec(key: key, kind: .agent, session: n.session, spawner: spawner, provider: "claude",
                                                     startedAt: st.mtime, lastAt: 0)
                }
                state.attempts[key]?.meta = String(path.dropLast(6)) + ".meta.json"
                touch(key)
                changed = true
            }
        }
        if let dir = sessionDir, let s = file.session { state.sessions[s]?.dir = dir }
        // The meta file's `finished` is read after the lines, so the end lands on the last of them.
        defer { if isNew, let key = file.agent { readMeta(key) } }
        guard st.size > file.offset else {
            file.mtime = st.mtime
            state.files[path] = file
            return
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let length = Int(st.size)
        guard let map = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else { return }
        defer { munmap(map, length) }
        let base = UnsafePointer<UInt8>(map.assumingMemoryBound(to: UInt8.self))
        var end = length
        while end > Int(file.offset) && base[end - 1] != 0x0A { end -= 1 }
        var pos = Int(file.offset)
        while pos < end {
            var lineEnd = end
            if let nl = memchr(base + pos, 0x0A, end - pos) { lineEnd = UnsafePointer<UInt8>(nl.assumingMemoryBound(to: UInt8.self)) - base }
            if lineEnd > pos {
                if role == .codex { codexLine(base + pos, lineEnd - pos, file: &file) } else { claudeLine(base + pos, lineEnd - pos, file: &file) }
            }
            pos = lineEnd + 1
        }
        report.filesRead += 1
        report.bytes += Int64(end) - file.offset
        file.offset = Int64(end)
        file.mtime = st.mtime
        state.files[path] = file
        changed = true
    }

    // MARK: Claude Code lines

    private func claudeLine(_ p: UnsafePointer<UInt8>, _ n: Int, file: inout TranscriptFile) {
        guard let sid = file.session else { return }
        let spawns = state.spawns
        let wanted: (String) -> (tracked: Bool, text: Bool) = { id in
            guard let s = spawns[id] else { return (false, false) }
            return (true, s.tool == .delegate || s.tool == .taskStatus)
        }
        let wantText = file.role == .session && !file.sawText
        guard let line = ClaudeTranscript.parse(p, n, wanted: wanted, wantText: wantText) else { return }
        let owner = file.agent ?? "session:" + sid
        let at = line.at ?? 0
        if line.assistant { file.sawText = true }
        if let text = line.text, wantText {
            file.sawText = true
            let c = Fingerprint.candidates(text)
            if !c.isEmpty, state.sessions[sid]?.boundTo == nil { state.sessions[sid]?.candidates = c }
        }
        // Activity and tokens, each message's usage once.
        var tokens = line.tokens
        if let key = line.messageKey.map({ Fingerprint.hash(Array($0.utf8)[...]) }) {
            if file.recentKeys.contains(key) { tokens = 0 } else {
                file.recentKeys.append(key)
                if file.recentKeys.count > 8 { file.recentKeys.removeFirst(file.recentKeys.count - 8) }
            }
        }
        if let agent = file.agent {
            if var a = state.attempts[agent] {
                if at > 0 {
                    if a.out.run == nil { a.startedAt = min(a.startedAt, at) }
                    a.lastAt = max(a.lastAt, at)
                }
                a.tokens += tokens
                if line.model != nil, a.model == nil { a.model = line.model }
                // A subagent's turn ends once, with its answer; a workflow agent hands its result back.
                if line.endTurn || line.returnsOutput, at > 0, at > (a.endedAt ?? 0) { a.endedAt = at; a.outcome = .ok }
                state.attempts[agent] = a
                touch(agent)
            }
        } else if var s = state.sessions[sid] {
            // After its turn ended, only a reply of its own counts as activity.
            if at > 0, line.assistant || s.stoppedAt == nil {
                s.startedAt = s.lastAt == 0 ? at : min(s.startedAt, at)
                s.lastAt = max(s.lastAt, at)
            }
            if s.project == nil, let cwd = line.cwd { s.project = Bytes.lastPathComponent(cwd) }
            s.tokens += tokens
            if let m = line.model, line.assistant { s.model = m }
            if line.assistant {
                if s.stoppedAt != nil, line.messageKey != s.stopKey { s.stoppedAt = nil; s.stopKey = nil }
                if line.endTurn, at > 0 { s.stoppedAt = at; s.stopKey = line.messageKey }
            }
            state.sessions[sid] = s
            touchSession(sid)
        }
        for sp in line.spawns { spawned(sp, by: owner, session: sid, at: at) }
        for r in line.results { result(r, meta: line.resultMeta, at: at) }
        if let notice = line.notice, let sp = state.spawns[notice.toolUseID] {
            let outcome: TaskAttemptOutcome = notice.status == "completed" ? .ok : .error
            if let key = sp.attempt { end(key, at: at, outcome) } else {
                state.spawns[notice.toolUseID]?.endedAt = at
                state.spawns[notice.toolUseID]?.outcome = outcome
            }
        }
        if let d = line.delegateNotice, let key = state.delegateTasks[d.taskID] {
            if let status = d.status { end(key, at: at, status == "completed" ? .ok : .error) } else {
                state.attempts[key]?.waitAt = at
                touch(key)
            }
        }
    }

    private func spawned(_ sp: ClaudeTranscript.Spawn, by owner: String, session: String, at: Double) {
        guard state.spawns[sp.id] == nil else { return }
        var rec = SpawnRec(tool: sp.tool, spawner: owner, session: session, at: at, title: sp.title.map(Self.untagged),
                           agentType: sp.agentType, model: sp.model, tag: sp.tag?.description, statusTaskID: sp.statusTaskID)
        if sp.tool == .delegate {
            let key = "delegate:" + sp.id
            rec.attempt = key
            state.attempts[key] = AttemptRec(key: key, kind: .delegate, session: session, spawner: owner, toolUseID: sp.id, tag: rec.tag,
                                             title: rec.title, agentType: sp.agentType, model: sp.model, provider: sp.provider,
                                             startedAt: at, lastAt: at, brief: sp.brief)
            touch(key)
        }
        state.spawns[sp.id] = rec
        // An agent whose meta named this call was read first.
        if sp.tool == .agent, let a = state.attempts.values.first(where: { $0.toolUseID == sp.id && $0.kind == .agent }) { link(a.key, to: sp.id) }
        changed = true
    }

    private func result(_ r: ClaudeTranscript.Result, meta: ClaudeTranscript.ResultMeta?, at: Double) {
        guard let sp = state.spawns[r.toolUseID] else { return }
        switch sp.tool {
        case .agent:
            guard let id = meta?.agentID, let key = TaskRunID.sanitize(id).map({ "agent:" + $0 }) else { return }
            if state.attempts[key] == nil {
                state.attempts[key] = AttemptRec(key: key, kind: .agent, session: sp.session, spawner: sp.spawner, provider: "claude", startedAt: sp.at, lastAt: sp.at)
            }
            link(key, to: r.toolUseID)
            if let m = meta?.model { state.attempts[key]?.model = m }
            if r.isError { end(key, at: at, .error) } else if meta?.status == "completed" { end(key, at: at, .ok) }
            touch(key)
        case .workflow:
            guard let run = meta?.runID, let id = TaskRunID.sanitize(run) else { return }
            let key = "workflow:" + id
            if state.attempts[key] == nil {
                let dir = state.sessions[sp.session]?.dir
                state.attempts[key] = AttemptRec(key: key, kind: .workflow, session: sp.session, spawner: sp.spawner, toolUseID: r.toolUseID, tag: sp.tag,
                                                 title: meta?.workflowName, agentType: "workflow", provider: "claude", startedAt: sp.at, lastAt: sp.at,
                                                 workflowFile: dir.map { $0 + "/workflows/" + run + ".json" })
            }
            state.spawns[r.toolUseID]?.attempt = key
            if let e = sp.endedAt { end(key, at: e, sp.outcome ?? .ok) }
            if r.isError { end(key, at: at, .error) }
            touch(key)
        case .delegate:
            guard let key = sp.attempt else { return }
            let json = r.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if let task = json?["taskId"] as? String { state.delegateTasks[task] = key }
            // A waited call returns the outcome itself; no later message to the parent follows it.
            let status = json?["status"] as? String
            if r.isError || ["failed", "interrupted", "cancelled", "canceled"].contains(status ?? "") { end(key, at: at, .error) }
            else if status == "completed" { end(key, at: at, .ok) }
            touch(key)
        case .taskStatus:
            guard let task = sp.statusTaskID, let key = state.delegateTasks[task],
                  let json = r.text.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
                  let status = json["status"] as? String else { return }
            if status == "completed" { end(key, at: at, .ok) } else if ["failed", "interrupted", "cancelled", "canceled"].contains(status) { end(key, at: at, .error) }
        }
        changed = true
    }

    /// Fills an agent from the call that spawned it.
    private func link(_ key: String, to toolUseID: String) {
        guard var a = state.attempts[key], let sp = state.spawns[toolUseID] else { return }
        state.spawns[toolUseID]?.attempt = key
        a.toolUseID = toolUseID
        a.spawner = sp.spawner
        a.title = sp.title ?? a.title
        a.agentType = sp.agentType ?? a.agentType
        a.model = a.model ?? sp.model
        a.tag = sp.tag ?? a.tag
        a.startedAt = min(a.startedAt, sp.at)
        if a.lastAt < sp.at { a.lastAt = sp.at }
        state.attempts[key] = a
        if let e = sp.endedAt { end(key, at: e, sp.outcome ?? .ok) }
        touch(key)
    }

    private func end(_ key: String, at: Double, _ outcome: TaskAttemptOutcome) {
        guard var a = state.attempts[key] else { return }
        // An error stands against a later plain end at the same moment.
        if let e = a.endedAt, e >= at, a.outcome == .error || outcome == .ok { return }
        a.endedAt = max(at, a.endedAt ?? 0)
        a.outcome = outcome
        state.attempts[key] = a
        touch(key)
        if a.kind == .workflow {
            for other in state.attempts.values where other.spawner == key { touch(other.key) }
        }
        changed = true
    }

    // MARK: Codex lines

    private func codexLine(_ p: UnsafePointer<UInt8>, _ n: Int, file: inout TranscriptFile) {
        let wantText = !file.sawText
        guard let (lineAt, event) = CodexTranscript.parse(p, n, wantText: wantText) else { return }
        let at = lineAt ?? 0
        if case .meta(let id, let cwd, let started) = event {
            guard let sid = TaskRunID.sanitize(id), sid == id else { return }
            file.session = sid
            if state.sessions[sid] == nil {
                state.sessions[sid] = SessionRec(id: sid, harness: "codex", project: cwd.flatMap(Bytes.lastPathComponent),
                                                 startedAt: started ?? at, lastAt: started ?? at)
            }
            touchSession(sid)
            return
        }
        guard let sid = file.session, var s = state.sessions[sid] else { return }
        // Bookkeeping lines after a turn's end don't reopen it.
        if at > 0, s.stoppedAt == nil || { if case .started = event { true } else { false } }() { s.lastAt = max(s.lastAt, at) }
        switch event {
        case .meta: break
        case .model(let m): s.model = m
        case .started: s.stoppedAt = nil; s.aborted = false
        case .completed: s.stoppedAt = at
        case .aborted: s.stoppedAt = at; s.aborted = true
        case .tokens(let t): s.tokens = max(s.tokens, t)
        case .text(let text):
            file.sawText = true
            let c = Fingerprint.candidates(text)
            if !c.isEmpty, s.boundTo == nil { s.candidates = c }
        }
        state.sessions[sid] = s
        touchSession(sid)
    }

    // MARK: Meta files

    /// Reads an agent's meta file: its label and type, the call that spawned it, and whether it finished.
    private func readMeta(_ key: String) {
        guard let a = state.attempts[key], let path = a.meta else { return }
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var r = a
        if let d = json["description"] as? String {
            if r.title == nil { r.title = Self.untagged(d) }
            if r.tag == nil { r.tag = TaskRef.firstTag(in: d)?.description }
        }
        r.agentType = r.agentType ?? json["agentType"] as? String
        r.model = r.model ?? json["model"] as? String
        state.attempts[key] = r
        // The call that spawned it; if that line isn't read yet, `spawned` links them when it is.
        if let id = json["toolUseId"] as? String, r.toolUseID == nil {
            if state.spawns[id] != nil { link(key, to: id) } else { state.attempts[key]?.toolUseID = id }
        }
        // A running agent's meta has no `finished` key; it appears, true, when the agent ends
        // (seen on Claude Code 2.1.322), so keep reading until then. Workflow agents' meta never
        // gets one: nothing more to learn from it.
        let finished = json["finished"] as? Bool == true
        if finished || path.contains("/subagents/workflows/") {
            state.attempts[key]?.meta = nil
            if finished, state.attempts[key]?.endedAt == nil {
                end(key, at: max(state.attempts[key]?.lastAt ?? 0, r.startedAt), .ok)
            }
        }
        touch(key)
        changed = true
    }

    /// Meta files of unfinished agents and results of unfinished workflows, for the given
    /// sessions (nil: all recent).
    private func refreshMetas(sessions: Set<String>?) {
        let recent = now().timeIntervalSince1970 - 6 * 3600
        for a in state.attempts.values where effective(a).end == nil && (sessions?.contains(a.session) ?? (a.lastAt > recent)) {
            if a.meta != nil { readMeta(a.key) }
            if a.kind == .workflow, let path = a.workflowFile, let data = FileManager.default.contents(atPath: path),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let status = json["status"] as? String,
               status != "running" {
                let m = max(LogFileReader.fileStat(path)?.mtime ?? 0, a.lastAt)
                end(a.key, at: m, status == "completed" ? .ok : .error)
            }
        }
    }

    // MARK: Binding delegates to their sessions

    /// Children start after their delegate (within half an hour); among delegates with the same
    /// brief, the latest one before the child wins, so a retried brief binds in order.
    private func bind() {
        var open = state.attempts.values.filter { $0.kind == .delegate && $0.child == nil && $0.brief != nil }
        guard !open.isEmpty else { return }
        let children = state.sessions.values.filter { $0.boundTo == nil && !($0.candidates ?? []).isEmpty }.sorted { $0.startedAt < $1.startedAt }
        for c in children {
            let set = Set(c.candidates!)
            guard let d = open.filter({ set.contains($0.brief!) && $0.session != c.id && $0.startedAt <= c.startedAt + 5 && c.startedAt - $0.startedAt < 1800 })
                .max(by: { $0.startedAt < $1.startedAt }) else { continue }
            open.removeAll { $0.key == d.key }
            state.attempts[d.key]?.child = c.id
            state.attempts[d.key]?.brief = nil
            state.sessions[c.id]?.boundTo = d.key
            state.sessions[c.id]?.candidates = nil
            touch(d.key)
            // Its agents move under the delegate, into the delegate's run.
            for a in state.attempts.values where a.session == c.id { touch(a.key) }
            changed = true
        }
    }

    // MARK: Writing events

    private func touch(_ key: String) { touchedAttempts.insert(key) }

    private func touchSession(_ id: String) {
        touchedSessions.insert(id)
        if let d = state.sessions[id]?.boundTo { touchedAttempts.insert(d) }
    }

    /// When an attempt last moved, its tokens, and how it ended (nil while active). A delegate's
    /// come from its child; anything that moved after its end is active again.
    func effective(_ a: AttemptRec) -> (last: Double, tokens: Int64, end: Double?, outcome: TaskAttemptOutcome?) {
        var last = a.lastAt, tokens = a.tokens, end = a.endedAt, outcome = a.outcome
        if a.kind == .delegate, let cid = a.child, let c = state.sessions[cid] {
            last = max(last, c.lastAt)
            tokens = c.tokens
            // The child's turn ending ends the delegate, unless the parent heard of an end since.
            if let stop = c.stoppedAt, end == nil || stop > end! { end = stop; outcome = c.aborted ? .error : .ok }
        }
        if a.kind == .agent, end == nil, let w = a.spawner, w.hasPrefix("workflow:"), let wf = state.attempts[w], let e = wf.endedAt {
            end = max(e, last); outcome = wf.outcome
        }
        if let e = end, last > e + 1 { end = nil; outcome = nil }
        return (last, tokens, end, outcome)
    }

    /// The run an attempt's events go to: its tag's, else its spawner's.
    private func run(of key: String, depth: Int = 0) -> String? {
        if key.hasPrefix("session:") {
            let sid = String(key.dropFirst(8))
            if let d = state.sessions[sid]?.boundTo, depth < 16 { return run(of: d, depth: depth + 1) }
            return sid
        }
        guard let a = state.attempts[key] else { return nil }
        if let tag = liveTag(a), let ref = TaskRef(tag) { return ref.run }
        guard depth < 16, let spawner = a.spawner, spawner != key else { return a.session }
        return run(of: spawner, depth: depth + 1) ?? a.session
    }

    /// An attempt's tag, if it names a run an agent has declared tasks in (its journal exists).
    /// A prompt that only talks about tags ("put [hr:RUN:PATH] in the description") must not
    /// invent a run or a task.
    private func liveTag(_ a: AttemptRec) -> String? {
        guard let tag = a.tag, let ref = TaskRef(tag), TaskRunID.sanitize(ref.run) == ref.run,
              FileManager.default.fileExists(atPath: TaskJournal.url(run: ref.run, stream: .journal, home: home).path) else { return nil }
        return tag
    }

    /// The parent key written: a bound child session's spawns hang under the delegate.
    private func parent(of a: AttemptRec) -> String? {
        guard let s = a.spawner else { return nil }
        if s.hasPrefix("session:"), let d = state.sessions[String(s.dropFirst(8))]?.boundTo { return d }
        return s
    }

    private func publish() -> Int {
        let wall = now().timeIntervalSince1970
        var events: [TaskEvent] = []
        func event(_ at: Double, _ run: String, _ op: TaskEvent.Op) { events.append(TaskEvent(at: Date(timeIntervalSince1970: at), run: run, source: .harness, op: op)) }

        for key in touchedAttempts.sorted() {
            guard var a = state.attempts[key], a.lastAt > 0, let run = run(of: key), TaskRunID.sanitize(run) == run else { continue }
            if state.sessions[run]?.spawned == false {
                state.sessions[run]?.spawned = true
                touchedSessions.insert(run)
            }
            let fx = effective(a)
            if let old = a.out.run, old != run, a.out.endedAt == nil {
                // Its run changed (a tag's plan was declared late): close it where it was, or it
                // stays "running" there for good.
                event(max(fx.last, a.startedAt), old, .attemptEnd(attempt: key, outcome: .ok))
            }
            if a.out.run != run { a.out = Emitted(run: run) }
            let parentKey = parent(of: a)
            let tag = liveTag(a)
            let spec = TaskEvent.AttemptSpec(key: key, kind: a.kind, agentType: a.agentType, model: a.model, provider: a.provider,
                                             tag: tag, parentKey: parentKey, title: a.title)
            let specKey = [a.kind.rawValue, a.agentType, a.model, a.provider, tag, parentKey, a.title].map { $0 ?? "" }.joined(separator: "\u{1F}")
            if a.out.spec != specKey {
                event(a.startedAt, run, .attempt(spec))
                a.out.spec = specKey
            }
            if fx.end == nil, a.out.endedAt != nil {
                // Moving again after its end: a later upsert reopens it.
                event(fx.last, run, .attempt(spec))
                a.out.endedAt = nil
                a.out.outcome = nil
            }
            let ending = fx.end != nil && (a.out.endedAt != fx.end || a.out.outcome != fx.outcome)
            let moved = fx.last > (a.out.activityAt ?? -1) || fx.tokens != (a.out.tokens ?? 0)
            if moved, ending || wall - (a.out.wall ?? 0) >= Self.activityInterval {
                event(fx.last, run, .activity(attempt: key, at: nil, tokens: fx.tokens > 0 ? fx.tokens : nil))
                a.out.activityAt = fx.last
                a.out.tokens = fx.tokens
                a.out.wall = wall
                pending.remove(key)
            } else if moved {
                pending.insert(key)
            }
            if fx.end == nil, let w = a.waitAt, w > (a.out.waitAt ?? 0) {
                event(w, run, .wait(task: nil, attempt: key, reason: .input, note: nil))
                a.out.waitAt = w
            }
            if ending, let e = fx.end {
                event(e, run, .attemptEnd(attempt: key, outcome: fx.outcome ?? .ok))
                a.out.endedAt = e
                a.out.outcome = fx.outcome
            }
            state.attempts[key] = a
        }

        var journals: [String: Bool] = [:]
        for sid in touchedSessions.sorted() {
            guard var s = state.sessions[sid], s.boundTo == nil, s.lastAt > 0, TaskRunID.sanitize(sid) == sid else { continue }
            if !s.spawned {
                let has = journals[sid] ?? FileManager.default.fileExists(atPath: TaskJournal.url(run: sid, stream: .journal, home: home).path)
                journals[sid] = has
                guard has else { continue }
            }
            let key = "session:" + sid
            if !state.metaRuns.contains(sid) {
                event(s.startedAt, sid, .meta(title: nil, project: s.project, harness: s.harness))
                state.metaRuns.insert(sid)
            }
            let provider = s.harness == "codex" ? "codex" : "claude"
            let specKey = [s.model ?? "", provider].joined(separator: "\u{1F}")
            if s.out.run != sid { s.out = Emitted(run: sid) }
            if s.out.spec != specKey {
                event(s.startedAt, sid, .attempt(.init(key: key, kind: .session, model: s.model, provider: provider)))
                s.out.spec = specKey
            }
            let moved = s.lastAt > (s.out.activityAt ?? -1) || s.tokens != (s.out.tokens ?? 0)
            let stopped = s.stoppedAt != nil
            if moved, stopped != s.outStopped || wall - (s.out.wall ?? 0) >= Self.activityInterval {
                event(s.lastAt, sid, .activity(attempt: key, at: nil, tokens: s.tokens > 0 ? s.tokens : nil))
                s.out.activityAt = s.lastAt
                s.out.tokens = s.tokens
                s.out.wall = wall
                pending.remove(sid)
            } else if moved {
                pending.insert(sid)
            }
            if stopped != (s.outStopped ?? false) {
                if let at = s.stoppedAt { event(at, sid, .stop(blocked: false)) } else { event(s.lastAt, sid, .resume) }
            }
            s.outStopped = stopped
            state.sessions[sid] = s
        }
        touchedAttempts = []
        touchedSessions = []
        guard !events.isEmpty else { return 0 }
        try? TaskJournal.append(events, stream: .observed, home: home)
        changed = true
        return events.count
    }

    // MARK: Saving

    /// Writes the state now if anything changed (on quit, and after a one-off scan).
    public func flush() { save(force: true) }

    /// A crash between saves costs only repeated events, which fold to the same thing.
    private func save(force: Bool = false) {
        prune()
        let t = now().timeIntervalSince1970
        guard changed, force || t - savedAt >= Self.saveInterval else { return }
        savedAt = t
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(state) else { return }
        let url = Self.stateURL(home: home)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".observer.\(getpid()).tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        chmod(tmp.path, 0o600)
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
        changed = false
    }

    /// Hourly: forgets what's a week old, spawns after a day, and child fingerprints after a day.
    private func prune() {
        let t = now().timeIntervalSince1970
        guard t - state.prunedAt > 3600 else { return }
        state.prunedAt = t
        let week = t - Self.keep, day = t - 86400
        state.sessions = state.sessions.filter { $0.value.lastAt >= week || $0.value.lastAt == 0 && $0.value.startedAt >= week }
        for (id, s) in state.sessions where s.candidates != nil && s.startedAt < day { state.sessions[id]?.candidates = nil }
        state.attempts = state.attempts.filter { $0.value.lastAt >= week }
        state.spawns = state.spawns.filter { $0.value.at >= day }
        state.delegateTasks = state.delegateTasks.filter { state.attempts[$0.value] != nil }
        state.files = state.files.filter { $0.value.mtime >= week }
        state.metaRuns = state.metaRuns.filter { state.sessions[$0] != nil }
        changed = true
    }

    /// Drops a `[hr:…]` tag from a label.
    static func untagged(_ label: String) -> String {
        guard let ref = TaskRef.firstTag(in: label) else { return label }
        let t = label.replacingOccurrences(of: ref.tag, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? label : t
    }
}
