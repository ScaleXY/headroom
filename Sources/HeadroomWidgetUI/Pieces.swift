import HeadroomArt
import HeadroomKit
import SwiftUI

// MARK: - Brand

/// A brand mark from `assets/brand`, scaled from its 24×24 viewBox into the frame.
struct MarkShape: Shape {
    var provider: Provider

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var t = CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s).scaledBy(x: s, y: s)
        let cg = BrandPaths.path(named: provider == .claude ? "claude" : "openai")
        return Path(cg.copy(using: &t) ?? cg)
    }
}

/// The provider tile: brand gradient squircle with the mark, as on the Pace card.
struct BrandTile: View {
    var provider: Provider
    var size: CGFloat

    var body: some View {
        let b = BrandColors.of(provider)
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [b.tileTop, b.tileBottom], startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1)))
            shape.strokeBorder(LinearGradient(colors: [white(0.34), white(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
            MarkShape(provider: provider).fill(b.markInk)
                .frame(width: size * (provider == .claude ? 0.62 : 0.6), height: size * (provider == .claude ? 0.62 : 0.6))
        }
        .frame(width: size, height: size)
        .shadow(color: black(0.22), radius: size * 0.1, y: size * 0.05)
    }
}

/// "MAX 20×" in the brand's tint.
struct PlanPill: View {
    var provider: Provider
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let b = BrandColors.of(provider), p = Palette(scheme)
        Text(text.uppercased())
            .font(.system(size: 7.5, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(b.pill(p))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(b.base.opacity(p.dark ? 0.16 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(b.base.opacity(0.32), lineWidth: 0.6))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Provider tile, name and plan: the header every one-provider widget opens with.
struct ProviderHeader: View {
    var provider: WidgetProvider
    var tile: CGFloat = 16
    var name = true
    var trailing: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
}

// MARK: - Type

/// A small-capitals label ("EVEN PACE", "TO RESET").
struct Caps: View {
    var text: String
    var size: CGFloat
    var color: Color?
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, size: CGFloat = 8, color: Color? = nil) { self.text = text; self.size = size; self.color = color }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.09)
            .foregroundStyle(color ?? Palette(scheme).chartLabel)
            .lineLimit(1)
    }
}

/// A status dot with a soft halo, colored by what it reports.
struct Dot: View {
    var color: Color
    var size: CGFloat = 5

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.22)).frame(width: size * 2.2, height: size * 2.2))
    }
}

// MARK: - Meters

/// The five-cell level meter, the same one the menu bar and the Pace card show.
struct CellMeter: View {
    var state: PacingState
    var cells: Int
    var caret: Double? = nil
    var height: CGFloat = 12
    var dim = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), t = p.tone(state)
        VStack(alignment: .leading, spacing: 2) {
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
            if let caret {
                GeometryReader { g in
                    Caret().fill(p.chartLabel).frame(width: 6, height: 4)
                        .position(x: min(max(g.size.width * caret, 3), g.size.width - 3), y: 2)
                }
                .frame(height: 4)
            }
        }
    }
}

/// The even-pace caret under a meter: a small upward triangle.
struct Caret: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        }
    }
}

/// A progress ring from 12 o'clock, clockwise, with a glow on the lit arc.
struct Ring: View {
    var fraction: Double
    var tone: Tone
    var width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
}

/// The hourglass glyph ("use it before it renews"), from the app's 14×20 viewBox.
struct Hourglass: View {
    var color: Color
    var height: CGFloat = 10

    var body: some View {
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
}

/// SVG path data scaled from its viewBox into the frame.
struct SVGShape: Shape {
    var d: String
    var box: CGSize

    func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / box.width, y: rect.height / box.height)
        let cg = SVGPath.parse(d)
        return Path(cg.copy(using: &t) ?? cg)
    }
}

/// The warning triangle the graphs end on when the allowance runs out first.
struct WarningGlyph: View {
    var fill: Color
    var ink: Color
    var size: CGFloat = 12

    var body: some View {
        ZStack {
            SVGShape(d: "M7 1.2c.5 0 .9.3 1.2.7l5.5 9.7c.5.9-.1 2-1.2 2H1.5c-1 0-1.7-1.1-1.2-2l5.5-9.7c.3-.4.7-.7 1.2-.7z",
                     box: CGSize(width: 14, height: 14)).fill(fill)
            SVGShape(d: "M7 4.8v3.6", box: CGSize(width: 14, height: 14)).stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Circle().fill(ink).frame(width: size * 0.13, height: size * 0.13).offset(y: size * 0.22)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Identity

/// The Headroom meter-H, for the empty state.
struct HeadroomMarkView: View {
    var size: CGFloat
    private static let cells: [UInt32] = [0x4A8EFF, 0x7DB4FF, 0xECEDF1, 0xFFC248, 0xFF6982]

    var body: some View {
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
            RoundedRectangle(cornerRadius: 2.2 * s, style: .continuous).fill(hex(0xECEDF1))
                .frame(width: 16 * s, height: 5 * s).offset(x: 24 * s, y: 28.8 * s)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Surface

/// The widget's surface: the popover's dark card with a brand orb in the corner and, when it
/// matters, a faint wash of the state color behind the dial.
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
            if let provider {
                let b = BrandColors.of(provider)
                RadialGradient(colors: [p.dark ? b.orbDark : b.orbLight, .clear], center: UnitPoint(x: -0.05, y: -0.1),
                               startRadius: 0, endRadius: 210)
            }
            if let accent, accent >= .tight {
                RadialGradient(colors: [p.tone(accent).glow.opacity(p.dark ? 0.32 : 0.22), .clear], center: UnitPoint(x: 0.5, y: 1.15),
                               startRadius: 0, endRadius: 230)
            }
            // A soft sheen along the top edge, like the popover's glass.
            LinearGradient(colors: [white(p.dark ? 0.045 : 0.6), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
        }
    }
}
