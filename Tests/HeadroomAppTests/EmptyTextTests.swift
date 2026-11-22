import AppKit
import Foundation
import Testing
@testable import HeadroomApp
import HeadroomKit
import HeadroomPresent

/// Text that turns out empty (a question with no words, a task with no title) draws nothing;
/// reading its font used to raise NSRangeException in the middle of a draw.
@MainActor @Suite struct EmptyTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func emptyTextDrawsNothing() {
        let rep = renderImage(size: CGSize(width: 40, height: 20), scale: 1) { ctx in
            Text("", F.sf(12), .black).draw(x: 0, capCenter: 10, in: ctx)
            TextBlock("", F.sf(12), .black, width: 40, lineHeight: 16).draw(x: 0, top: 0, in: ctx)
        }
        #expect(rep != nil)
        #expect(Text("", F.sf(12), .black).width == 0)
    }

    @Test func aRunAskingWithoutSayingWhatStillOpens() {
        // `task wait --reason input` with no note folds to a question with no text; the task has no title either.
        let r = TaskRun(id: "r", title: "Run", startedAt: now, updatedAt: now, state: .waiting, waitReason: .input, hasDeclaredTasks: true,
                        nodes: [TaskNode(id: "a", title: "", state: .waiting, waitReason: .input, startedAt: now)],
                        question: TaskQuestion(text: "", askedAt: now))
        let card = RunsPresenter(now: now).page([r]).live[0]
        // The question block says something even when the run didn't.
        #expect(card.question?.text == RunWords.waitingForAnswer)
        for style in RunPageStyle.allCases {
            let measured = RunPageRenderer.draw(card, style: style, origin: .zero, width: 360, theme: .dark, ctx: nil)
            var drawn: CGFloat = 0
            _ = renderImage(size: CGSize(width: 400, height: 1600), scale: 1) { ctx in
                drawn = RunPageRenderer.draw(card, style: style, origin: .zero, width: 360, theme: .dark, ctx: ctx)
            }
            #expect(drawn == measured && drawn > 0, "\(style)")
        }
    }
}
