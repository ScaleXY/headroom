import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomKit

/// Regressions from the correctness audit of the task commands.
@Suite(.serialized) struct TaskAuditTests {
    /// `--run=ID` used to fall through to the limits wait, which returned at once.
    @Test func waitTakesTheRunInEitherFlagForm() {
        let h = Home()
        h.run(["task", "start", "a"])
        #expect(h.run(["wait", "--run", "r1", "--timeout", "0s"]).0 == 2)
        let (code, out) = h.run(["wait", "--run=r1", "--timeout=0s"])
        #expect(code == 2 && out.contains("timed out"))
    }

    /// `inf` trapped in the kqueue timeout and `nan` span for ever.
    @Test func timeoutsAreFiniteAndFitATimespec() throws {
        for bad in ["inf", "nan", "infs", "nanh", "1e400", "1e400d", "-inf"] { #expect(WaitCommand.parseDuration(bad) == nil, "\(bad)") }
        try #require(WaitCommand.parseDuration("inf") == nil)
        #expect(WaitCommand.parseDuration("90s") == 90 && WaitCommand.parseDuration("2d") == 172_800 && WaitCommand.parseDuration("15") == 15)
        let huge = try #require(WaitCommand.parseDuration("1e30h"))
        #expect(huge <= Double(Int32.max))
        let h = Home()
        h.run(["task", "start", "a"])
        #expect(h.run(["wait", "--run", "r1", "--timeout", "inf"]).0 == 64)
        #expect(h.run(["wait", "--run", "r1", "--timeout", "nan"]).0 == 64)
    }

    /// `--timeout=10s` used to be ignored (six hours instead) and `--provider=codex` read as any.
    @Test func theLimitsWaitTakesFlagsWithAnEqualsSign() throws {
        let c = CLITests()
        let url = try c.write(c.snapshot(blocked: true, sessionUsed: 1))
        #expect(c.run(["wait", "--timeout", "soon"], url: url).0 == 64)
        #expect(c.run(["wait", "--timeout=soon"], url: url).0 == 64)
        #expect(c.run(["wait", "--provider=bogus"], url: url).0 == 64)
        // Claude is blocked, Codex isn't: only asking for Claude waits (and times out at once).
        #expect(c.run(["wait", "--provider=claude", "--timeout=0s"], url: url).0 == 2)
        #expect(c.run(["wait", "--provider=codex", "--timeout=0s"], url: url).0 == 0)
    }

    @Test func aStepCountAtTheEdgeOfIntIsAnErrorNotATrap() {
        #expect(throws: TaskOps.Failure.self) { try TaskOps.steps("9223372036854775807/3") }
        let h = Home()
        #expect(h.run(["task", "progress", "a", "--step", "9223372036854775807/3"]).0 == 64)
    }

    /// Callers fill lists they don't use with []: an empty `ids` beside an `id` used to be "needs id".
    @Test func mcpTakesTheIdWhenIdsIsEmpty() throws {
        let h = Home()
        let server = MCPServer(ctx: h.ctx(), snapshotURL: h.url.appendingPathComponent("snapshot.json"))
        let (text, failed) = server.call("update_task", ["action": "start", "id": "a", "ids": [String]()])
        #expect(!failed && text.contains("started a"))
        #expect(server.call("update_task", ["action": "start", "ids": [String]()]).1)
        #expect(server.call("update_task", ["action": "done", "id": "zz", "ids": ["a"]]).0.contains("a done"))
    }

    /// A run id that names nothing used to list every run instead.
    @Test func tasksRefusesARunIdThatNamesNothing() {
        let h = Home()
        h.run(["task", "start", "a"])
        #expect(h.run(["tasks", "--run", "..."]).0 == 64)
        #expect(h.run(["tasks", "--run", ""]).0 == 0) // no id given, as for the task commands
        #expect(h.run(["tasks", "--run", "r1"]).0 == 0)
    }

    /// Naming an existing task in a later plan only to nest new work under it (no title) used to
    /// replace its title with its id.
    @Test func planningUnderAnExistingTaskKeepsItsTitle() throws {
        let h = Home()
        h.run(["task", "plan"], stdin: #"{"tasks": [{"id": "api", "title": "API changes", "children": [{"id": "schema", "title": "Schema"}]}]}"#)
        let (code, out) = h.run(["task", "plan"], stdin: #"{"tasks": [{"id": "api", "children": [{"id": "schema"}, {"id": "extra"}]}]}"#)
        #expect(code == 0 && out.contains("[hr:r1:api]  api") && out.contains("[hr:r1:api/extra]  extra"))
        let r = try #require(h.fold())
        #expect(r.node("api").title == "API changes" && r.node("api/schema").title == "Schema")
        #expect(r.node("api/extra").title == "extra")
        // The same through the MCP server.
        let server = MCPServer(ctx: h.ctx(), snapshotURL: h.url.appendingPathComponent("snapshot.json"))
        let (text, failed) = server.call("plan_tasks", ["tasks": [["id": "api", "children": [["id": "more"]]]]])
        #expect(!failed && text.contains("[hr:r1:api/more]  more"))
        #expect(h.fold()?.node("api").title == "API changes" && h.fold()?.node("api/more").title == "more")
    }

    @Test func theTaskHelpListsEveryFlagFailTakes() {
        #expect(TaskCommand.help.contains("fail ID [ID …] --reason TEXT [--instead NEW] [--force]"))
    }

    /// JSON that parses but isn't a request object is an invalid request, not a parse error.
    @Test func mcpTellsBadJSONFromABadRequest() throws {
        let server = MCPServer(ctx: Home().ctx(), snapshotURL: URL(fileURLWithPath: "/nonexistent/snapshot.json"))
        func code(_ line: String) throws -> Int? {
            let reply = try #require(server.handle(line))
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            #expect(obj["id"] is NSNull)
            return (obj["error"] as? [String: Any])?["code"] as? Int
        }
        #expect(try code("{not json") == -32700)
        #expect(try code("[]") == -32600)
        #expect(try code(#"[{"jsonrpc": "2.0", "id": 1, "method": "ping"}]"#) == -32600)
    }
}
