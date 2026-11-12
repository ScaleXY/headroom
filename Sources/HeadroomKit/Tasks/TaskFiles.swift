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

    /// Appends each event to its run's file as a single `write` on an `O_APPEND` descriptor, so
    /// concurrent writers never interleave within a line.
    public static func append(_ events: [TaskEvent], stream: Stream, home: URL) throws {
        let dir = directory(stream, home: home)
        try makeDirectory(directory(home: home))
        try makeDirectory(dir)
        for e in events {
            guard TaskRunID.sanitize(e.run) == e.run else { throw BadRunID(run: e.run) }
            let bytes = try line(e)
            let fd = open(url(run: e.run, stream: stream, home: home).path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
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

    /// Every event of every run written to since `modifiedSince`.
    public static func readAll(home: URL, modifiedSince: Date? = nil) -> [TaskEvent] {
        runs(home: home, modifiedSince: modifiedSince).flatMap { read(run: $0, home: home) }
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.headroomMillis.string(from: date))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Reads milliseconds or whole seconds.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.headroomMillis.date(from: s) ?? ISO8601DateFormatter.headroom.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
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
