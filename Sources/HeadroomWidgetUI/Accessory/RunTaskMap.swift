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

/// The task map. Finished work is solid blue, work under way blue up to how far it has got over a
/// wash of the same blue, something to look at amber, something that needs you rose, and work not
/// started the empty track.
public struct RunTaskMap: View {
    public var blocks: [RunMapBlock]
    public var height: CGFloat
    public var gap: CGFloat

    public init(blocks: [RunMapBlock], height: CGFloat = 8, gap: CGFloat = 2) { self.blocks = blocks; self.height = height; self.gap = gap }
    @Environment(\.colorScheme) private var scheme

    /// Ticks under must-haves need a little room below the blocks.
    var tickRoom: CGFloat { blocks.contains(where: \.critical) ? 4 : 0 }

    public var body: some View {
        let p = Palette(scheme), blue = p.tone(.plenty)
        Canvas { ctx, size in
            let frames = Self.layout(blocks.map(\.weight), width: size.width, gap: blocks.count > 16 ? max(1, gap - 0.5) : gap)
            let radius = min(2.5, height / 2)
            for (b, f) in zip(blocks, frames) {
                let box = CGRect(x: f.minX, y: 0, width: f.width, height: height)
                let shape = Path(roundedRect: box, cornerRadius: radius, style: .continuous)
                ctx.fill(shape, with: .color(p.meterTrack))
                let fill = min(max(b.fill, 0), 1)
                let solid: GraphicsContext.Shading, wash: Color?
                switch b.hue {
                case .neutral, .progress:
                    solid = .linearGradient(Gradient(colors: [blue.top, blue.bottom]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: height))
                    wash = b.hue == .progress ? blue.bottom.opacity(p.dark ? 0.30 : 0.22) : nil
                case .warn: solid = .color(p.amber); wash = p.amber.opacity(0.24)
                case .alert: solid = .color(p.rose); wash = p.rose.opacity(0.24)
                case .quiet: solid = .color(p.muted2); wash = nil
                case .failed: solid = .color(p.ink.opacity(p.dark ? 0.55 : 0.5)); wash = nil
                }
                ctx.drawLayer { layer in
                    layer.clip(to: shape)
                    if let wash, b.hue != .quiet { layer.fill(Path(box), with: .color(wash)) }
                    if fill > 0 { layer.fill(Path(CGRect(x: box.minX, y: 0, width: max(box.width * fill, min(box.width, 2)), height: height)), with: solid) }
                }
                if b.critical {
                    let tick = CGRect(x: box.midX - 2.5, y: height + 2, width: 5, height: 2)
                    ctx.fill(Path(roundedRect: tick, cornerRadius: 1), with: .color(p.ink.opacity(p.dark ? 0.62 : 0.5)))
                }
            }
        }
        .frame(height: height + tickRoom)
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
