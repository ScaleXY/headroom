import Foundation
import HeadroomKit
import notify

/// The `headroom` command. Reads `snapshot.json` only: it never touches credentials or the network.
public enum HeadroomCLI {
    public static let version = "0.1.1-beta.5"

    public enum Exit: Int32 {
        case ok = 0
        case failure = 1
        case usage = 64
        case timeout = 2
        case noData = 3
    }

    /// `home` holds `snapshot.json`, `tasks.json` and `tasks/`; it defaults to the snapshot's directory.
    public static func run(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           output: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                           snapshotURL: URL? = nil, home: URL? = nil, input: CLIInput = .standard,
                           now: @escaping () -> Date = Date.init) -> Int32 {
        let snapshotURL = snapshotURL ?? (home ?? SnapshotFile.directory(environment: environment)).appendingPathComponent("snapshot.json")
        let home = home ?? snapshotURL.deletingLastPathComponent()
        var args = args
        let style = Style(environment: environment, isTTY: isatty(STDOUT_FILENO) == 1, forceColor: args.contains("--color"))
        args.removeAll { $0 == "--color" }

        // `task` and `hooks` take free text (`--note`, `--title`) and print their own help.
        let freeText = ["task", "hooks"].contains(args.first ?? "")
        if args.first == "help" || (!freeText && (args.contains("--help") || args.contains("-h"))) {
            output(usage)
            return Exit.ok.rawValue
        }
        if args.first == "--version" || (!freeText && args.contains("--version")) {
            output("headroom \(version)")
            return Exit.ok.rawValue
        }
        let json = args.contains("--json")
        let ctx = TaskContext(home: home, environment: environment, now: now, output: output, style: style, input: input, snapshotURL: snapshotURL)
        switch args.first {
        case "statusline":
            // Status lines are read through pipes (Claude Code, tmux), so only NO_COLOR turns colors off.
            let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
            return statusline(Array(args.dropFirst()), style: Style(colors: !noColor), output: output, url: snapshotURL, now: now(), tasks: ctx)
        case "wait":
            let rest = Array(args.dropFirst())
            if rest.contains("--run") {
                return RunWaitCommand.run(rest, ctx: ctx)
            }
            return WaitCommand.run(rest, style: style, output: output, url: snapshotURL, now: now)
        case "tasks":
            return TasksCommand.run(Array(args.dropFirst()), ctx: ctx)
        case "task":
            return TaskCommand.run(Array(args.dropFirst()), ctx: ctx)
        case "hooks":
            return HooksCommand.run(Array(args.dropFirst()), ctx: ctx)
        case "mcp":
            return MCPServer(ctx: ctx, snapshotURL: snapshotURL).serve()
        case nil, "--json", "--refresh":
            if args.contains("--refresh") { Refresh.request(url: snapshotURL, now: now) }
            guard let snapshot = SnapshotFile.read(from: snapshotURL) else {
                output(json ? #"{"error":"no_snapshot","message":"Headroom has not written a snapshot yet. Is the app running?"}"# : "No Headroom data yet. Open Headroom.app (it writes \(snapshotURL.path)).")
                return Exit.noData.rawValue
            }
            if json {
                output(jsonOutput(snapshot, now: now()))
            } else {
                output(Summary.render(snapshot, style: style, now: now()))
            }
            return Exit.ok.rawValue
        default:
            output(usage)
            return Exit.usage.rawValue
        }
    }

    static let usage = """
    usage: headroom [--json] [--refresh]
           headroom statusline [--format claude|tmux|sketchybar|plain] [--provider claude|codex] [--run ID]
           headroom wait [--provider claude|codex|any] [--timeout 6h] [--json]
           headroom wait --run ID [--until done|attention] [--timeout 6h] [--json]
           headroom tasks [--run ID] [--all] [--json] [--watch]
           headroom task plan [--run ID] [--title T] [--file PATH | -]
           headroom task add ID --title T [--effort xs|s|m|l|xl|N] [--importance critical|normal|optional] [--steps N]
           headroom task start|done|fail|skip|cancel ID [ID …] | progress|wait ID … (see headroom task --help)
           headroom task status [--titles] | guide | adopt RUN | hook
           headroom hooks install|uninstall|status [--codex] [--enforce] [--instructions] [--settings PATH] [--project]
           headroom mcp

    Shows how much of your weekly Claude and Codex allowance is left against the time
    left until renewal, and what long agent runs are doing. Reads the files Headroom.app
    writes; never uses credentials or the network. See headroom(1).
    """

    /// The snapshot plus liveness fields, pretty-printed.
    static func jsonOutput(_ s: Snapshot, now: Date) -> String {
        let encoder = SnapshotFile.encoder(pretty: true)
        guard let data = try? encoder.encode(s), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        object["stale"] = !SnapshotFile.writerIsAlive(s)
        object["age_seconds"] = Int(now.timeIntervalSince(s.generatedAt))
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: statusline

    static func statusline(_ args: [String], style: Style, output: (String) -> Void, url: URL, now: Date, tasks: TaskContext) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let format = StatusLine.Format(rawValue: value("--format") ?? "claude") ?? .claude
        let only = value("--provider").flatMap(Provider.init(rawValue:))
        guard let s = SnapshotFile.read(from: url) else {
            output("Headroom: no data")
            return Exit.noData.rawValue
        }
        var line = StatusLine.render(s, format: format, only: only, colors: style.colors, now: now)
        // Claude Code pipes its session JSON in; its `session_id` names the run when nothing else does.
        let piped = format == .claude ? tasks.input.readPiped() : nil
        let session = piped.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["session_id"] as? String
        if let run = RunResolver.resolve(flag: value("--run"), environment: tasks.environment, session: session, home: tasks.home),
           let r = TaskStore(home: tasks.home).run(run, now: now), !r.nodes.isEmpty, r.isActive(now: now) {
            line += "  " + TaskRender.statusSegment(r, format: format, colors: style.colors)
        }
        output(line)
        return Exit.ok.rawValue
    }
}

/// ANSI styling; honors NO_COLOR and plain pipes.
struct Style {
    var colors: Bool

    init(environment: [String: String], isTTY: Bool, forceColor: Bool) {
        if let nc = environment["NO_COLOR"], !nc.isEmpty { colors = false }
        else { colors = forceColor || isTTY }
    }

    init(colors: Bool) { self.colors = colors }

    func paint(_ s: String, _ hex: UInt32?) -> String {
        guard colors, let hex else { return s }
        return "\u{1B}[38;2;\((hex >> 16) & 0xFF);\((hex >> 8) & 0xFF);\(hex & 0xFF)m\(s)\u{1B}[0m"
    }

    func bold(_ s: String) -> String { colors ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    func dim(_ s: String) -> String { colors ? "\u{1B}[2m\(s)\u{1B}[0m" : s }

    static func hex(for state: PacingState) -> UInt32? {
        switch state {
        case .plenty: 0x6AA8FF
        case .onPace: nil
        case .tight: 0xFFC248
        case .veryTight: 0xFF6982
        }
    }

    static func hex(for level: SessionLevel) -> UInt32? {
        switch level {
        case .normal: nil
        case .amber: 0xFFC248
        case .rose, .blocked: 0xFF6982
        }
    }

    static let credit: UInt32 = 0x8CC2FF
    static let muted: UInt32 = 0x8A90A2
    static let blue: UInt32 = 0x6AA8FF
    static let amber: UInt32 = 0xFFC248
    static let rose: UInt32 = 0xFF6982
    static let green: UInt32 = 0x5BD68A
}

enum Refresh {
    /// Posts the refresh notification (debounced to ≥ 30 s) and waits up to 10 s for a new snapshot.
    static func request(url: URL, now: () -> Date) {
        let before = SnapshotFile.read(from: url)
        if let b = before, SnapshotFile.writerIsAlive(b), now().timeIntervalSince(b.generatedAt) < 30 { return }
        notify_post(SnapshotFile.refreshNotification)
        guard before.map(SnapshotFile.writerIsAlive) ?? false else { return }
        _ = SnapshotWatch.waitForChange(url: url, after: before?.generatedAt, timeout: 10)
    }
}

/// Blocks (no CPU) until the snapshot's `generated_at` changes, or the timeout passes.
enum SnapshotWatch {
    static func waitForChange(url: URL, after: Date?, timeout: TimeInterval) -> Snapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        let dirFD = open(url.deletingLastPathComponent().path, O_EVTONLY)
        defer { if dirFD >= 0 { close(dirFD) } }
        let kq = kqueue()
        defer { close(kq) }
        if dirFD >= 0 {
            var ev = kevent(ident: UInt(dirFD), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_DELETE), data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }
        while true {
            if let s = SnapshotFile.read(from: url), s.generatedAt != after { return s }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var ts = timespec(tv_sec: Int(left), tv_nsec: Int((left - floor(left)) * 1e9))
            var out = kevent()
            _ = kevent(kq, nil, 0, &out, 1, &ts)
        }
    }
}
