import AppKit
import HeadroomKit
import HeadroomPresent

/// Activity's summary card (redesign §5): the API value of the range across the enabled
/// providers, the "Include cached reads" switch, and the split between Claude and Codex in 20
/// meter cells.
@MainActor
enum SummaryCardRenderer {
    static let padTop: CGFloat = 13, padX: CGFloat = 14, padBottom: CGFloat = 12

    @discardableResult
    static func draw(_ m: ActivitySummaryModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        let heroH: CGFloat = 34.4, labelTop: CGFloat = 7, labelH: CGFloat = 14.4
        var h = padTop + 15 + 10 + heroH + labelTop + labelH
        if m.showsSplit { h += 13 + 10 + 7 + 16 }
        h += padBottom
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: nil, theme: theme, ctx: ctx)
        var y = origin.y + padTop

        // Eyebrow and the switch.
        Text(m.eyebrow.uppercased(), F.sf(9, 650), theme.muted, kern: 1.08).draw(x: x0, capCenter: y + 7.5, in: ctx)
        drawSwitch(on: m.includesCachedReads, right: x0 + w, y: y, theme: theme, ctx: ctx, out: out)
        y += 15 + 10

        // Hero: dollars with the cents small, the tokens on the right.
        let money = NumberFormat.dollars(micros: m.micros, style: .precise)
        let (whole, cents) = split(money)
        let bigFont = F.sf(40, 700, tabular: true)
        let b = baseline(top: y, font: bigFont, lineHeight: heroH)
        let big = Text(whole, bigFont, theme.ink, kern: -1.8)
        big.draw(x: x0 - 1, baseline: b, in: ctx)
        if let cents { Text(cents, F.sf(20, 650, tabular: true), theme.ink.fade(0.55), kern: -0.4).draw(x: x0 - 1 + big.width + 1, baseline: b, in: ctx) }
        let labelFont = F.sf(12, 500)
        Text("what this would cost at API rates", labelFont, theme.muted)
            .draw(x: x0, baseline: baseline(top: y + heroH + labelTop, font: labelFont, lineHeight: labelH), in: ctx)
        // Right block, its bottom on the label's: 18 pt tokens over the caption.
        let bottom = y + heroH + labelTop + labelH
        let capFont = F.sf(11.5, 500)
        let capTop = bottom - 15.5
        Text(m.tokensCaption, capFont, theme.muted).draw(x: x0 + w, baseline: baseline(top: capTop, font: capFont, lineHeight: 15.5), align: .right, in: ctx)
        let tokFont = F.sf(18, 700, tabular: true)
        Text(NumberFormat.tokens(m.tokens), tokFont, theme.ink, kern: -0.36)
            .draw(x: x0 + w, baseline: baseline(top: capTop - 18.9, font: tokFont, lineHeight: 18.9), align: .right, in: ctx)
        y = bottom

        guard m.showsSplit else { return h }
        // The split: 20 cells, the first provider's share in its tone, the rest in the other's.
        y += 13
        let n = ActivitySummaryModel.splitCells, gap: CGFloat = 2
        let k = m.leadingCells(n)
        let cellW = (w - gap * CGFloat(n - 1)) / CGFloat(n)
        let a = m.slices[0].provider, z = m.slices[m.slices.count - 1].provider
        for i in 0..<n {
            let r = CGRect(x: x0 + CGFloat(i) * (cellW + gap), y: y, width: cellW, height: 10)
            let shape = rounded(r, left: i == 0 ? 5 : 2.5, right: i == n - 1 ? 5 : 2.5)
            ctx.fill(shape, theme.providerTone(i < k ? a : z, 0.92))
        }
        for (j, slice) in [m.slices[0], m.slices[m.slices.count - 1]].enumerated() {
            let from = j == 0 ? 0 : k, to = j == 0 ? k : n
            guard to > from else { continue }
            out?.add(CGRect(x: x0 + CGFloat(from) * (cellW + gap), y: y - 3, width: CGFloat(to - from) * (cellW + gap) - gap, height: 16),
                     tooltip: "\(slice.provider.displayName) · \(NumberFormat.dollars(micros: slice.micros, style: .precise)) · \(NumberFormat.percent(slice.share)) of the API value")
        }
        y += 10 + 7

        // Legend: swatch, tile, name, dollars and share; the first on the left, the last on the right.
        for (j, slice) in [m.slices[0], m.slices[m.slices.count - 1]].enumerated() {
            let name = Text("\(slice.provider.displayName) \(NumberFormat.dollars(micros: slice.micros, style: .precise))", F.sf(11.5, 600, tabular: true), theme.ink)
            let pct = Text(" \(Int((slice.share * 100).rounded()))%", F.sf(11.5, 500, tabular: true), theme.ink.fade(0.55))
            let itemW = 7 + 6 + 16 + 6 + name.width + pct.width
            let x = j == 0 ? x0 : x0 + w - itemW
            let mid = y + 8
            ctx.fill(rounded(CGRect(x: x, y: mid - 3.5, width: 7, height: 7), 2), theme.providerTone(slice.provider, 0.92))
            BrandMark.drawTile(slice.provider, in: CGRect(x: x + 13, y: mid - 8, width: 16, height: 16), theme: theme, ctx: ctx)
            name.draw(x: x + 35, capCenter: mid, in: ctx)
            pct.draw(x: x + 35 + name.width, capCenter: mid, in: ctx)
        }
        return h
    }

    /// "$218.19" → ("$218", ".19"); amounts without cents ("$12.3K") stay whole.
    static func split(_ money: String) -> (String, String?) {
        guard let dot = money.lastIndex(of: "."), money.distance(from: dot, to: money.endIndex) == 3,
              money[money.index(after: dot)...].allSatisfy(\.isNumber) else { return (money, nil) }
        return (String(money[..<dot]), String(money[dot...]))
    }

    /// "Include cached reads" and its switch, right-aligned at `right`, 15 pt tall from `y`. On, it's
    /// drawn in Headroom ink (not green).
    static func drawSwitch(on: Bool, right: CGFloat, y: CGFloat, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        let track = CGRect(x: right - 26, y: y, width: 26, height: 15)
        let trackColor: NSColor = on ? (theme.isDark ? rgb(0xECEDF1) : rgb(0x2A2C31)) : (theme.isDark ? white(0.16) : black(0.14))
        ctx.fill(rounded(track, 7.5), trackColor)
        let knob = CGRect(x: track.minX + (on ? 13 : 2), y: track.minY + 2, width: 11, height: 11)
        let knobPath = CGMutablePath(); knobPath.addEllipse(in: knob)
        ctx.withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: black(on ? 0.2 : 0.3).cgColor)
            ctx.fill(knobPath, on && theme.isDark ? rgb(0x131418) : .white)
        }
        let label = Text("Include cached reads", F.sf(11, 600), theme.muted)
        label.draw(x: track.minX - 7, capCenter: track.midY, align: .right, in: ctx)
        let hit = CGRect(x: track.minX - 7 - label.width - 6, y: y - 4, width: label.width + 7 + 26 + 10, height: 23)
        out?.add(hit, tooltip: on ? "Counting cached reads. Turn off to count only new tokens."
                                   : "Counting new tokens only. Turn on to count cached reads too.",
                 action: .activityMode(on ? ActivityMode.newOnly.rawValue : ActivityMode.all.rawValue), hover: 8)
    }
}
