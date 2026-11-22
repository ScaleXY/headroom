import HeadroomArt
import HeadroomKit
import SwiftUI

// MARK: - Brand

/// A brand mark from `assets/brand`, scaled from its 24×24 viewBox into the frame.
public struct MarkShape: Shape {
    public var provider: Provider

    public func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var t = CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s).scaledBy(x: s, y: s)
        let cg = BrandPaths.path(named: provider == .claude ? "claude" : "openai")
        return Path(cg.copy(using: &t) ?? cg)
    }

    public init(provider: Provider) {
        self.provider = provider
    }
}

/// The provider tile (redesign §2 rule 1): the real mark in the provider's tone on a neutral
/// Headroom tile, as on the Mac's cards.
public struct BrandTile: View {
    public var provider: Provider
    public var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme)
        let k = size / 26
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [p.markTileTop, p.markTileBottom], startPoint: .top, endPoint: .bottom))
            // inset 0 1px 0: a 1 pt highlight along the top edge.
            shape.fill(p.markTileHighlight)
                .mask(shape.subtracting(shape.offset(y: 1)).frame(width: size, height: size))
            shape.strokeBorder(p.markTileStroke, lineWidth: 0.5)
            MarkShape(provider: provider).fill(p.providerTone(provider))
                .frame(width: size * 0.58, height: size * 0.58)
        }
        .frame(width: size, height: size)
        .shadow(color: p.markTileShadow, radius: 1.5 * k, y: 1 * k)
    }

    public init(provider: Provider, size: CGFloat) {
        self.provider = provider
        self.size = size
    }
}

/// "MAX 20×" in the provider's tone (rule 2): tone text, a 10% tone fill and a 0.5 pt stroke at 42%.
public struct PlanPill: View {
    public var provider: Provider
    public var text: String
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme)
        Text(text.uppercased())
            .font(.system(size: 7.5, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(p.providerTone(provider))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.providerTone(provider, ProviderTone.pillFill)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(p.providerTone(provider, ProviderTone.pillStroke), lineWidth: 0.5))
            .lineLimit(1)
            .fixedSize()
    }

    public init(provider: Provider, text: String) {
        self.provider = provider
        self.text = text
    }
}

/// Provider tile, name and plan: the header every one-provider widget opens with.
public struct ProviderHeader: View {
    public var provider: WidgetProvider
    public var tile: CGFloat = 16
    public var name = true
    public var trailing: String? = nil
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 6) {
            BrandTile(provider: provider.id, size: tile)
            if name {
                Text(provider.id.displayName).font(Fonts.text(tile * 0.78, .semibold)).foregroundStyle(p.ink).lineLimit(1)
            }
            if let plan = provider.plan, name { PlanPill(provider: provider.id, text: plan) }
            Spacer(minLength: 4)
            if let trailing { Caps(trailing) }
        }
    }

    public init(provider: WidgetProvider, tile: CGFloat = 16, name: Bool = true, trailing: String? = nil) {
        self.provider = provider
        self.tile = tile
        self.name = name
        self.trailing = trailing
    }
}

// MARK: - Type

/// A small-capitals label ("ON TRACK", "TO RESET").
public struct Caps: View {
    public var text: String
    public var size: CGFloat
    public var color: Color?
    @Environment(\.colorScheme) private var scheme

    public init(_ text: String, size: CGFloat = 8, color: Color? = nil) { self.text = text; self.size = size; self.color = color }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.09)
            .foregroundStyle(color ?? Palette(scheme).chartLabel)
            .lineLimit(1)
    }
}

/// A status dot with a soft halo, colored by what it reports.
public struct Dot: View {
    public var color: Color
    public var size: CGFloat = 5

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.22)).frame(width: size * 2.2, height: size * 2.2))
    }

    public init(color: Color, size: CGFloat = 5) {
        self.color = color
        self.size = size
    }
}

// MARK: - Meters

/// The five-cell level meter, the same one the menu bar and the Pace card show.
public struct CellMeter: View {
    public var state: PacingState
    public var cells: Int
    public var caret: Double? = nil
    public var height: CGFloat = 12
    public var dim = false
    /// "On track" beside the caret (the phone's Limits card), drawn in small capitals.
    public var caretLabel: String? = nil
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme), t = p.tone(state)
        VStack(alignment: .leading, spacing: caretLabel == nil ? 2 : 4) {
            HStack(spacing: height * 0.22) {
                ForEach(0..<5, id: \.self) { i in
                    let cell = RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
                    if i < cells {
                        cell.fill(t.fill).shadow(color: t.glow, radius: height * 0.33)
                            .overlay(cell.strokeBorder(white(p.dark ? 0.18 : 0.25), lineWidth: 0.5).blendMode(.plusLighter).opacity(0.6))
                    } else {
                        cell.fill(p.meterEmpty)
                    }
                }
            }
            .padding(height * 0.16)
            .background(RoundedRectangle(cornerRadius: height * 0.36, style: .continuous).fill(p.meterTrack))
            .overlay(RoundedRectangle(cornerRadius: height * 0.36, style: .continuous).strokeBorder(p.meterTrackBorder, lineWidth: 0.5))
            .frame(height: height + height * 0.32)
            .opacity(dim ? 0.45 : 1)
            if let caret, let caretLabel {
                GeometryReader { g in
                    HStack(spacing: 4) {
                        Caret().fill(p.chartLabel).frame(width: 7, height: 5)
                        Text(caretLabel.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(p.chartLabel).lineLimit(1)
                    }
                    .fixedSize()
                    .position(x: min(max(g.size.width * caret, 44), g.size.width - 44), y: 6)
                }
                .frame(height: 12)
            } else if let caret {
                GeometryReader { g in
                    Caret().fill(p.chartLabel).frame(width: 6, height: 4)
                        .position(x: min(max(g.size.width * caret, 3), g.size.width - 3), y: 2)
                }
                .frame(height: 4)
            }
        }
    }

    public init(state: PacingState, cells: Int, caret: Double? = nil, height: CGFloat = 12, dim: Bool = false, caretLabel: String? = nil) {
        self.state = state
        self.cells = cells
        self.caret = caret
        self.height = height
        self.dim = dim
        self.caretLabel = caretLabel
    }
}

/// The even-pace caret under a meter: a small upward triangle.
public struct Caret: Shape {
    public func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        }
    }
}

/// A progress ring from 12 o'clock, clockwise, with a glow on the lit arc.
public struct Ring: View {
    public var fraction: Double
    public var tone: Tone
    public var width: CGFloat
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let p = Palette(scheme), f = min(max(fraction, 0), 1)
        ZStack {
            Circle().inset(by: width / 2).stroke(p.meterEmpty, lineWidth: width)
            Circle().inset(by: width / 2).trim(from: 0, to: f)
                .stroke(AngularGradient(colors: [tone.bottom, tone.top, tone.bottom], center: .center,
                                        startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tone.glow, radius: width * 0.6)
                .opacity(f > 0 ? 1 : 0)
        }
    }

    public init(fraction: Double, tone: Tone, width: CGFloat) {
        self.fraction = fraction
        self.tone = tone
        self.width = width
    }
}

/// The hourglass glyph ("use it before it renews"), from the app's 14×20 viewBox.
public struct Hourglass: View {
    public var color: Color
    public var height: CGFloat = 10

    public var body: some View {
        let k = height / 20
        ZStack {
            SVGShape(d: "M2 1.6h10M2 18.4h10", box: CGSize(width: 14, height: 20)).stroke(color, style: StrokeStyle(lineWidth: 2.2 * k, lineCap: .round))
            SVGShape(d: "M3.3 2.2c0 4 3.7 5.4 3.7 7.8s-3.7 3.8-3.7 7.8M10.7 2.2c0 4-3.7 5.4-3.7 7.8s3.7 3.8 3.7 7.8", box: CGSize(width: 14, height: 20))
                .stroke(color, lineWidth: 1.7 * k)
            SVGShape(d: "M4.4 17.4c.7-2 2.6-2.9 2.6-2.9s1.9.9 2.6 2.9zM5.2 5.6h3.6c-.6 1.2-1.8 1.9-1.8 1.9s-1.2-.7-1.8-1.9z", box: CGSize(width: 14, height: 20))
                .fill(color)
        }
        .frame(width: height * 0.7, height: height)
    }

    public init(color: Color, height: CGFloat = 10) {
        self.color = color
        self.height = height
    }
}

/// SVG path data scaled from its viewBox into the frame.
public struct SVGShape: Shape {
    public var d: String
    public var box: CGSize

    nonisolated(unsafe) private static var parsed: [String: CGPath] = [:]
    private static let lock = NSLock()

    /// Parsed once per path string: a shape is drawn again on every body pass.
    private static func parse(_ d: String) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let p = parsed[d] { return p }
        let p = SVGPath.parse(d)
        parsed[d] = p
        return p
    }

    public func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / box.width, y: rect.height / box.height)
        let cg = Self.parse(d)
        return Path(cg.copy(using: &t) ?? cg)
    }

    public init(d: String, box: CGSize) {
        self.d = d
        self.box = box
    }
}

/// The warning triangle the graphs end on when the allowance runs out first.
public struct WarningGlyph: View {
    public var fill: Color
    public var ink: Color
    public var size: CGFloat = 12

    public var body: some View {
        ZStack {
            SVGShape(d: "M7 1.2c.5 0 .9.3 1.2.7l5.5 9.7c.5.9-.1 2-1.2 2H1.5c-1 0-1.7-1.1-1.2-2l5.5-9.7c.3-.4.7-.7 1.2-.7z",
                     box: CGSize(width: 14, height: 14)).fill(fill)
            SVGShape(d: "M7 4.8v3.6", box: CGSize(width: 14, height: 14)).stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Circle().fill(ink).frame(width: size * 0.13, height: size * 0.13).offset(y: size * 0.22)
        }
        .frame(width: size, height: size)
    }

    public init(fill: Color, ink: Color, size: CGFloat = 12) {
        self.fill = fill
        self.ink = ink
        self.size = size
    }
}

// MARK: - Identity

/// The Headroom meter-H, for the empty state.
public struct HeadroomMarkView: View {
    public var size: CGFloat
    private static let cells: [UInt32] = [0x4A8EFF, 0x7DB4FF, 0xECEDF1, 0xFFC248, 0xFF6982]

    public var body: some View {
        let s = size / 64
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 15 * s, style: .continuous)
                .fill(LinearGradient(colors: [hex(0x2E313B), hex(0x0E0F13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 15 * s, style: .continuous).strokeBorder(white(0.12), lineWidth: max(s, 0.5)))
                .shadow(color: black(0.3), radius: 4 * s, y: 2 * s)
            ForEach([16.0, 38.0], id: \.self) { x in
                ForEach(0..<5, id: \.self) { i in
                    let c = hex(Self.cells[i])
                    RoundedRectangle(cornerRadius: 2.6 * s, style: .continuous)
                        .fill(i < 3 ? c : c.opacity(0.27))
                        .shadow(color: i < 3 ? c.opacity(0.55) : .clear, radius: 1.8 * s)
                        .frame(width: 10 * s, height: 6.2 * s)
                        .offset(x: x * s, y: (51.8 - 6.2 - 8.7 * Double(i)) * s)
                }
            }
            // The crossbar: one more pearl cell in the "now" row, joining the legs.
            RoundedRectangle(cornerRadius: 2.6 * s, style: .continuous)
                .fill(hex(Self.cells[2]))
                .shadow(color: hex(Self.cells[2]).opacity(0.55), radius: 1.8 * s)
                .frame(width: 9 * s, height: 6.2 * s)
                .offset(x: 27.5 * s, y: 28.2 * s)
        }
        .frame(width: size, height: size)
    }

    public init(size: CGFloat) {
        self.size = size
    }
}

// MARK: - Surface

/// The provider's signature on a card (redesign §2 rules 3 and 4): a soft wash and a 1.5 pt light
/// along the top edge in the provider's tone, and, on cards that show a pacing state, a glow in the
/// state color from the top-right corner. Draws no fill of its own; clip it to the card's shape.
public struct SignatureLight: View {
    public var provider: Provider?
    public var state: PacingState?
    @Environment(\.colorScheme) private var scheme

    public init(provider: Provider?, state: PacingState? = nil) {
        self.provider = provider
        self.state = state
    }

    public var body: some View {
        let p = Palette(scheme)
        GeometryReader { g in
            let w = max(g.size.width, 1)
            ZStack(alignment: .topLeading) {
                if let provider {
                    // radial-gradient(75% 64px at 16% 0%, tone 11% / 9%, transparent)
                    let rx = w * 0.75, ry: CGFloat = 64
                    RadialGradient(colors: [p.providerTone(provider, ProviderTone.edgeWash(dark: p.dark)), p.providerTone(provider, 0)],
                                   center: .center, startRadius: 0, endRadius: rx)
                        .frame(width: rx * 2, height: rx * 2)
                        .scaleEffect(x: 1, y: ry / rx)
                        .position(x: w * 0.16, y: 0)
                }
                if let state {
                    // radial-gradient(260px 170px at 100% 0%, glow, transparent 72%)
                    let glow = p.stateGlow(state)
                    RadialGradient(stops: [.init(color: glow, location: 0), .init(color: glow.opacity(0), location: 0.72)],
                                   center: .center, startRadius: 0, endRadius: 260)
                        .frame(width: 520, height: 520)
                        .scaleEffect(x: 1, y: 170.0 / 260)
                        .position(x: w, y: 0)
                }
                if let provider {
                    let tone = p.providerTone(provider)
                    LinearGradient(stops: [.init(color: tone.opacity(0), location: 0), .init(color: tone.opacity(0), location: 0.03),
                                           .init(color: tone.opacity(ProviderTone.edgeLight(dark: p.dark)), location: 0.20),
                                           .init(color: tone.opacity(0), location: 0.72)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w, height: 1.5)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The widget's surface: the popover's card with the provider's top-edge light and, when the
/// widget shows a pacing state, that state's glow from the top-right corner.
public struct WidgetSurface: View {
    var provider: Provider?
    var accent: PacingState?
    @Environment(\.colorScheme) private var scheme

    public init(provider: Provider?, accent: PacingState? = nil) { self.provider = provider; self.accent = accent }

    public var body: some View {
        let p = Palette(scheme)
        ZStack {
            LinearGradient(colors: p.dark ? [hex(0x1E1F25), hex(0x121317)] : [hex(0xFFFFFF), hex(0xF1F1F5)],
                           startPoint: .top, endPoint: .bottom)
            // A soft sheen along the top edge, like the popover's glass.
            LinearGradient(colors: [white(p.dark ? 0.045 : 0.6), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
            SignatureLight(provider: provider, state: accent)
        }
    }
}
