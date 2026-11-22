import AppKit
import Foundation
import Testing
@testable import HeadroomApp
import HeadroomPresent

/// The Ledger line's 30pt task meter has to show progress for any run the presenter maps
/// (up to `RunsPresenter.maxSegments` tasks), not only for the few-task ones.
@MainActor @Suite struct MiniMeterTests {
    func card(_ n: Int) -> RunCardModel {
        RunCardModel(id: "r", title: "Run", subtitle: "", stateText: "", glyph: .running, tone: .progress, live: true, declared: true, headline: "",
                     segments: (0..<n).map { _ in RunSegment(weight: 1 / Double(n), fill: 1, tone: .progress) })
    }

    /// The share of the meter's inside that is lit (the pacing blue), with every task done.
    func lit(_ n: Int) -> Double {
        let scale: CGFloat = 4
        let meter = CGRect(x: 4, y: 4, width: RunListRenderer.meterW, height: 8)
        guard let rep = renderImage(size: CGSize(width: 40, height: 16), scale: scale, { ctx in
            RunListRenderer.drawMiniMeter(self.card(n), rect: meter, theme: .dark, ctx: ctx)
        }), let data = rep.bitmapData else { return 0 }
        // The middle row of the track, clear of the rounded ends.
        let y = Int(meter.midY * scale)
        let xs = Int((meter.minX + 5) * scale)..<Int((meter.maxX - 5) * scale)
        let blue = xs.filter { x in
            let p = data + y * rep.bytesPerRow + x * 4
            return p[2] > 200 && p[3] > 200
        }
        return Double(blue.count) / Double(xs.count)
    }

    @Test func aFinishedRunFillsTheMeterHoweverManyTasks() {
        for n in [1, 5, 12, 16, 17, 24, 28, 29, 40, RunsPresenter.maxSegments] {
            #expect(lit(n) > 0.3, "\(n) tasks: \(lit(n))")
        }
    }
}

/// A finished run's Ledger line: took and cost are columns, and stay apart whatever the cost.
@MainActor @Suite struct LedgerColumnTests {
    /// How many separate stretches of ink the line has between its state icon and its chevron.
    func stretches(cost: String) -> Int {
        let scale: CGFloat = 2
        let row = CGRect(x: 0, y: 0, width: 352, height: RunListRenderer.ledgerRow)
        let card = RunCardModel(id: "r", title: "", subtitle: "", stateText: "", glyph: .done, tone: .neutral, live: false, declared: true, headline: "",
                                receipt: RunReceiptModel(duration: "1h 42m", tokens: "", cost: cost, tasks: "", tasksNote: "", time: .zero))
        guard let rep = renderImage(size: row.size, scale: scale, { ctx in
            RunListRenderer.drawLedgerFinished(card, row: row, theme: .dark, ctx: ctx)
        }), let data = rep.bitmapData else { return 0 }
        let inked = (Int(34 * scale)..<Int((row.maxX - 26) * scale)).map { x in
            (0..<rep.pixelsHigh).contains { y in (data + y * rep.bytesPerRow + x * 4)[3] > 40 }
        }
        // Ink, then at least 5pt of nothing, is one stretch.
        var count = 0, blank = Int.max
        for on in inked {
            if on { if blank >= Int(5 * scale) { count += 1 }; blank = 0 } else if blank < Int.max { blank += 1 }
        }
        return count
    }

    @Test func aLargeCostKeepsClearOfTheDuration() {
        #expect(stretches(cost: "about $1.46") == 2)
        #expect(stretches(cost: "about $123.45") == 2)
        #expect(stretches(cost: "about $1,234.56") == 2)
    }
}
