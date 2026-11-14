import Foundation
import Testing
@testable import HeadroomKit

/// The incremental reader must answer exactly as a full read does, whatever happened to the files.
@Suite struct TaskJournalReaderTests {
    final class Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-reader-\(UUID().uuidString)", isDirectory: true)
        let t0 = Date(timeIntervalSince1970: 1_794_477_845.120)
        deinit { try? FileManager.default.removeItem(at: url) }

        func add(_ s: TimeInterval, _ op: TaskEvent.Op, run: String = "r1", stream: TaskJournal.Stream = .journal) throws {
            try TaskJournal.append([TaskEvent(at: t0.addingTimeInterval(s), run: run, source: .agent, op: op)], stream: stream, home: url)
        }

        func file(_ stream: TaskJournal.Stream, run: String = "r1") -> URL { TaskJournal.url(run: run, stream: stream, home: url) }

        func write(_ text: String, to stream: TaskJournal.Stream) throws {
            let h = try FileHandle(forWritingTo: file(stream))
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
            try h.close()
        }
    }

    private func same(_ reader: inout TaskJournalReader, _ h: Home, run: String = "r1") -> Bool {
        reader.read(run: run, home: h.url) == TaskJournal.read(run: run, home: h.url)
    }

    @Test func appendsAreReadWithoutLosingOrRepeatingALine() throws {
        let h = Home()
        var reader = TaskJournalReader()
        #expect(reader.read(run: "r1", home: h.url).isEmpty)
        try h.add(0, .add(.init(id: "a", title: "A")))
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 1)
        for i in 1...40 {
            try h.add(Double(i), .progress(task: "a", step: i, total: 40, fraction: nil, note: "step \(i)"))
            if i % 3 == 0 { try h.add(Double(i) + 0.5, .activity(attempt: "agent:x", at: nil, tokens: Int64(i) * 100), stream: .observed) }
            #expect(same(&reader, h))
        }
        #expect(reader.read(run: "r1", home: h.url).count == 54)
        // Asked again with nothing new: the same events.
        #expect(same(&reader, h))
    }

    @Test func aLineStillBeingWrittenIsNotCountedTwice() throws {
        let h = Home()
        var reader = TaskJournalReader()
        try h.add(0, .add(.init(id: "a")))
        _ = reader.read(run: "r1", home: h.url)
        let line = String(decoding: try TaskJournal.line(TaskEvent(at: h.t0.addingTimeInterval(5), run: "r1", source: .agent, op: .start(task: "a"))), as: UTF8.self)
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        // Half a line: skipped, as a full read skips it.
        try h.write(String(line[..<half]), to: .journal)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 1)
        // The rest without its newline: a whole line, read by both.
        try h.write(String(line[half...].dropLast()), to: .journal)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 2)
        // The newline, then more: still two, then three.
        try h.write("\n", to: .journal)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 2)
        try h.add(6, .done(task: "a", evidence: nil))
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 3)
        // Junk and blank lines are skipped one by one.
        try h.write("not json\n\n{\"op\":\"nope\",\"run\":\"r1\",\"ts\":\"2026-11-12T10:00:00Z\"}\n", to: .journal)
        try h.add(7, .end)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 4)
    }

    @Test func aReplacedShrunkOrDeletedFileIsReadAfresh() throws {
        let h = Home()
        var reader = TaskJournalReader()
        try h.add(0, .add(.init(id: "a")))
        for i in 0..<30 { try h.add(Double(i), .activity(attempt: "agent:x", at: nil, tokens: Int64(i)), stream: .observed) }
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 31)

        // Renamed over, as compaction does, by a longer file with other content.
        let observed = h.file(.observed)
        let kept = try String(contentsOf: observed, encoding: .utf8).split(separator: "\n").suffix(3).joined(separator: "\n") + "\n"
        let other = observed.deletingLastPathComponent().appendingPathComponent(".swap")
        try Data(String(repeating: kept, count: 20).utf8).write(to: other)
        #expect(rename(other.path, observed.path) == 0)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 61)

        // Truncated in place.
        try Data(kept.utf8).write(to: observed, options: [])
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 4)

        // Rewritten in place at the same length.
        let flipped = kept.replacingOccurrences(of: "agent:x", with: "agent:y")
        try FileHandle(forWritingTo: observed).write(contentsOf: Data(flipped.utf8))
        #expect(flipped.utf8.count == kept.utf8.count && same(&reader, h))

        try FileManager.default.removeItem(at: observed)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 1)
        try h.add(40, .activity(attempt: "agent:x", at: nil, tokens: 1), stream: .observed)
        #expect(same(&reader, h) && reader.read(run: "r1", home: h.url).count == 2)
    }

    /// A long observed run written in batches, compacted on the way as the app does, read after
    /// every batch: the reader never differs from a full read, and holds only the runs it is told to.
    @Test func compactionAndForgottenRunsReadTheSame() throws {
        let h = Home()
        var reader = TaskJournalReader()
        let (journal, observed) = TaskJournalCompactionTests.stream(seed: 7, hours: 16)
        try TaskJournal.append(journal, stream: .journal, home: h.url)
        try h.add(0, .add(.init(id: "b")), run: "r2")
        let file = h.file(.observed)
        var inodes: Set<UInt64> = []
        var i = 0
        while i < observed.count {
            try TaskJournal.append(Array(observed[i..<min(i + 50, observed.count)]), stream: .observed, home: h.url)
            i += 50
            // A full read each time is the slow part: every eighth batch, and the last.
            if i % 400 == 0 || i >= observed.count { #expect(same(&reader, h)) }
            inodes.insert((try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64) ?? 0)
        }
        // Compaction replaced the file on the way.
        #expect(inodes.count > 1)
        #expect(TaskJournal.compactObserved(run: "r1", home: h.url) > 0 && same(&reader, h))
        #expect(same(&reader, h, run: "r2"))
        reader.keep(only: ["r2"])
        try h.add(90000, .done(task: "b", evidence: nil), run: "r2")
        #expect(same(&reader, h) && same(&reader, h, run: "r2"))
    }
}
