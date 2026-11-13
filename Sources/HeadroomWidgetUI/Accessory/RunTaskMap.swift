import SwiftUI

// A run drawn as a map of its tasks rather than one bar: a block per task, as wide as its share
// of the run, filled as far as it has got, with a pearl tick under each must-have. The iPhone card,
// the iPad, the run Live Activity and the Watch draw it the same way the Mac does.

/// One block of the map, as resolved words and numbers (`RunSegment` on the presenter side).
public struct RunMapBlock: Codable, Hashable, Sendable {
    /// Share of the run; a map's weights sum to 1.
    public var weight: Double
    /// How far along, 0…1.
    public var fill: Double
    public var hue: RunHue
    /// A must-have.
    public var critical: Bool

    public init(weight: Double, fill: Double, hue: RunHue, critical: Bool = false) {
        self.weight = weight; self.fill = fill; self.hue = hue; self.critical = critical
    }
}

/// The task map in the cell meter's grammar (`CellMeter`): a recessed track, one cell per task as
/// wide as its share, finished work lit with the tone's glow, work under way lit as far as it has
/// got over a wash of its colour, something stuck amber, something that needs you rose, a failure
/// hatched; a caret under each must-have, as the even-pace caret sits under the meter.
public struct RunTaskMap: View {
    public var blocks: [RunMapBlock]
    /// The cells' height; the track adds its padding around them.
    public var height: CGFloat
    public var gap: CGFloat
    /// Carets under must-haves; off where the map sits inside a line of text.
    public var carets: Bool

    public init(blocks: [RunMapBlock], height: CGFloat = 8, gap: CGFloat = 2, carets: Bool = true) {
        self.blocks = blocks; self.height = height; self.gap = gap; self.carets = carets
    }
    @Environment(\.colorScheme) private var scheme

    var pad: CGFloat { max(1.5, height * 0.16) }
    /// Carets under must-haves need a little room below the track.
    var caretRoom: CGFloat { carets && blocks.contains(where: \.critical) ? 6 : 0 }

    public var body: some View {
        let p = Palette(scheme)
        let pad = pad, height = height
        Canvas { ctx, size in
            let trackH = height + pad * 2
            let track = Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: trackH), cornerRadius: trackH * 0.36, style: .continuous)
            ctx.fill(track, with: .color(p.meterTrack))
            ctx.stroke(track, with: .color(p.meterTrackBorder), lineWidth: 0.5)
            let frames = Self.layout(blocks.map(\.weight), width: size.width - pad * 2, gap: blocks.count > 16 ? max(1, gap - 0.5) : gap)
            let radius = min(height * 0.24, 4)
            for (b, f) in zip(blocks, frames) {
                let box = CGRect(x: pad + f.minX, y: pad, width: f.width, height: height)
                let shape = Path(roundedRect: box, cornerRadius: min(radius, box.width / 2), style: .continuous)
                ctx.fill(shape, with: .color(p.meterEmpty))
                let fill = min(max(b.fill, 0), 1)
                let tone: Tone? = switch b.hue {
                case .neutral, .progress: p.tone(.plenty)
                case .warn: p.tone(.tight)
                case .alert: p.tone(.veryTight)
                case .quiet, .failed: nil
                }
                let gradient = GraphicsContext.Shading.linearGradient(Gradient(colors: [tone?.top ?? p.muted2, tone?.bottom ?? p.muted2]),
                                                                      startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY))
                if b.hue == .failed {
                    ctx.drawLayer { layer in
                        layer.clip(to: shape)
                        layer.fill(Path(box), with: .color(p.ink.opacity(p.dark ? 0.22 : 0.16)))
                        var stripes = Path(), x = box.minX - box.height
                        while x < box.maxX { stripes.move(to: CGPoint(x: x, y: box.maxY)); stripes.addLine(to: CGPoint(x: x + box.height, y: box.minY)); x += 3.5 }
                        layer.stroke(stripes, with: .color(p.ink.opacity(p.dark ? 0.6 : 0.5)), lineWidth: 1)
                    }
                } else if fill >= 1 {
                    ctx.drawLayer { layer in
                        if let tone { layer.addFilter(.shadow(color: tone.glow, radius: height * 0.33)) }
                        layer.fill(shape, with: gradient)
                    }
                } else if fill > 0 {
                    ctx.drawLayer { layer in
                        layer.clip(to: shape)
                        if let tone { layer.fill(Path(box), with: .color(tone.bottom.opacity(p.dark ? 0.24 : 0.18))) }
                        layer.fill(Path(CGRect(x: box.minX, y: box.minY, width: max(box.width * fill, min(box.width, 2)), height: box.height)), with: gradient)
                    }
                }
                if b.critical, carets {
                    var caret = Path()
                    caret.move(to: CGPoint(x: box.midX, y: trackH + 2)); caret.addLine(to: CGPoint(x: box.midX + 3, y: trackH + 6))
                    caret.addLine(to: CGPoint(x: box.midX - 3, y: trackH + 6)); caret.closeSubpath()
                    ctx.fill(caret, with: .color(p.chartLabel))
                }
            }
        }
        .frame(height: height + pad * 2 + caretRoom)
        .accessibilityHidden(true)
    }

    /// Each block's x-extent: widths by weight, none thinner than 3 points, gaps between.
    static func layout(_ weights: [Double], width: CGFloat, gap: CGFloat) -> [CGRect] {
        guard !weights.isEmpty, width > 0 else { return [] }
        let avail = max(0, width - gap * CGFloat(weights.count - 1))
        let total = max(weights.reduce(0, +), 1e-9)
        var widths = weights.map { max(3, CGFloat($0 / total) * avail) }
        let scale = avail / max(widths.reduce(0, +), 1)
        widths = widths.map { $0 * scale }
        var x: CGFloat = 0
        return widths.map { w in defer { x += w + gap }; return CGRect(x: x, y: 0, width: w, height: 0) }
    }
}
