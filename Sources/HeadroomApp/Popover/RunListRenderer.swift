import AppKit
import HeadroomKit
import HeadroomPresent

/// The Runs tab's list, in the style Settings picks (Ledger, Two-line, Fill rows). Every line
/// opens the run's own page (`.openRun`).
@MainActor
enum RunListRenderer {
    /// Live runs (what needs you first), then the last day's finished ones. `showFinished` opens
    /// Two-line's folded finished line. Returns the height.
    @discardableResult
    static func drawPage(_ page: RunsPageModel, style: RunsListStyle, showFinished: Bool = false, origin: CGPoint, width: CGFloat, theme t: Theme,
                         ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        if page.isEmpty { return RunCardRenderer.drawEmpty(origin: origin, width: width, theme: t, ctx: ctx, out: out) }
        return 0 // Drawn by the list workstream.
    }

    // MARK: Pieces

    /// The provider's tile with the state as a dot on its corner, as an app badge sits.
    static func drawTile(_ c: RunCardModel, center: CGPoint, tone: NSColor, theme t: Theme, ctx: CGContext) {
        let rect = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
        if let p = c.provider {
            BrandMark.drawTile(p, in: rect, ctx: ctx)
        } else {
            ctx.fill(rounded(rect, 5.5), t.chipFill)
            RunCardRenderer.drawGlyph(c.glyph, color: tone, center: center, size: 10, ctx: ctx)
            return
        }
        let dot = CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 9, height: 9)
        ctx.fill(CGPath(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5), transform: nil), t.cardSolid)
        ctx.withState {
            if c.tone != .quiet && c.tone != .neutral { ctx.setShadow(offset: .zero, blur: 5, color: tone.fade(0.8).cgColor) }
            ctx.fill(CGPath(ellipseIn: dot, transform: nil), tone)
        }
    }

    /// The task map at line height: the meter's recessed track, a cell per task (lit, part-lit or
    /// empty in the map's colours); five cells when there's no map.
    static func drawMiniMeter(_ c: RunCardModel, rect: CGRect, theme t: Theme, ctx: CGContext) {
        let track = rounded(rect, rect.height / 2)
        ctx.fill(track, t.meterTrack)
        if t.isDark { ctx.innerStroke(track, t.meterTrackBorder, width: 0.5) }
        let inner = rect.insetBy(dx: 2, dy: 2)
        let cells: [(weight: Double, fill: Double, tone: RunTone, failed: Bool)]
        if !c.segments.isEmpty {
            cells = c.segments.map { ($0.weight, $0.fill, $0.tone, $0.failed) }
        } else {
            let f = min(max(c.hero?.fraction ?? 0, 0), 1)
            cells = (0..<5).map { i in (0.2, min(max(f * 5 - Double(i), 0), 1), c.tone == .warn ? .warn : .progress, false) }
        }
        let n = cells.count
        let gap: CGFloat = n > 12 ? 1 : 1.5, minW: CGFloat = 1.5
        let avail = inner.width - gap * CGFloat(n - 1)
        let spare = max(0, avail - minW * CGFloat(n))
        let total = max(cells.reduce(0) { $0 + $1.weight }, 1e-9)
        var x = inner.minX
        for (i, cell) in cells.enumerated() {
            let bw = avail > minW * CGFloat(n) ? minW + CGFloat(cell.weight / total) * spare : avail / CGFloat(n)
            let b = CGRect(x: x, y: inner.minY, width: bw, height: inner.height)
            let shape = rounded(b, left: i == 0 ? inner.height / 2 : 1, right: i == n - 1 ? inner.height / 2 : 1)
            ctx.fill(shape, t.meterEmpty)
            let colors: PacingColors = switch cell.tone {
            case .alert: t.pacing(.veryTight)
            case .warn: t.pacing(.tight)
            default: t.pacing(.plenty)
            }
            if cell.failed {
                ctx.fill(shape, RunCardRenderer.failure(t).fade(0.7))
            } else if cell.fill > 0, cell.tone != .quiet {
                ctx.withState {
                    ctx.addPath(shape); ctx.clip()
                    if cell.fill < 1 { ctx.fill(CGPath(rect: b, transform: nil), colors.bottom.fade(t.isDark ? 0.24 : 0.18)) }
                    ctx.fillVertical(CGPath(rect: CGRect(x: b.minX, y: b.minY, width: max(b.width * CGFloat(cell.fill), 1.5), height: b.height), transform: nil),
                                     colors.top, colors.bottom)
                }
            }
            x += bw + gap
        }
    }

    /// What the line leaves out, on hover.
    static func tooltip(_ c: RunCardModel) -> String {
        var parts = [c.title, c.stateText]
        if let label = c.hero?.label { parts.append(label) }
        if let caption = c.hero?.sideCaption, c.live { parts.append(caption) }
        parts.append(c.subtitle)
        return parts.joined(separator: " · ")
    }
}
