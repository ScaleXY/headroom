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
    /// under tmux and prompts, where standard input may be a pipe nobody writes to.
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

    /// Wakes `--watch`, `wait --run` and the app.
    func posted() { notify_post(TaskJournal.notification) }

    func append(_ events: [TaskEvent]) throws {
        try TaskJournal.append(events, stream: .journal, home: home)
        posted()
    }

    func error(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}

/// Run ids: `--run`, else a `RUN:` prefix on the task id, else the first harness variable set.
/// `CODEX_THREAD_ID` sits with the harness-native ids, before T3 Code's, so a command an agent
/// runs and the hooks of its harness (which see only the session id) name the same run.
enum RunResolver {
    static let variables = ["HEADROOM_RUN", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "T3CODE_THREAD_ID"]

    static func resolve(flag: String?, environment: [String: String]) -> String? {
        if let flag, !flag.isEmpty { return TaskRunID.sanitize(flag) }
        for v in variables { if let raw = environment[v], let id = TaskRunID.sanitize(raw) { return id } }
        return nil
    }

    /// The run and path for a task id that may carry a `RUN:` prefix.
    static func resolve(flag: String?, id: String, environment: [String: String]) -> (run: String, path: String)? {
        if let flag, !flag.isEmpty {
            guard let run = TaskRunID.sanitize(flag) else { return nil }
            return (run, TaskRef(id)?.path ?? id)
        }
        if let ref = TaskRef(id) { return (ref.run, ref.path) }
        return resolve(flag: nil, environment: environment).map { ($0, id) }
    }

    /// Which harness a run id came from, for the run's metadata.
    static func harness(environment: [String: String]) -> String? {
        if environment["HEADROOM_RUN"]?.isEmpty == false { return nil }
        if environment["CLAUDE_CODE_SESSION_ID"]?.isEmpty == false { return "claude-code" }
        if environment["CODEX_THREAD_ID"]?.isEmpty == false { return "codex" }
        if environment["T3CODE_THREAD_ID"]?.isEmpty == false { return "t3code" }
        return nil
    }

    static let missing = "no run id: pass --run ID, prefix the task id with RUN:, or set HEADROOM_RUN"
}

/// Flags and positionals. Valued flags always take the next argument, so notes may start with `-`.
struct Args {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    struct Bad: Error { var message: String }

    init(_ args: [String], valued: Set<String> = [], flags known: Set<String> = []) throws(Bad) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if valued.contains(a) {
                guard i + 1 < args.count else { throw Bad(message: "\(a) needs a value") }
                values[a] = args[i + 1]
                i += 2
                continue
            }
            if known.contains(a) { flags.insert(a) } else if a.hasPrefix("--") { throw Bad(message: "unknown option \(a)") } else { positional.append(a) }
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
    func run(_ id: String, now: Date) -> TaskRun? {
        if let feed = TasksFile.read(from: TasksFile.url(home: home)), TasksFile.writerIsAlive(feed), let r = feed.run(id),
           !TaskJournal.runs(home: home, modifiedSince: feed.generatedAt).contains(id) {
            return r
        }
        let events = TaskJournal.read(run: id, home: home)
        return events.isEmpty ? nil : TaskFold.fold(events, now: now).first.map { TaskCompaction.compact($0, now: now) }
    }
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
