import HeadroomKit
import HeadroomPresent
import HeadroomWidgetUI
import SwiftUI

/// The Limits card's reservoir, as the Mac draws it (`ReservoirRenderer`): a recessed track filled
/// from the left to what's left in the state's colors, the big number on the fill (or just past its
/// edge when the level is low), and the renewal in a frosted tag at the right end. Drawn in one
/// Canvas so the real text widths decide where the number goes (`Reservoir.place`).
struct ReservoirView: View {
    var hero: HeroModel
    var state: PacingState
    /// Settings → Meter off: the track, the number and the tag, without the level.
    var filled = true
    var dim: Double = 1
    @Environment(\.colorScheme) private var scheme
    // Dynamic Type grows the words a little, capped so the 88 pt reservoir keeps its shape.
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 48
    @ScaledMetric(relativeTo: .footnote) private var labelSize: CGFloat = 11.5
    @ScaledMetric(relativeTo: .headline) private var countSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var dateSize: CGFloat = 11

    var body: some View {
        let sizes = Sizes(number: min(numberSize, 54), label: min(labelSize, 13.5), count: min(countSize, 20), date: min(dateSize, 13))
        let dark = scheme == .dark
        Canvas { ctx, size in
            ReservoirDrawing(hero: hero, state: state, filled: filled, dark: dark, sizes: sizes).draw(in: &ctx, size: size)
        }
        .frame(height: CGFloat(Reservoir.height))
        .opacity(dim)
        .accessibilityElement()
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var s = "\(hero.percentLeft) percent \(hero.label)"
        if let count = hero.renewIn { s += ", renews in \(count)" + (hero.renewAt.map { ", \($0)" } ?? "") }
        return s
    }

    struct Sizes {
        var number: CGFloat
        var label: CGFloat
        var count: CGFloat
        var date: CGFloat
    }
}

/// The reservoir's drawing, kept apart from the view so the Canvas closure stays small.
private struct ReservoirDrawing {
    var hero: HeroModel
    var state: PacingState
    var filled: Bool
    var dark: Bool
    var sizes: ReservoirView.Sizes

    static func color(_ c: Reservoir.Color) -> Color {
        let r = Double((c.hex >> 16) & 0xFF) / 255
        let g = Double((c.hex >> 8) & 0xFF) / 255
        let b = Double(c.hex & 0xFF) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: c.alpha)
    }

    func digits(_ scale: CGFloat, color: Color) -> Text {
        let size = sizes.number * scale
        let tracking = -2.2 * size / CGFloat(Reservoir.numberSize)
        return Text("\(hero.percentLeft)").font(.system(size: size, weight: .heavy).monospacedDigit()).tracking(tracking).foregroundStyle(color)
    }

    func percent(_ scale: CGFloat, color: Color) -> Text {
        let size = sizes.number * scale * CGFloat(Reservoir.percentScale)
        return Text("%").font(.system(size: size, weight: .bold)).foregroundStyle(color)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let p = Palette(dark ? .dark : .light)
        let palette = Reservoir.palette(state, dark: dark)
        let track = Reservoir.track(dark: dark)
        let shape = Path(roundedRect: rect, cornerRadius: CGFloat(Reservoir.radius))
        ctx.fill(shape, with: .color(Self.color(track.fill)))

        // Measure: the tag, then the number and its line, to place the number.
        let caps = ctx.resolve(Text("RENEWS IN").font(.system(size: 8.5, weight: .bold)).tracking(0.9).foregroundStyle(p.muted))
        let count = hero.renewIn.map { ctx.resolve(Text($0).font(.system(size: sizes.count, weight: .bold).monospacedDigit()).tracking(-0.3).foregroundStyle(p.ink)) }
        let date = hero.renewAt.map { ctx.resolve(Text($0).font(.system(size: sizes.date, weight: .semibold)).foregroundStyle(p.muted)) }
        let free = CGSize(width: 1000, height: 200)
        var tagRect: CGRect? = nil
        var right = rect.maxX - CGFloat(Reservoir.outsideMinX)
        if let count {
            let widths = [caps.measure(in: free).width, count.measure(in: free).width, date?.measure(in: free).width ?? 0]
            let tw = CGFloat(Reservoir.tagWidth(textWidth: Double(widths.max() ?? 0)))
            let th = CGFloat(Reservoir.tagHeight)
            let tx = rect.maxX - CGFloat(Reservoir.tagInset) - tw
            tagRect = CGRect(x: tx, y: rect.midY - th / 2, width: tw, height: th)
            right = tx - CGFloat(Reservoir.tagGap)
        }
        let fill = filled ? CGFloat(Reservoir.fillWidth(percentLeft: hero.percentLeft, width: Double(rect.width))) : 0
        let numberW = ctx.resolve(digits(1, color: .black)).measure(in: free).width + 1 + ctx.resolve(percent(1, color: .black)).measure(in: free).width
        let labelFont = Font.system(size: sizes.label, weight: .semibold)
        let labelW = ctx.resolve(Text(hero.label).font(labelFont)).measure(in: free).width + 1
        let place = Reservoir.place(fill: Double(fill), number: Double(numberW), label: Double(labelW), right: Double(right))

        var inner = ctx
        inner.clip(to: shape)
        if fill > 0 { drawFill(in: &inner, palette: palette, width: fill, rect: rect) }

        // The number: the state's ink on the fill, the state's color on the track.
        let ink = Self.color(palette.ink)
        let numberColor = place.inside ? ink : (palette.plainOnTrack ? p.ink : Self.color(palette.text))
        let labelColor = place.inside ? ink.opacity(0.8) : p.muted.opacity(0.8)
        let scale = CGFloat(place.scale)
        let x = CGFloat(place.x)
        let base = rect.midY + 8 * sizes.number / CGFloat(Reservoir.numberSize)
        let d = inner.resolve(digits(scale, color: numberColor))
        inner.draw(d, at: CGPoint(x: x, y: base - d.firstBaseline(in: free)), anchor: .topLeading)
        let pct = inner.resolve(percent(scale, color: numberColor.opacity(0.85)))
        let raise = sizes.number * scale * 0.44
        inner.draw(pct, at: CGPoint(x: x + d.measure(in: free).width + scale, y: base - raise - pct.firstBaseline(in: free)), anchor: .topLeading)
        let shown = fitted(hero.label, font: labelFont, width: CGFloat(place.labelRoom) - 1, ctx: inner)
        let label = inner.resolve(Text(shown).font(labelFont).foregroundStyle(labelColor))
        let labelBase = rect.midY + 27
        inner.draw(label, at: CGPoint(x: x + 1, y: labelBase - label.firstBaseline(in: free)), anchor: .topLeading)

        if let tagRect, let count { drawTag(in: &inner, rect: tagRect, caps: caps, count: count, date: date) }
        let edge = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: CGFloat(Reservoir.radius) - 0.5)
        ctx.stroke(edge, with: .color(Self.color(track.stroke)), lineWidth: 1)
    }

    /// `s`, cut with an ellipsis to fit `width`.
    func fitted(_ s: String, font: Font, width: CGFloat, ctx: GraphicsContext) -> String {
        let free = CGSize(width: 1000, height: 200)
        func w(_ t: String) -> CGFloat { ctx.resolve(Text(t).font(font)).measure(in: free).width }
        guard w(s) > width else { return s }
        var t = s
        while t.count > 1, w(t + "…") > width { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The level: deep to light toward the edge, its glow on the track, a sheen across the top, and
    /// a lit edge (none when full).
    func drawFill(in ctx: inout GraphicsContext, palette: Reservoir.Palette, width: CGFloat, rect: CGRect) {
        let fillRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let path = Path(fillRect)
        let gradient = Gradient(colors: [Self.color(palette.deep), Self.color(palette.light)])
        let glow = Self.color(palette.glow)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: glow, radius: 7))
            layer.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: fillRect.minX, y: fillRect.midY),
                                                   endPoint: CGPoint(x: fillRect.maxX, y: fillRect.midY)))
        }
        let sheen = Gradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0)])
        ctx.fill(path, with: .linearGradient(sheen, startPoint: CGPoint(x: fillRect.minX, y: fillRect.minY),
                                             endPoint: CGPoint(x: fillRect.minX, y: fillRect.minY + fillRect.height * 0.55)))
        guard !Reservoir.isFull(percentLeft: hero.percentLeft) else { return }
        let edgeW = CGFloat(Reservoir.edgeWidth), inset = CGFloat(Reservoir.edgeInset)
        let edgeRect = CGRect(x: fillRect.maxX - edgeW, y: rect.minY + inset, width: edgeW, height: rect.height - inset * 2)
        let edgeColor = Color.white.opacity(dark ? 0.92 : 0.85)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.white.opacity(0.75), radius: 2.5))
            layer.fill(Path(roundedRect: edgeRect, cornerRadius: 1), with: .color(edgeColor))
        }
    }

    /// The frosted tag: "RENEWS IN", the countdown, and the day and time.
    func drawTag(in ctx: inout GraphicsContext, rect: CGRect, caps: GraphicsContext.ResolvedText,
                 count: GraphicsContext.ResolvedText, date: GraphicsContext.ResolvedText?) {
        let style = Reservoir.tag(dark: dark)
        let shape = Path(roundedRect: rect, cornerRadius: CGFloat(Reservoir.tagRadius))
        let fillColor = Self.color(style.fill), shadow = Self.color(style.shadow)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: shadow, radius: 3.5, x: 0, y: 2))
            layer.fill(shape, with: .color(fillColor))
        }
        let inset = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: CGFloat(Reservoir.tagRadius) - 0.5)
        ctx.stroke(inset, with: .color(Self.color(style.stroke)), lineWidth: 1)
        if let hi = style.highlight {
            ctx.fill(Path(CGRect(x: rect.minX + 10, y: rect.minY + 0.5, width: rect.width - 20, height: 1)), with: .color(Self.color(hi)))
        }
        let free = CGSize(width: 1000, height: 200)
        let tx = rect.minX + CGFloat(Reservoir.tagPadding)
        ctx.draw(caps, at: CGPoint(x: tx, y: rect.minY + 18 - caps.firstBaseline(in: free)), anchor: .topLeading)
        ctx.draw(count, at: CGPoint(x: tx, y: rect.minY + 37 - count.firstBaseline(in: free)), anchor: .topLeading)
        if let date {
            ctx.draw(date, at: CGPoint(x: tx, y: rect.minY + 51 - date.firstBaseline(in: free)), anchor: .topLeading)
        }
    }
}
