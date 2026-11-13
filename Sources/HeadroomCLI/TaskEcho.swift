import Foundation
import HeadroomKit

/// What `headroom task` says back to the agent: one line after every report, and the compact
/// tree `headroom task status` prints. Both are about the caller's run only.
enum TaskEcho {
    /// A running task with no report for this long gets named in the echo.
    static let silence: TimeInterval = 20 * 60

    /// Leaves still open that an agent can act on (untagged helper agents left out): running
    /// first, then waiting, then planned, each in plan order.
    static func open(_ r: TaskRun) -> [TaskNode] {
        func rank(_ n: TaskNode) -> Int { n.state == .running ? 0 : n.state == .waiting ? 1 : 2 }
        return r.nodes.enumerated()
            .filter { $0.element.leaf && !$0.element.state.isTerminal && !TaskPath.isImplicit($0.element.id) }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The headline percent: the fold's best estimate.
    static func percent(_ r: TaskRun) -> String { "\(Int((r.progress.estimate * 100).rounded(.down)))%" }

    static func describe(_ n: TaskNode, now: Date) -> String {
        switch n.state {
        case .running: n.startedAt.map { "running \(TimeFormat.compact(max(0, now.timeIntervalSince($0))))" } ?? "running"
        case .waiting: "waiting on \(n.waitReason?.rawValue ?? "dependency")"
        default: n.state.rawValue
        }
    }

    /// Up to three lines: what changed, the run's percent and what is open; a nudge about the
    /// running task silent longest (over 20 minutes); the room left in the 5-hour window.
    static func lines(changed: String, touched: Set<String>, run r: TaskRun, ctx: TaskContext) -> [String] {
        let now = ctx.now()
        let open = open(r)
        var first = changed + " · run \(percent(r))"
        if open.isEmpty {
            if r.hasDeclaredTasks { first += " · nothing open" }
        } else {
            first += " · open: " + open.prefix(3).map { "\($0.id) (\(describe($0, now: now)))" }.joined(separator: ", ")
                + (open.count > 3 ? " +\(open.count - 3) more" : "")
        }
        var out = [first]
        let quiet = open.filter { $0.state == .running && !touched.contains($0.id) }
            .compactMap { n in n.lastActivityAt.map { (n.id, now.timeIntervalSince($0)) } }
            .filter { $0.1 > silence }
            .max { $0.1 < $1.1 }
        if let quiet {
            out.append("\(quiet.0) has had no report for \(TimeFormat.compact(quiet.1)): report its progress, or close it if it's finished.")
        }
        if let room = room(r, ctx: ctx) { out.append(room) }
        return out
    }

    /// The limits line for the run's provider, when the app knows it.
    static func room(_ r: TaskRun, ctx: TaskContext) -> String? {
        let harness = r.harness ?? (ctx.environment["CLAUDE_CODE_SESSION_ID"] != nil ? "claude-code" : ctx.environment["CODEX_THREAD_ID"] != nil ? "codex" : nil)
        guard let p = TaskLimits.provider(named: harness), let s = ctx.snapshot else { return nil }
        return TaskLimits.roomLine(p, providers: s.providers, now: ctx.now())
    }

    // MARK: Status

    static func stateWord(_ n: TaskNode) -> String {
        n.state == .waiting ? "waiting:\(n.waitReason?.rawValue ?? "dependency")" : n.state.rawValue
    }

    /// The run as a compact tree for an agent: a header with the run id, then one line per task,
    /// `name  state  [steps]  [age or note]`, indented by depth. Finished groups are one line.
    static func status(_ r: TaskRun, now: Date, titles: Bool) -> [String] {
        let tasks = r.nodes.filter { !TaskPath.isImplicit($0.id) }
        let leaves = tasks.filter { $0.leaf && $0.counted }
        var head = "run \(r.id)"
        if r.title != r.id { head += " \"\(TaskText.display(r.title, limit: 60))\"" }
        head += " · \(percent(r)) · \(leaves.filter { $0.state == .done }.count) of \(leaves.count) done"
        switch r.state {
        case .running: break
        case .waiting: head += " · waiting on \(r.waitReason?.rawValue ?? "dependency")"
        case .stopped: head += " · stopped with work left"
        default: head += " · \(r.state.rawValue)"
        }
        guard r.hasDeclaredTasks, !tasks.isEmpty else {
            return [head, "No plan declared. For work with 3 or more steps, declare one: headroom task guide explains how."]
        }
        var rows: [(name: String, state: String, rest: [String])] = []
        var folded: [String] = []
        for n in tasks {
            if folded.contains(where: { n.id.hasPrefix($0 + "/") }) { continue }
            let name = String(repeating: "  ", count: max(0, n.depth)) + TaskPath.last(n.id)
            var rest: [String] = []
            if n.leaf {
                if let s = n.steps { rest.append("\(s.done)/\(s.total)") }
            } else {
                let under = leaves.filter { $0.id.hasPrefix(n.id + "/") }
                if !under.isEmpty { rest.append("\(under.filter { $0.state == .done }.count)/\(under.count)") }
                if n.state.isTerminal { folded.append(n.id) }
            }
            var detail: [String] = []
            switch n.state {
            case .running where n.leaf:
                if let s = n.startedAt { detail.append(TimeFormat.compact(max(0, now.timeIntervalSince(s)))) }
                if let last = n.lastActivityAt, now.timeIntervalSince(last) > silence { detail.append("no report for \(TimeFormat.compact(now.timeIntervalSince(last)))") }
            case .waiting:
                if let w = n.waitNote { detail.append(TaskText.display(w, limit: 50)) }
            case .failed:
                if let f = n.failure { detail.append(TaskText.display(f, limit: 50)) }
            default:
                break
            }
            if !detail.isEmpty { rest.append(detail.joined(separator: ", ")) }
            if titles { rest.append("\"\(TaskText.display(n.title, limit: TaskText.titleLimit))\"") }
            rows.append((name, stateWord(n), rest))
        }
        let nameWidth = min(28, rows.map(\.name.count).max() ?? 0)
        let stateWidth = rows.map(\.state.count).max() ?? 0
        return [head] + rows.map { row in
            let name = row.name.count >= nameWidth ? row.name : row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let state = row.rest.isEmpty ? row.state : row.state.padding(toLength: stateWidth, withPad: " ", startingAt: 0)
            return ([name, state] + row.rest).joined(separator: "  ")
        }
    }
}
