import AppKit
import HeadroomKit
import HeadroomPresent

/// "Recent runs" at the end of the Activity tab: the last two weeks of finished runs, one line
/// each (outcome, title, when, how long, what it cost), with the totals in the header.
@MainActor
enum RecentRunsRenderer {
    static let sectionHeaderHeight: CGFloat = 30
    static let rowHeight: CGFloat = 38

    static func drawSectionHeader(_ m: RecentRunsModel, x: CGFloat, y: CGFloat, width: CGFloat, theme t: Theme, ctx: CGContext) {
        let mid = y + 14
        Text(RecentRunsModel.title, F.sf(15, 650), t.ink, kern: -0.15).draw(x: x + 3, capCenter: mid, in: ctx)
        Text(m.summary, F.sf(11.5, 500, tabular: true), t.muted).draw(x: x + width - 3, capCenter: mid, align: .right, in: ctx)
    }

    /// The list in one card. Returns its height.
    @discardableResult
    static func draw(_ m: RecentRunsModel, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let footer: CGFloat = m.more > 0 ? 26 : 0
        let h = 6 + CGFloat(m.rows.count) * rowHeight + footer + 6
        guard let ctx else { return h }
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: h)
        CardChrome.draw(rect, provider: nil, theme: t, ctx: ctx)
        let x0 = origin.x + 14, w = width - 28
        var y = origin.y + 6
        for (i, r) in m.rows.enumerated() {
            if i > 0 { ctx.fill(CGPath(rect: CGRect(x: x0 + 22, y: y, width: w - 22, height: 0.5), transform: nil), t.separator) }
            let mid = y + rowHeight / 2
            let tone = RunCardRenderer.color(r.tone, t, glyph: r.glyph)
            // The outcome in a soft disc, so a column of them reads at a glance.
            let disc = CGRect(x: x0, y: mid - 8, width: 16, height: 16)
            ctx.fill(CGPath(ellipseIn: disc, transform: nil), tone.fade(r.tone == .neutral || r.tone == .quiet ? 0.08 : 0.14))
            RunCardRenderer.drawGlyph(r.glyph, color: r.glyph == .done ? t.ink.fade(0.7) : tone, center: CGPoint(x: disc.midX, y: disc.midY), size: 9, ctx: ctx)
            // Right: cost over duration, figures aligned.
            var right = x0 + w
            let cost = r.cost.map { Text($0, F.sf(12.5, 650, tabular: true), t.ink) }
            let duration = Text(r.duration, F.sf(11, 500, tabular: true), t.muted)
            if let cost {
                cost.draw(x: right, capCenter: mid - 7, align: .right, in: ctx)
                duration.draw(x: right, capCenter: mid + 8, align: .right, in: ctx)
            } else {
                duration.draw(x: right, capCenter: mid, align: .right, in: ctx)
            }
            right -= max(cost?.width ?? 0, duration.width) + 12
            let tx = x0 + 26
            RunCardRenderer.fit(r.title, F.sf(12.5, 600), t.ink, width: right - tx, kern: -0.05).draw(x: tx, capCenter: mid - 7, in: ctx)
            let sub = r.glyph == .done ? r.when : r.when + " · " + r.outcome.lowercased()
            RunCardRenderer.fit(sub, F.sf(11, 500), t.muted, width: right - tx).draw(x: tx, capCenter: mid + 8, in: ctx)
            out?.add(CGRect(x: origin.x, y: y, width: width, height: rowHeight), tooltip: "\(r.title): \(r.outcome), took \(r.duration)")
            y += rowHeight
        }
        if m.more > 0 {
            ctx.fill(CGPath(rect: CGRect(x: x0, y: y, width: w, height: 0.5), transform: nil), t.separator)
            Text("+ \(m.more) more in the last two weeks", F.sf(11.5, 500), t.muted).draw(x: x0 + 26, capCenter: y + 13, in: ctx)
        }
        return h
    }
}
