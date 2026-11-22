import AppKit
import HeadroomKit
import HeadroomPresent

/// The Limits card's reservoir (`Reservoir`): a recessed track filled from the left to what's left
/// in the state's colors, the big number on the fill (or just past its edge when the level is low),
/// and the renewal in a frosted tag at the right end, which the fill passes under.
@MainActor
enum ReservoirRenderer {
    static let numberFont = F.sf(CGFloat(Reservoir.numberSize), 750, tabular: true)
    static let percentFont = F.sf(CGFloat(Reservoir.numberSize * Reservoir.percentScale), 700)
    static let labelFont = F.sf(CGFloat(Reservoir.labelSize), 600)
    static let numberKern: CGFloat = -2.2
    /// The gap between the digits and the raised "%" (3 pt past the digits' trailing tracking).
    static let percentGap: CGFloat = 1

    static let capsFont = F.sf(8.5, 700)
    static let capsKern: CGFloat = 0.9
    static let countFont = F.sf(17, 700, tabular: true)
    static let countKern: CGFloat = -0.3
    static let dateFont = F.sf(11, 600)

    static func color(_ c: Reservoir.Color) -> NSColor { rgb(c.hex, CGFloat(c.alpha)) }

    /// Where everything goes: the fill's width, the tag (nil without a known renewal), and the number.
    struct Layout {
        var fill: CGFloat
        var tag: CGRect?
        var placement: Reservoir.Placement
        var numberWidth: CGFloat
        var label: String
    }

    static func numberWidth(_ percentLeft: Int) -> CGFloat {
        let digits = Text("\(percentLeft)", numberFont, .black, kern: numberKern).width
        let percent = Text("%", percentFont, .black).width
        return digits + percentGap + percent
    }

    static func tagTextWidth(_ h: HeroModel) -> CGFloat? {
        guard let count = h.renewIn else { return nil }
        let caps = Text("RENEWS IN", capsFont, .black, kern: capsKern).width
        let main = Text(count, countFont, .black, kern: countKern).width
        let date = h.renewAt.map { Text($0, dateFont, .black).width } ?? 0
        return max(caps, main, date)
    }

    static func layout(_ h: HeroModel, filled: Bool, rect: CGRect) -> Layout {
        let width = Double(rect.width)
        let fill = filled ? CGFloat(Reservoir.fillWidth(percentLeft: h.percentLeft, width: width)) : 0
        var tag: CGRect? = nil
        var right = rect.maxX - CGFloat(Reservoir.outsideMinX)
        if let text = tagTextWidth(h) {
            let tw = CGFloat(Reservoir.tagWidth(textWidth: Double(text)))
            let th = CGFloat(Reservoir.tagHeight)
            let tx = rect.maxX - CGFloat(Reservoir.tagInset) - tw
            tag = CGRect(x: tx, y: rect.midY - th / 2, width: tw, height: th)
            right = tx - CGFloat(Reservoir.tagGap)
        }
        let number = numberWidth(h.percentLeft)
        let labelWidth = Text(h.label, labelFont, .black).width + 1
        let placement = Reservoir.place(fill: Double(fill), number: Double(number), label: Double(labelWidth),
                                        right: Double(right - rect.minX))
        let room = CGFloat(placement.labelRoom) - 1
        return Layout(fill: fill, tag: tag, placement: placement, numberWidth: number, label: fitted(h.label, width: room))
    }

    /// `s`, cut with an ellipsis to fit `width`.
    static func fitted(_ s: String, width: CGFloat) -> String {
        guard Text(s, labelFont, .black).width > width else { return s }
        var t = s
        while t.count > 1, Text(t + "…", labelFont, .black).width > width { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func draw(_ h: HeroModel, state: PacingState, filled: Bool, dim: Double, rect: CGRect, theme: Theme, ctx: CGContext) {
        let l = layout(h, filled: filled, rect: rect)
        let palette = Reservoir.palette(state, dark: theme.isDark)
        let track = Reservoir.track(dark: theme.isDark)
        let shape = rounded(rect, CGFloat(Reservoir.radius))
        ctx.withState {
            if dim < 1 {
                ctx.setAlpha(CGFloat(dim))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            ctx.fill(shape, color(track.fill))
            ctx.withState {
                ctx.addPath(shape)
                ctx.clip()
                if l.fill > 0 { drawFill(palette, width: l.fill, full: Reservoir.isFull(percentLeft: h.percentLeft), rect: rect, theme: theme, ctx: ctx) }
                drawNumber(h, layout: l, palette: palette, rect: rect, theme: theme, ctx: ctx)
                if let tag = l.tag { drawTag(h, rect: tag, theme: theme, ctx: ctx) }
            }
            ctx.innerStroke(shape, color(track.stroke), width: 1)
            if dim < 1 { ctx.endTransparencyLayer() }
        }
    }

    /// The level: a gradient from the deep color to the light one at the edge, its glow spilling onto
    /// the track, a sheen across the top, and a lit edge (none when full).
    static func drawFill(_ p: Reservoir.Palette, width: CGFloat, full: Bool, rect: CGRect, theme: Theme, ctx: CGContext) {
        let fillRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let path = CGPath(rect: fillRect, transform: nil)
        let deep = color(p.deep), light = color(p.light)
        ctx.glow(path, color: color(p.glow), blur: 12, base: deep)
        ctx.fillLinear(path, [deep, light], from: CGPoint(x: fillRect.minX, y: fillRect.midY), to: CGPoint(x: fillRect.maxX, y: fillRect.midY))
        let sheenEnd = fillRect.minY + fillRect.height * 0.55
        ctx.fillLinear(path, [white(0.24), white(0)], from: CGPoint(x: fillRect.minX, y: fillRect.minY), to: CGPoint(x: fillRect.minX, y: sheenEnd))
        guard !full else { return }
        let edgeW = CGFloat(Reservoir.edgeWidth), inset = CGFloat(Reservoir.edgeInset)
        let edge = rounded(CGRect(x: fillRect.maxX - edgeW, y: rect.minY + inset, width: edgeW, height: rect.height - inset * 2), 1)
        ctx.withState {
            ctx.setShadow(offset: .zero, blur: 4, color: white(0.75).cgColor)
            ctx.fill(edge, white(theme.isDark ? 0.92 : 0.85))
        }
    }

    /// The number with its raised "%" and the line under it: in the state's ink on the fill, in the
    /// state's color on the track.
    static func drawNumber(_ h: HeroModel, layout l: Layout, palette p: Reservoir.Palette, rect: CGRect, theme: Theme, ctx: CGContext) {
        let inside = l.placement.inside
        let numberColor: NSColor = inside ? color(p.ink) : (p.plainOnTrack ? theme.ink : color(p.text))
        let labelColor: NSColor = inside ? color(p.ink).fade(0.8) : theme.muted.fade(0.8)
        let x = rect.minX + CGFloat(l.placement.x)
        let base = rect.minY + rect.height / 2 + 8
        // Drawn smaller only in a squeeze between a low level and a wide tag.
        let scale = CGFloat(l.placement.scale)
        let size = CGFloat(Reservoir.numberSize) * scale
        let numFont = scale < 1 ? F.sf(size, 750, tabular: true) : numberFont
        let pctFont = scale < 1 ? F.sf(size * CGFloat(Reservoir.percentScale), 700) : percentFont
        let digits = Text("\(h.percentLeft)", numFont, numberColor, kern: numberKern * scale)
        digits.draw(x: x, baseline: base, in: ctx)
        let raise = size * 0.44
        Text("%", pctFont, numberColor.fade(0.85)).draw(x: x + digits.width + percentGap * scale, baseline: base - raise, in: ctx)
        Text(l.label, labelFont, labelColor).draw(x: x + 1, baseline: rect.minY + rect.height / 2 + 27, in: ctx)
    }

    /// The frosted renewal tag: "RENEWS IN", the countdown, and the day and time.
    static func drawTag(_ h: HeroModel, rect: CGRect, theme: Theme, ctx: CGContext) {
        let style = Reservoir.tag(dark: theme.isDark)
        let shape = rounded(rect, CGFloat(Reservoir.tagRadius))
        ctx.withState {
            // Flipped context: CG shadow offsets are in base space (y up), so negate.
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: color(style.shadow).cgColor)
            ctx.fill(shape, color(style.fill))
        }
        ctx.innerStroke(shape, color(style.stroke), width: 1)
        if let hi = style.highlight {
            ctx.fill(CGPath(rect: CGRect(x: rect.minX + 10, y: rect.minY + 0.5, width: rect.width - 20, height: 1), transform: nil), color(hi))
        }
        let tx = rect.minX + CGFloat(Reservoir.tagPadding)
        Text("RENEWS IN", capsFont, theme.muted, kern: capsKern).draw(x: tx, baseline: rect.minY + 18, in: ctx)
        if let count = h.renewIn {
            Text(count, countFont, theme.ink, kern: countKern).draw(x: tx, baseline: rect.minY + 37, in: ctx)
        }
        if let date = h.renewAt {
            Text(date, dateFont, theme.muted).draw(x: tx, baseline: rect.minY + 51, in: ctx)
        }
    }
}
