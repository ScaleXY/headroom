import Foundation

/// The append-only event files under `<home>/tasks/`: `journal/<run>.jsonl` for what agents,
/// hooks and people declare, `observed/<run>.jsonl` for what the app reads from harness
/// transcripts. Directories are 0700, files 0600.
public enum TaskJournal {
    /// Darwin notification posted after appending, so watchers fold again.
    public static let notification = "com.scalexy.headroom.tasks"

    public enum Stream: String, CaseIterable, Sendable {
        case journal, observed
    }

    public static func directory(home: URL) -> URL { home.appendingPathComponent("tasks", isDirectory: true) }

    public static func directory(_ stream: Stream, home: URL) -> URL {
        directory(home: home).appendingPathComponent(stream.rawValue, isDirectory: true)
    }

    public static func url(run: String, stream: Stream, home: URL) -> URL {
        directory(stream, home: home).appendingPathComponent("\(run).jsonl")
    }

    public struct BadRunID: Error { public var run: String }

    /// One JSON object and a newline.
    public static func line(_ e: TaskEvent) throws -> Data {
        var data = try encoder().encode(e)
        data.append(0x0A)
        return data
    }

    /// An observed file is compacted each time it grows past another multiple of this.
    public static let compactEvery = 512 * 1024

    /// Appends each event to its run's file as a single `write` on an `O_APPEND` descriptor, so
    /// concurrent writers never interleave within a line. An observed file that grows past another
    /// `compactEvery` bytes is compacted (`compactObserved`).
    public static func append(_ events: [TaskEvent], stream: Stream, home: URL) throws {
        let dir = directory(stream, home: home)
        try makeDirectory(directory(home: home))
        try makeDirectory(dir)
        var grown: Set<String> = []
        for e in events {
            guard TaskRunID.sanitize(e.run) == e.run else { throw BadRunID(run: e.run) }
            let bytes = try line(e)
            let fd = open(url(run: e.run, stream: stream, home: home).path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var st = stat()
            let before = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if stream == .observed, (before + written) / compactEvery > before / compactEvery { grown.insert(e.run) }
        }
        for run in grown.sorted() { compactObserved(run: run, home: home) }
    }

    /// Rewrites a run's observed file without the activity lines that change nothing the fold
    /// reports: within a stretch of one attempt's activity (other attempts' activity aside, nothing
    /// else in between), a line whose neighbours are within `TaskFold.workingGap` of each other,
    /// older than `TaskFold.recentLookback` plus an hour before the run's last event. Folding before
    /// and after gives the same runs. Written beside and renamed over, so readers see one or the
    /// other. The observer is the file's only writer. Returns how many lines went.
    @discardableResult
    public static func compactObserved(run: String, home: URL) -> Int {
        let file = url(run: run, stream: .observed, home: home)
        guard let data = try? Data(contentsOf: file) else { return 0 }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let d = decoder()
        let observed = lines.map { try? d.decode(TaskEvent.self, from: Data($0)) }
        let journal = (try? Data(contentsOf: url(run: run, stream: .journal, home: home))).map(decode) ?? []
        let drop = TaskCompaction.droppableActivity(journal: journal, observed: observed)
        guard !drop.isEmpty else { return 0 }
        var out = Data(capacity: data.count)
        for (i, l) in lines.enumerated() where !drop.contains(i) {
            out.append(contentsOf: l)
            if i < lines.count - 1 { out.append(0x0A) }
        }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(run).jsonl.compact-\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return 0
        }
        return drop.count
    }

    static func makeDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Every line that decodes. Blank, torn, malformed and unknown-op lines are skipped one by one.
    public static func decode(_ data: Data) -> [TaskEvent] {
        let d = decoder()
        return data.split(separator: 0x0A).compactMap { try? d.decode(TaskEvent.self, from: Data($0)) }
    }

    /// One run's events: the journal, then the observed file (the fold keeps that order for ties).
    public static func read(run: String, home: URL) -> [TaskEvent] {
        Stream.allCases.flatMap { s in (try? Data(contentsOf: url(run: run, stream: s, home: home))).map(decode) ?? [] }
    }

    /// Runs with an event file, optionally only those written to since `modifiedSince`.
    public static func runs(home: URL, modifiedSince: Date? = nil) -> [String] {
        var out: Set<String> = []
        for s in Stream.allCases {
            let dir = directory(s, home: home)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                if let since = modifiedSince {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                    guard let m = attrs?[.modificationDate] as? Date, m >= since else { continue }
                }
                out.insert(String(name.dropLast(6)))
            }
        }
        return out.sorted()
    }

    /// Whether either of a run's files was written to since `since`: what `runs(home:modifiedSince:)`
    /// answers for one run, without listing every run.
    public static func modified(run: String, home: URL, since: Date) -> Bool {
        Stream.allCases.contains { s in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url(run: run, stream: s, home: home).path)
            return (attrs?[.modificationDate] as? Date).map { $0 >= since } ?? false
        }
    }

    /// Every event of every run written to since `modifiedSince`.
    public static func readAll(home: URL, modifiedSince: Date? = nil) -> [TaskEvent] {
        runs(home: home, modifiedSince: modifiedSince).flatMap { read(run: $0, home: home) }
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.headroomEventString(date))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Reads milliseconds or whole seconds.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.headroomEventDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }
}

/// Reads runs' event files over and over without decoding a line twice: what `TaskJournal.read`
/// returns, for a reader that asks again on every change (the app folds live runs every few
/// seconds while agents work). The files only grow, one whole line per write, so a file that is
/// the same file and longer is read from where the last read ended; one that was replaced
/// (`compactObserved` renames a new file over it), shrank or was rewritten is read from the start.
public struct TaskJournalReader: Sendable {
    struct Key: Hashable, Sendable {
        var run: String
        var stream: TaskJournal.Stream
    }

    struct File: Sendable {
        /// Device, inode and creation time: a renamed-over file differs even at the same size.
        var identity: [Int64]
        var size = 0
        var modified: [Int] = []
        /// Bytes decoded into `events`: up to and including the last newline read.
        var consumed = 0
        var events: [TaskEvent] = []
        /// What follows the last newline, if it decodes. Read again next time.
        var tail: [TaskEvent] = []
    }

    private var files: [Key: File] = [:]

    public init() {}

    /// One run's events: the journal, then the observed file, exactly as `TaskJournal.read`.
    public mutating func read(run: String, home: URL) -> [TaskEvent] {
        TaskJournal.Stream.allCases.flatMap { read(Key(run: run, stream: $0), path: TaskJournal.url(run: run, stream: $0, home: home).path) }
    }

    /// Drops what is held for every other run.
    public mutating func keep(only runs: Set<String>) {
        files = files.filter { runs.contains($0.key.run) }
    }

    private mutating func read(_ key: Key, path: String) -> [TaskEvent] {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { files[key] = nil; return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { files[key] = nil; return [] }
        let identity = [Int64(st.st_dev), Int64(bitPattern: UInt64(st.st_ino)), Int64(st.st_birthtimespec.tv_sec), Int64(st.st_birthtimespec.tv_nsec)]
        let modified = [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec)]
        var size = Int(st.st_size)
        if let f = files[key], f.identity == identity, f.size == size, f.modified == modified { return f.events + f.tail }
        // The same file, longer: the lines already read are still its first lines.
        var f = files[key].flatMap { $0.identity == identity && $0.size < size ? $0 : nil } ?? File(identity: identity)
        let want = size - f.consumed
        var chunk = Data(count: want)
        let got = want == 0 ? 0 : chunk.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var n = 0
            while n < want {
                let r = pread(fd, base + n, want - n, off_t(f.consumed + n))
                if r < 0 && errno == EINTR { continue }
                if r < 0 { return -1 }
                if r == 0 { break }
                n += r
            }
            return n
        }
        guard got >= 0 else { files[key] = nil; return [] }
        if got < want {
            chunk.count = got
            size = f.consumed + got
        }
        let d = TaskJournal.decoder()
        var rest = chunk[...]
        if let newline = chunk.lastIndex(of: 0x0A) {
            f.events += chunk[..<newline].split(separator: 0x0A).compactMap { try? d.decode(TaskEvent.self, from: Data($0)) }
            f.consumed += newline + 1
            rest = chunk[(newline + 1)...]
        }
        f.tail = rest.isEmpty ? [] : (try? d.decode(TaskEvent.self, from: Data(rest))).map { [$0] } ?? []
        f.size = size
        f.modified = modified
        files[key] = f
        return f.events + f.tail
    }
}

/// `tasks.json`, schema 1: every recent run folded, written atomically by the app for the CLI,
/// widgets and phones. Same conventions as `snapshot.json`: snake_case keys, ISO 8601 dates in
/// whole seconds, and the writer's PID so readers can tell a live file from a stale one.
public struct TasksFeed: Codable, Sendable, Hashable {
    public static let currentSchema = 1

    public var schema: Int
    public var generatedAt: Date
    public var writerPID: Int32
    public var runs: [TaskRun]

    public init(generatedAt: Date, writerPID: Int32, runs: [TaskRun]) {
        self.schema = Self.currentSchema
        self.generatedAt = generatedAt
        self.writerPID = writerPID
        self.runs = runs
    }

    public func run(_ id: String) -> TaskRun? { runs.first { $0.id == id } }

    enum CodingKeys: String, CodingKey {
        case schema, runs
        case generatedAt = "generated_at"
        case writerPID = "writer_pid"
    }
}

public enum TasksFile {
    public static func url(home: URL = SnapshotFile.directory) -> URL { home.appendingPathComponent("tasks.json") }

    public static func encoder(pretty: Bool = false) -> JSONEncoder { SnapshotFile.encoder(pretty: pretty) }
    public static func decoder() -> JSONDecoder { SnapshotFile.decoder() }

    public static func read(from url: URL) -> TasksFeed? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(TasksFeed.self, from: data)
    }

    /// Whether the process that wrote the file is still running.
    public static func writerIsAlive(_ f: TasksFeed) -> Bool {
        #if os(macOS)
        f.writerPID > 0 && kill(f.writerPID, 0) == 0
        #else
        false
        #endif
    }
}

extension ISO8601DateFormatter {
    /// Event timestamps keep milliseconds so events from two files order correctly.
    nonisolated(unsafe) public static let headroomMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
