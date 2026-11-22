import Foundation
import HeadroomKit
import HeadroomSync
import Testing

@MainActor @Suite struct RunMetadataSyncTests {
    @Test func sessionTitlesSyncWithNamesAndGitFieldsStayLocal() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let title = String(repeating: "a", count: 130)
        var run = TaskRun(id: "run1", title: "run1", project: "private-project", startedAt: now, updatedAt: now,
                          state: .running, sessionTitle: title, repo: "private-org/private-repo", branch: "private-branch")
        let named = try #require(RunSummaryBuilder.summaries([run], includeNames: true, now: now)?.first)
        let anonymous = try #require(RunSummaryBuilder.summaries([run], includeNames: false, now: now)?.first)
        #expect(named.title == String(title.prefix(120)) && anonymous.title == nil)
        for summary in [named, anonymous] {
            let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
            for value in [run.project!, run.repo!, run.branch!] {
                #expect(!json.contains(value))
            }
        }

        run.title = "Declared title"
        #expect(RunSummaryBuilder.summaries([run], includeNames: true, now: now)?.first?.title == "Declared title")
    }
}
