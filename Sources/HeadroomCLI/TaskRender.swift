import Foundation
import HeadroomKit

/// `headroom tasks`: each run as a header (glyph, title, a done/in-flight/not-started bar,
/// percent, must-haves, ETA, tokens), then its tasks as an indented tree.
enum TaskRender {
    static func render(_ runs: [TaskRun], style: Style, now: Date, live: Bool, all: Bool) -> String {
        var lines: [String] = []
        if runs.isEmpty {
            lines.append(all ? "No task runs in the last 7 days." : "No active task runs.")
            lines.append(style.dim("Agents declare tasks with `headroom task plan`; `headroom task guide` explains how."))
        }
        for (i, r) in runs.enumerated() {
            if i > 0 { lines.append("") }
            lines.append(header(r, style: style, now: now))
            let width = min(36, (r.nodes.map { $0.depth * 2 + TaskText.display($0.title, limit: TaskText.titleLimit).count }.max() ?? 0))
            for n in r.nodes { lines.append(line(n, style: style, now: now, width: width, declared: r.hasDeclaredTasks)) }
            if let earlier = r.finishedEarlier, earlier > 0 { lines.append("  " + style.dim("+ \(earlier) finished earlier")) }
        }
        if !live { lines.append(style.dim("(Headroom.app isn't running, so only tasks agents reported are shown)")) }
        return lines.joined(separator: "\n")
    }

    static func header(_ r: TaskRun, style: Style, now: Date) -> String {
        let (g, hex) = glyph(r.state, reason: r.waitReason)
        // Nothing declared: nobody knows how many agents are still to come, so counts, not a percent or an ETA.
        let observed = !r.hasDeclaredTasks && !r.nodes.isEmpty
        var parts: [String] = []
        if observed {
            let earlier = r.finishedEarlier ?? 0
            parts.append("\(r.nodes.filter(\.state.isTerminal).count + earlier) of \(r.nodes.count + earlier) agents finished")
        } else {
            parts.append(percent(r.progress, style: style))
            if r.mustHaves.total > 0 { parts.append("must-haves \(r.mustHaves.done)/\(r.mustHaves.total)") }
            if let eta = r.etaSeconds { parts.append("~\(TimeFormat.compact(eta)) left") }
        }
        if r.tokens > 0 { parts.append("\(NumberFormat.tokens(r.tokens)) tokens") }
        // For an unnamed run, show its project or a short id.
        let name = TaskText.display(r.bestTitle ?? r.project ?? String(r.id.prefix(8)), limit: TaskText.titleLimit)
        var head = "\(style.paint(g, hex)) \(style.bold(name))  " + (observed ? "" : "\(bar(r.progress, width: 20, style: style))  ") + parts.joined(separator: " · ")
        var detail = [stateWord(r)]
        if r.stale { detail.append("no activity for \(TimeFormat.compact(now.timeIntervalSince(r.updatedAt)))") }
        detail.append("updated \(TimeFormat.compact(now.timeIntervalSince(r.updatedAt))) ago")
        if r.scopeChanges > 0 { detail.append("scope +\(r.scopeChanges)") }
        if let p = r.project { detail.append(TaskText.display(p, limit: 60)) }
        if let repo = r.repo { detail.append(TaskText.display(repo, limit: 80)) }
        if let branch = r.branch { detail.append(TaskText.display(branch, limit: 80)) }
        if let h = r.harness { detail.append(TaskText.display(h, limit: 40)) }
        head += "\n  " + style.dim(detail.joined(separator: " · "))
        if let w = r.warning { head += "\n  " + style.paint("⚠ " + TaskText.display(w), Style.amber) }
        return head
    }

    static func line(_ n: TaskNode, style: Style, now: Date, width: Int, declared: Bool = true) -> String {
        // A failed approach another task took over from: set aside, not a failure.
        let (g, hex) = n.replacedBy != nil ? ("↷", Style.muted) : glyph(n.state, reason: n.waitReason)
        let indent = String(repeating: "  ", count: n.depth + 1)
        let quiet = !n.counted || n.state == .skipped || n.state == .cancelled
        let title = TaskText.display(n.title, limit: TaskText.titleLimit)
        let padded = title.count + n.depth * 2 >= width ? title : title.padding(toLength: width - n.depth * 2, withPad: " ", startingAt: 0)
        var out = indent + style.paint(g, hex) + " " + (quiet ? style.dim(padded) : padded)
        out += "  " + bar(n.progress, width: 10, style: style) + " " + percent(n.progress, style: style).leftPad(4)
        var detail: [String] = []
        if let s = n.steps, n.leaf { detail.append("\(s.done)/\(s.total)") }
        if n.importance != .normal { detail.append(n.importance.rawValue) }
        switch n.state {
        case .waiting:
            detail.append(style.paint(n.waitReason == .input ? "needs input" : "waiting on \(n.waitReason?.rawValue ?? "dependency")", Style.amber))
            if let w = n.waitNote { detail.append(TaskText.display(w)) }
        case .failed where n.replacedBy != nil:
            detail.append("replaced by \(n.replacedBy!)")
            if let f = n.failure { detail.append(TaskText.display(f)) }
        case .failed:
            if let f = n.failure { detail.append(style.paint(TaskText.display(f), Style.rose)) }
        case .parked:
            detail.append("parked")
        default:
            break
        }
        if n.stale, let last = n.lastActivityAt { detail.append(style.paint("stale \(TimeFormat.compact(now.timeIntervalSince(last)))", Style.amber)) }
        // Only where a plan was declared: in a run nobody declared, no agent ever reports an outcome.
        if !n.confirmed, declared { detail.append("unconfirmed") }
        if n.attempts.retries > 0 { detail.append("retried \(n.attempts.retries)×") }
        if n.attempts.active > 1 { detail.append("\(n.attempts.active) agents") }
        if n.tokens > 0 { detail.append(NumberFormat.tokens(n.tokens)) }
        if let note = n.note, n.state != .waiting, n.state != .failed { detail.append(TaskText.display(note)) }
        if !detail.isEmpty { out += "  " + style.dim("· ") + detail.joined(separator: style.dim(" · ")) }
        return out
    }

    /// `42%`, or `42% (~55%)` when tokens suggest more than has been reported done.
    static func percent(_ p: TaskProgress, style: Style) -> String {
        let done = Int((p.done * 100).rounded(.down))
        let est = Int((p.estimate * 100).rounded(.down))
        return est > done ? "\(done)%" + style.dim(" (~\(est)%)") : "\(done)%"
    }

    /// Done █, in flight ▒, not started ░.
    static func bar(_ p: TaskProgress, width: Int, style: Style) -> String {
        let d = Int((p.done * Double(width)).rounded())
        let f = max(0, min(width, Int(((p.done + p.inFlight) * Double(width)).rounded())) - d)
        let rest = max(0, width - d - f)
        return style.paint(String(repeating: "█", count: d), Style.blue) + style.paint(String(repeating: "▒", count: f), Style.blue)
            + style.paint(String(repeating: "░", count: rest), Style.muted)
    }

    static func glyph(_ s: TaskState, reason: TaskWaitReason?) -> (String, UInt32?) {
        switch s {
        case .planned: ("○", Style.muted)
        case .running: ("●", Style.blue)
        case .waiting: ("⏸", reason == .input ? Style.rose : Style.amber)
        case .parked: ("◐", Style.muted)
        case .done: ("✓", Style.green)
        case .partial: ("◑", Style.amber)
        case .failed: ("✗", Style.rose)
        case .skipped, .cancelled: ("⊘", Style.muted)
        }
    }

    static func glyph(_ s: TaskRunState, reason: TaskWaitReason?) -> (String, UInt32?) {
        switch s {
        case .running: ("●", Style.blue)
        case .waiting: ("⏸", reason == .input ? Style.rose : Style.amber)
        case .stopped: ("■", Style.muted)
        case .done: ("✓", Style.green)
        case .partial: ("◑", Style.amber)
        case .failed: ("✗", Style.rose)
        }
    }

    static func stateWord(_ r: TaskRun) -> String {
        switch r.state {
        case .waiting: r.waitReason == .input ? "needs input" : "waiting on \(r.waitReason?.rawValue ?? "dependency")"
        case .stopped: "stopped with work left"
        default: r.state.rawValue
        }
    }

    /// One line for `wait --run`: title, state, percent.
    static func summary(_ r: TaskRun, style: Style) -> String {
        "\(TaskText.display(r.bestTitle ?? r.project ?? r.id, limit: TaskText.titleLimit)) · \(stateWord(r)) · \(Int((r.progress.done * 100).rounded(.down)))%"
    }

    /// The status line's run segment: percent done, running count, and a marker when it needs you.
    static func statusSegment(_ r: TaskRun, format: StatusLine.Format, colors: Bool) -> String {
        var s = "▤ \(Int((r.progress.done * 100).rounded(.down)))%"
        if r.runningCount > 0 { s += " ▶\(r.runningCount)" }
        if r.needsInput { s += " " + StatusLine.paint("⏸input", Style.rose, format: format, colors: colors) }
        else if r.state == .failed || r.state == .partial { s += " " + StatusLine.paint("✗", Style.rose, format: format, colors: colors) }
        else if r.state == .done { s += " ✓" }
        return s
    }
}
