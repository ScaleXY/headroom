import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

private func withBytes<T>(_ text: String, _ body: (UnsafePointer<UInt8>, Int) -> T) -> T {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBufferPointer { body($0.baseAddress!, $0.count) }
}

/// Numbers no harness writes, but a damaged or hand-edited log can hold: none of them may trap.
@Suite struct HostileInputTests {
    @Test func integersOutsideInt64AreNilNotATrap() {
        func int(_ number: String) -> Int64? {
            withBytes(number) { p, n in JSONScan(p, n).int(ByteSpan(start: 0, end: n)) }
        }
        #expect(int("1e30") == nil)
        #expect(int("1e999") == nil)
        #expect(int("-1.5e300") == nil)
        #expect(int("12.0") == 12)
        #expect(int("1.5e2") == 150)
        #expect(int("-9223372036854775808") == .min)
    }

    @Test func claudeUsageWithAbsurdCountsDoesNotOverflow() {
        let line = #"{"type":"assistant","timestamp":"2026-10-17T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"m","usage":{"input_tokens":9223372036854775807,"cache_creation_input_tokens":9223372036854775807,"cache_read_input_tokens":9223372036854775807,"output_tokens":9223372036854775807,"cache_creation":{"ephemeral_5m_input_tokens":9223372036854775807,"ephemeral_1h_input_tokens":9223372036854775807}}}}"#
        let event = withBytes(line) { p, n in ClaudeLogParser.parse(p, n, fallbackKey: "k") }
        #expect(event != nil)
        #expect(event?.tokens.newInput == Int64(UInt32.max))
        #expect(event?.tokens.output == Int64(UInt32.max))
    }

    @Test func codexUsageWithAbsurdCountsDoesNotOverflow() {
        let line = #"{"timestamp":"2026-10-17T10:00:00.000Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":-9223372036854775807,"cached_input_tokens":9223372036854775807,"cache_write_input_tokens":9223372036854775807,"output_tokens":7}}}"#
        var state = CodexFileState()
        let parsed = withBytes(line) { p, n in CodexLogParser.parse(p, n, state: &state, fileKey: "f") }
        guard case .event(let event) = parsed else {
            Issue.record("expected an event")
            return
        }
        #expect(event.tokens.newInput == 0)
        #expect(event.tokens.output == 7)
    }

    @Test func codexTranscriptTotalsDoNotOverflow() {
        let line = #"{"timestamp":"2026-10-17T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9223372036854775807,"cached_input_tokens":-9223372036854775807,"output_tokens":9223372036854775807}}}}"#
        let parsed = withBytes(line) { p, n in CodexTranscript.parse(p, n, wantText: false, pendingCall: nil) }
        #expect(parsed != nil)
    }
}

@Suite struct ChildProcessTests {
    /// The `security` output holds every token in the Keychain item: it must be wiped where it
    /// sits, not in a copy.
    @Test func keychainOutputIsZeroedInPlace() async throws {
        final class OneShot: ProcessRunning, @unchecked Sendable {
            let buffer: UnsafeMutableRawBufferPointer
            init(_ json: Data) {
                buffer = .allocate(byteCount: json.count, alignment: 1)
                json.copyBytes(to: buffer)
            }
            deinit { buffer.deallocate() }
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) async throws -> ProcessResult {
                ProcessResult(status: 0, stdout: Data(bytesNoCopy: buffer.baseAddress!, count: buffer.count, deallocator: .none))
            }
        }
        let runner = OneShot(keychainJSON(expiresMs: 1_800_000_000_000))
        let creds = try await ClaudeCredentialReader(runner: runner).read()
        #expect(creds.accessToken == "tok-123")
        #expect(runner.buffer.allSatisfy { $0 == 0 })
    }

    /// A background job the child leaves behind (a daemon started from the login shell's profile)
    /// keeps the pipe open; the run must end when the child does, not when that job does.
    @Test func runEndsWithTheChildNotWithWhatItLeftBehind() async throws {
        // The job left behind sleeps a minute, far longer than a busy CI machine can hold the run
        // up: waiting for it reads as a minute, not as a few slow seconds.
        let t0 = Date()
        let result = try await SystemProcessRunner().run("/bin/sh", arguments: ["-c", "sleep 60 & echo $!"], currentDirectory: nil, timeout: 45)
        let took = Date().timeIntervalSince(t0)
        let job = pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        if let job { kill(job, SIGKILL) }
        #expect(job != nil)
        #expect(took < 30)
        #expect(result.status == 0 && !result.timedOut)
    }

    /// Two reads that both find the token expired must start Claude Code once: finding the CLI
    /// suspends between the throttle's check and its stamp.
    @Test func overlappingRefreshesSpawnOnce() async {
        let runner = FakeRunner(["/bin/claude": ProcessResult(status: 0, stdout: Data("ok".utf8))])
        let refresher = ClaudeRefresher(runner: runner, clock: FakeClock(Date(timeIntervalSince1970: 1_800_000_000)), locateClaude: {
            try? await Task.sleep(for: .milliseconds(50))
            return "/bin/claude"
        })
        async let a = refresher.refreshIfAllowed(popoverOpen: true)
        async let b = refresher.refreshIfAllowed(popoverOpen: true)
        let outcomes = await [a, b]
        #expect(runner.recorded.count == 1)
        #expect(outcomes.contains(.throttled))
    }

    /// A Codex that exits at once (a broken install) must fail the read, not kill Headroom with
    /// SIGPIPE on the next request.
    @Test func sendingToAnExitedServerThrows() async throws {
        let channel = try ProcessLineChannel(CodexLaunch(mode: .spawn, executable: "/usr/bin/true", arguments: [], workingDirectory: nil))
        #expect(try await channel.nextLine() == nil)
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { try await channel.send(CodexRequest.encode(.initialize, id: 1)) }
        await channel.close()
    }
}

@Suite struct ProcessOutputTests {
    /// More than a pipe holds (64 KB), on both streams at once, arrives whole and in order.
    @Test func largeOutputOnBothStreamsArrivesWhole() async throws {
        let script = "i=0; while [ $i -lt 4000 ]; do echo \"line $i 0123456789012345678901234567890123456789012345678901234567890123456789\"; echo \"err $i\" >&2; i=$((i+1)); done"
        let result = try await SystemProcessRunner().run("/bin/sh", arguments: ["-c", script], currentDirectory: nil, timeout: 30)
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        #expect(result.status == 0 && !result.timedOut)
        #expect(lines.count == 4000)
        #expect(lines.enumerated().allSatisfy { $0.element.hasPrefix("line \($0.offset) ") })
        #expect(String(decoding: result.stderr, as: UTF8.self).split(separator: "\n").count == 4000)
    }

    @Test func timeoutStillEndsARunawayChild() async throws {
        let result = try await SystemProcessRunner().run("/bin/sleep", arguments: ["30"], currentDirectory: nil, timeout: 0.3)
        #expect(result.timedOut)
    }
}

@Suite struct ObserverRereadTests {
    /// A sync tool or a restore replaces a transcript with a copy (a new inode): it is read again
    /// from the start, and must not count its tokens twice.
    @Test func replacedTranscriptCountsItsTokensOnce() async throws {
        let h = try ObserverHome()
        try h.write("s1.jsonl", [
            Fx.assistant(1, "s1", id: "m1", tokens: 100, [Fx.agentCall("tu1", "Survey the API", prompt: "look around")]),
            Fx.user(2, "s1", Fx.toolResult("tu1", "Async agent launched"), result: ["status": "async_launched", "agentId": "a1"]),
        ])
        let agent = [Fx.assistant(4, "s1", id: "x1", tokens: 300, [Fx.text("working")], agent: "a1")]
        try h.write("s1/subagents/agent-a1.jsonl", agent)
        let o = h.observer()
        _ = await o.scan(since: Fx.t0.addingTimeInterval(-86400))
        func tokens(_ key: String) -> Int64? {
            h.events("s1").lazy.compactMap { if case .activity(key, _, let t?) = $0.op { t } else { nil } }.last
        }
        let first = try #require(tokens("agent:a1"))
        let session = try #require(tokens("session:s1"))
        for rel in ["s1/subagents/agent-a1.jsonl", "s1.jsonl"] {
            let url = URL(fileURLWithPath: h.path(rel))
            try Data(contentsOf: url).write(to: url, options: .atomic)
        }
        h.clock.now += 120
        _ = await o.ingest(paths: [h.path("s1.jsonl"), h.path("s1/subagents/agent-a1.jsonl")])
        #expect(tokens("agent:a1") == first)
        #expect(tokens("session:s1") == session)
    }

    @Test func eventsTheJournalCouldNotTakeAreWrittenOnTheNextPass() async throws {
        let h = try ObserverHome()
        try h.write("s1.jsonl", [
            Fx.assistant(1, "s1", id: "m1", tokens: 100, [Fx.agentCall("tu1", "Survey the API", prompt: "look around")]),
            Fx.user(2, "s1", Fx.toolResult("tu1", "Async agent launched"), result: ["status": "async_launched", "agentId": "a1"]),
        ])
        try h.write("s1/subagents/agent-a1.jsonl", [Fx.assistant(4, "s1", id: "x1", tokens: 300, [Fx.text("working")], agent: "a1")])
        // A file where the observed journals' folder goes: nothing can be appended.
        let folder = TaskJournal.directory(.observed, home: h.home)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: folder)
        let o = h.observer()
        #expect(await o.scan(since: Fx.t0.addingTimeInterval(-86400)).events == 0)
        try FileManager.default.removeItem(at: folder)
        #expect(h.events("s1").isEmpty)
        // Nothing new in the transcripts: the next pass still writes what the first couldn't.
        h.clock.now += 120
        #expect(await o.ingest(paths: [h.path("s1.jsonl")]).events > 0)
        let ops = h.events("s1").map(\.op)
        #expect(ops.contains { if case .attempt(let a) = $0 { a.key == "agent:a1" } else { false } })
        #expect(ops.contains { if case .attempt(let a) = $0 { a.key == "session:s1" } else { false } })
    }
}
