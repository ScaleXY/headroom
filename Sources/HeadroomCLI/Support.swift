import Foundation
import HeadroomKit
import notify

/// Standard input, swappable for tests.
public struct CLIInput {
    /// Everything up to end of file.
    public var readAll: () -> Data
    /// One line without its newline; nil at end of file.
    public var readLine: () -> String?
    /// Whether input comes from a pipe or file rather than a terminal.
    public var isPiped: Bool
    /// Whether input (or end of file) is ready within this many milliseconds.
    public var isReady: (Int32) -> Bool

    public init(readAll: @escaping () -> Data, readLine: @escaping () -> String?, isPiped: Bool, isReady: @escaping (Int32) -> Bool = { _ in true }) {
        self.readAll = readAll; self.readLine = readLine; self.isPiped = isPiped; self.isReady = isReady
    }

    public static var standard: CLIInput {
        CLIInput(readAll: { FileHandle.standardInput.readDataToEndOfFile() }, readLine: { Swift.readLine(strippingNewline: true) },
                 isPiped: isatty(STDIN_FILENO) == 0,
                 isReady: { ms in
                     var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                     return poll(&p, 1, ms) > 0
                 })
    }

    /// Fixed input: the whole of `data`, or its lines one at a time.
    public static func data(_ data: Data) -> CLIInput {
        final class Lines: @unchecked Sendable { var rest: [String] = [] }
        let lines = Lines()
        lines.rest = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.rest.last == "" { lines.rest.removeLast() }
        return CLIInput(readAll: { data }, readLine: { lines.rest.isEmpty ? nil : lines.rest.removeFirst() }, isPiped: true)
    }

    /// Input only if some is already waiting or arrives within a moment: status lines also run
    /// under tmux and prompts, and agents' shells, where standard input may be a pipe nobody writes to.
    func readPiped(timeout: Int32 = 50) -> Data? {
        guard isPiped, isReady(timeout) else { return nil }
        let data = readAll()
        return data.isEmpty ? nil : data
    }
}

/// What every task command needs, threaded through instead of read from the process.
struct TaskContext {
    var home: URL
    var environment: [String: String]
    var now: () -> Date
    var output: (String) -> Void
    var style: Style
    var input: CLIInput
    /// The app's snapshot, for the room left in the 5-hour window; `home/snapshot.json` when nil.
    var snapshotURL: URL? = nil

    /// Wakes `--watch`, `wait --run` and the app.
    func posted() { notify_post(TaskJournal.notification) }

    func append(_ events: [TaskEvent]) throws {
        try TaskJournal.append(events, stream: .journal, home: home)
        posted()
    }

    func error(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    var snapshot: Snapshot? { SnapshotFile.read(from: snapshotURL ?? home.appendingPathComponent("snapshot.json")) }
}

/// Which run a command or hook means. One order everywhere: `--run`, then `HEADROOM_RUN`, then the
/// harness session (a hook payload's `session_id`, else `CLAUDE_CODE_SESSION_ID`,
/// `CODEX_THREAD_ID`, `T3CODE_THREAD_ID`). A harness session that adopted an earlier run
/// (`headroom task adopt`) means that run. A `RUN:` prefix on a task id names the run for that id
/// when no `--run` is given.
enum RunResolver {
    static let sessionVariables = ["CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "T3CODE_THREAD_ID"]
    static let variables = ["HEADROOM_RUN"] + sessionVariables

    static func resolve(flag: String?, environment: [String: String], session: String? = nil, home: URL? = nil) -> String? {
        if let flag, !flag.isEmpty { return TaskRunID.sanitize(flag) }
        if let raw = environment["HEADROOM_RUN"], let id = TaskRunID.sanitize(raw) { return id }
        guard let s = harnessSession(environment: environment, payload: session) else { return nil }
        return home.flatMap { alias(for: s, home: $0) } ?? s
    }

    /// The harness's own id for this session, before any adoption.
    static func harnessSession(environment: [String: String], payload: String? = nil) -> String? {
        if let payload, let id = TaskRunID.sanitize(payload) { return id }
        for v in sessionVariables { if let raw = environment[v], let id = TaskRunID.sanitize(raw) { return id } }
        return nil
    }

    /// `tasks/aliases/<session>`: the run a session adopted.
    static func aliasURL(session: String, home: URL) -> URL {
        TaskJournal.directory(home: home).appendingPathComponent("aliases", isDirectory: true).appendingPathComponent(session)
    }

    static func alias(for session: String, home: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: aliasURL(session: session, home: home).path) else { return nil }
        return TaskRunID.sanitize(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a run has any event file.
    static func exists(_ run: String, home: URL) -> Bool {
        TaskJournal.Stream.allCases.contains { FileManager.default.fileExists(atPath: TaskJournal.url(run: run, stream: $0, home: home).path) }
    }

    /// Which harness a run id came from, for the run's metadata.
    static func harness(environment: [String: String]) -> String? {
        if environment["HEADROOM_RUN"]?.isEmpty == false { return nil }
        if environment["CLAUDE_CODE_SESSION_ID"]?.isEmpty == false { return "claude-code" }
        if environment["CODEX_THREAD_ID"]?.isEmpty == false { return "codex" }
        if environment["T3CODE_THREAD_ID"]?.isEmpty == false { return "t3code" }
        return nil
    }

    /// The app the session runs in: its bundle id (`__CFBundleIdentifier`), else `TERM_PROGRAM`.
    static func host(environment: [String: String]) -> String? {
        for v in ["__CFBundleIdentifier", "TERM_PROGRAM"] { if let h = environment[v], !h.isEmpty { return String(h.prefix(120)) } }
        return nil
    }

    static let missing = "no run id: pass --run ID, prefix the task id with RUN: (from a [hr:RUN:PATH] tag), or set HEADROOM_RUN"
}

/// Flags and positionals. Valued flags take the next argument (so notes may start with `-`) or
/// `--flag=value`; `repeated` flags may be given more than once.
struct Args {
    var positional: [String] = []
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []

    struct Bad: Error { var message: String }

    init(_ args: [String], valued: Set<String> = [], flags known: Set<String> = [], repeated: Set<String> = []) throws(Bad) {
        var i = 0
        while i < args.count {
            var a = args[i]
            var inline: String?
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                inline = String(a[a.index(after: eq)...])
                a = String(a[..<eq])
            }
            if valued.contains(a) || repeated.contains(a) {
                let v: String
                if let inline {
                    v = inline
                    i += 1
                } else {
                    guard i + 1 < args.count else { throw Bad(message: "\(a) needs a value") }
                    v = args[i + 1]
                    i += 2
                }
                if repeated.contains(a) { lists[a, default: []].append(v) } else { values[a] = v }
                continue
            }
            if known.contains(a) {
                guard inline == nil else { throw Bad(message: "\(a) takes no value") }
                flags.insert(a)
            } else if a.hasPrefix("--") {
                throw Bad(message: "unknown option \(a)")
            } else {
                positional.append(args[i])
            }
            i += 1
        }
    }

    subscript(_ flag: String) -> String? { values[flag] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

/// Reads the folded runs: `tasks.json` while its writer runs, otherwise (and for any run written
/// to since the app last folded) a fold of the event files, compacted as the app compacts them.
struct TaskStore {
    var home: URL
    static let window: TimeInterval = 7 * 86400

    struct Loaded {
        var runs: [TaskRun]
        /// Whether a live app wrote the file the runs came from.
        var live: Bool
    }

    func load(now: Date, all: Bool) -> Loaded {
        let since = now.addingTimeInterval(-Self.window)
        var runs: [TaskRun]
        var live = false
        if let feed = TasksFile.read(from: TasksFile.url(home: home)), TasksFile.writerIsAlive(feed) {
            live = true
            let fresh = Set(TaskJournal.runs(home: home, modifiedSince: feed.generatedAt))
            runs = feed.runs.filter { !fresh.contains($0.id) }
            if !fresh.isEmpty {
                let folded = TaskFold.foldCalibrated(fresh.flatMap { TaskJournal.read(run: $0, home: home) }, now: now)
                runs += folded.map { r in var r = TaskCompaction.compact(r, now: now); r.warning = feed.run(r.id)?.warning; return r }
            }
        } else {
            runs = TaskFold.foldCalibrated(TaskJournal.readAll(home: home, modifiedSince: since), now: now).map { TaskCompaction.compact($0, now: now) }
        }
        runs = runs.filter { all ? $0.updatedAt >= since : $0.isActive(now: now) }
        return Loaded(runs: runs.sortedForDisplay(), live: live)
    }

    /// One run, cheaply: the live file's copy if current, else a fold of just its events.
    func run(_ id: String, now: Date) -> TaskRun? { loadRun(id, now: now).runs.first }

    /// One run, and whether a live app wrote `tasks.json`, from a single read of that file.
    func loadRun(_ id: String, now: Date) -> Loaded {
        let feed = TasksFile.read(from: TasksFile.url(home: home))
        let live = feed.map(TasksFile.writerIsAlive) ?? false
        if let feed, live, let r = feed.run(id), !TaskJournal.modified(run: id, home: home, since: feed.generatedAt) {
            return Loaded(runs: [r], live: live)
        }
        let events = TaskJournal.read(run: id, home: home)
        let run = events.isEmpty ? nil : TaskFold.fold(events, now: now).first.map { TaskCompaction.compact($0, now: now) }
        return Loaded(runs: run.map { [$0] } ?? [], live: live)
    }

    /// Whether a live app wrote `tasks.json`.
    var live: Bool { TasksFile.read(from: TasksFile.url(home: home)).map(TasksFile.writerIsAlive) ?? false }
}

/// Blocks (no CPU) until a task file changes: the Darwin notification writers post, a new file in
/// the event directories, a write to a watched run's files, a new `tasks.json`, or the timeout.
enum TaskWatch {
    static func wait(home: URL, runs: [String], timeout: TimeInterval) {
        let kq = kqueue()
        // Out of descriptors: callers loop on this, so wait a moment instead of spinning.
        guard kq >= 0 else { Thread.sleep(forTimeInterval: min(max(0, timeout), 1)); return }
        defer { close(kq) }
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        func watch(_ path: String, _ flags: Int32) {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            fds.append(fd)
            var ev = kevent(ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: UInt32(flags), data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }
        let dirFlags = NOTE_WRITE | NOTE_RENAME | NOTE_DELETE
        watch(home.path, dirFlags)
        watch(TaskJournal.directory(home: home).path, dirFlags)
        for s in TaskJournal.Stream.allCases {
            watch(TaskJournal.directory(s, home: home).path, dirFlags)
            for r in runs { watch(TaskJournal.url(run: r, stream: s, home: home).path, NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME) }
        }
        var token: Int32 = 0
        var nfd: Int32 = -1
        if notify_register_file_descriptor(TaskJournal.notification, &nfd, 0, &token) == NOTIFY_STATUS_OK {
            var ev = kevent(ident: UInt(nfd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }
        defer { if nfd >= 0 { notify_cancel(token) } }
        let left = max(0, timeout)
        var ts = timespec(tv_sec: Int(left), tv_nsec: Int((left - floor(left)) * 1e9))
        var out = kevent()
        _ = kevent(kq, nil, 0, &out, 1, &ts)
    }
}
