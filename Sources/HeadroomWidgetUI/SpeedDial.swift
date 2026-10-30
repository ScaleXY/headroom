import HeadroomKit
import SwiftUI

/// The Burn-o-meter: a speedometer for how fast an allowance is going.
///
/// The needle reads against the pace that lands on 0% exactly at the reset (1×); the readout
/// is the speed itself, in percent of the allowance per hour. The arc is built from the same lit cells
/// as the five-cell meter, colored by zone (azure cruising, pearl on pace, amber, rose redline),
/// with the zone bands drawn under it like a gauge's painted scale. A small notch marks the longer
/// average so a burst reads as a burst.
struct SpeedDial: View {
    /// Current burn ÷ lasting burn; `.infinity` once nothing is left; nil without a reading.
    var ratio: Double?
    var average: Double?
    var value: String
    /// Set smaller after the value: "%/h".
    var unit: String? = nil
    var caption: String?
    /// Draws the 0 · 1× · 2× · 3× scale.
    var scale = true
    var dim = false
    @Environment(\.colorScheme) private var scheme

    /// Degrees, clockwise from 3 o'clock: the dial runs from 7:30 round the top to 4:30.
    static let start = 150.0, sweep = 240.0
    static let segments = 30

    var body: some View {
        GeometryReader { g in
            let D = min(g.size.width, g.size.height / Self.aspect)
            let geo = Geometry(D: D, origin: CGPoint(x: (g.size.width - D) / 2, y: 0))
            dial(geo).frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
        .aspectRatio(1 / Self.aspect, contentMode: .fit)
    }

    /// Height ÷ width: the dial's bottom gap holds the readout.
    static let aspect: CGFloat = 0.94

    struct Geometry {
        var D: CGFloat
        var origin: CGPoint
        var c: CGPoint { CGPoint(x: origin.x + D / 2, y: origin.y + D / 2) }
        var rOut: CGFloat { D / 2 - D * 0.015 }
        var width: CGFloat { D * 0.088 }
        var rIn: CGFloat { rOut - width }

        func angle(_ v: Double) -> Double {
            (SpeedDial.start + SpeedDial.sweep * min(max(v, 0), BurnGauge.maxRatio * 1.03) / BurnGauge.maxRatio) * .pi / 180
        }

        func point(_ a: Double, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a))) }

        /// An annular sector between two angles (radians).
        func sector(_ a0: Double, _ a1: Double, inner: CGFloat, outer: CGFloat, into p: inout Path) {
            let steps = max(2, Int(abs(a1 - a0) / 0.03))
            p.move(to: point(a0, outer))
            for i in 1...steps { p.addLine(to: point(a0 + (a1 - a0) * Double(i) / Double(steps), outer)) }
            for i in stride(from: steps, through: 0, by: -1) { p.addLine(to: point(a0 + (a1 - a0) * Double(i) / Double(steps), inner)) }
            p.closeSubpath()
        }
    }

    @ViewBuilder
    private func dial(_ g: Geometry) -> some View {
        let p = Palette(scheme)
        let step = BurnGauge.maxRatio / Double(Self.segments)
        let gap = 1.7 * .pi / 180
        let lit = { (i: Int) -> Bool in
            guard let ratio else { return false }
            return ratio >= (Double(i) + 0.5) * step
        }
        let needleState = ratio.map { $0.isFinite ? BurnGauge.state($0) : .veryTight } ?? .onPace
        let needle = p.tone(needleState)

        ZStack(alignment: .topLeading) {
            // Unlit cells.
            Path { path in
                for i in 0..<Self.segments where !lit(i) {
                    g.sector(g.angle(Double(i) * step) + gap / 2, g.angle(Double(i + 1) * step) - gap / 2, inner: g.rIn, outer: g.rOut, into: &path)
                }
            }
            .fill(p.meterEmpty)

            // Lit cells, one path per zone so each glows in its own color.
            ForEach(BurnGauge.zones.indices, id: \.self) { z in
                let zone = BurnGauge.zones[z], tone = p.tone(zone.state)
                Path { path in
                    for i in 0..<Self.segments where lit(i) {
                        let mid = (Double(i) + 0.5) * step
                        guard mid >= zone.from, mid < zone.to || (z == BurnGauge.zones.count - 1) else { continue }
                        g.sector(g.angle(Double(i) * step) + gap / 2, g.angle(Double(i + 1) * step) - gap / 2, inner: g.rIn, outer: g.rOut, into: &path)
                    }
                }
                .fill(tone.fill)
                .shadow(color: tone.glow, radius: g.D * 0.03)
            }

            // The painted scale: zone bands just inside the cells.
            ForEach(BurnGauge.zones.indices, id: \.self) { z in
                let zone = BurnGauge.zones[z]
                Path { path in
                    g.sector(g.angle(zone.from) + (z == 0 ? 0 : gap / 2), g.angle(zone.to) - (z == BurnGauge.zones.count - 1 ? 0 : gap / 2),
                             inner: g.rIn - g.D * 0.034, outer: g.rIn - g.D * 0.02, into: &path)
                }
                .fill(p.tone(zone.state).bottom.opacity(zone.state == .onPace ? (p.dark ? 0.55 : 0.45) : 0.62))
            }

            if scale { ticks(g, p) }

            // The longer average: a small notch on the band.
            if let average, average.isFinite, average > 0.02 {
                let a = g.angle(average)
                Path { path in
                    path.move(to: g.point(a, g.rIn - g.D * 0.017))
                    path.addLine(to: g.point(a - 0.075, g.rIn - g.D * 0.075))
                    path.addLine(to: g.point(a + 0.075, g.rIn - g.D * 0.075))
                    path.closeSubpath()
                }
                .fill(p.ink.opacity(0.72))
                .shadow(color: black(p.dark ? 0.5 : 0.15), radius: 1)
            }

            needleView(g, needle, p)

            // Readout in the gap at the bottom.
            VStack(spacing: g.D * 0.012) {
                HStack(alignment: .firstTextBaseline, spacing: g.D * 0.008) {
                    Text(value)
                        .font(.system(size: g.D * 0.165, weight: .semibold).monospacedDigit())
                        .tracking(-g.D * 0.005)
                        .foregroundStyle(ratio == nil ? p.muted : p.ink)
                        .contentTransition(.numericText())
                        .widgetAccentable()
                    if let unit { Text(unit).font(.system(size: g.D * 0.075, weight: .semibold)).foregroundStyle(p.muted) }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: g.D * 0.66)
                // Below the arc's ends, so a caption may run nearly the dial's width.
                if let caption { Caps(caption, size: max(6.5, g.D * 0.052)).minimumScaleFactor(0.8).frame(width: g.D * 0.92) }
            }
            .position(x: g.c.x, y: g.c.y + g.D * (caption == nil ? 0.26 : 0.29))
        }
        .opacity(dim ? 0.5 : 1)
    }

    @ViewBuilder
    private func ticks(_ g: Geometry, _ p: Palette) -> some View {
        let r0 = g.rIn - g.D * 0.052
        Path { path in
            for k in 0...12 {
                let v = Double(k) * 0.25, a = g.angle(v)
                let major = k % 4 == 0
                path.move(to: g.point(a, r0))
                path.addLine(to: g.point(a, r0 - g.D * (major ? 0.055 : k % 2 == 0 ? 0.034 : 0.022)))
            }
        }
        .stroke(p.chartLabel, style: StrokeStyle(lineWidth: max(0.8, g.D * 0.0085), lineCap: .round))
        let needleAt = ratio.map { $0.isFinite ? min($0, BurnGauge.maxRatio * 1.03) : BurnGauge.maxRatio * 1.03 } ?? 0
        ForEach(0..<4, id: \.self) { k in
            let pt = g.point(g.angle(Double(k)), r0 - g.D * 0.125)
            // A label the needle lies across steps back.
            let covered = abs(needleAt - Double(k)) < 0.22
            Text(k == 0 ? "0" : "\(k)×")
                .font(.system(size: max(7, g.D * 0.062), weight: k == 1 ? .bold : .semibold).monospacedDigit())
                .foregroundStyle(k == 1 ? p.ink.opacity(0.85) : p.chartLabel)
                .fixedSize()
                .opacity(covered ? 0.2 : 1)
                .position(pt)
        }
    }

    @ViewBuilder
    private func needleView(_ g: Geometry, _ tone: Tone, _ p: Palette) -> some View {
        let a = g.angle(ratio.map { $0.isFinite ? $0 : BurnGauge.maxRatio * 1.03 } ?? 0)
        let perp = a + .pi / 2
        let base = g.D * 0.026, tipLen = g.rIn - g.D * 0.045, tail = g.D * 0.085
        let side = { (s: Double, r: CGFloat) -> CGPoint in
            CGPoint(x: g.c.x + r * CGFloat(cos(perp)) * CGFloat(s), y: g.c.y + r * CGFloat(sin(perp)) * CGFloat(s))
        }
        Path { path in
            path.move(to: g.point(a, tipLen))
            path.addLine(to: side(1, base / 2))
            path.addLine(to: g.point(a + .pi, tail))
            path.addLine(to: side(-1, base / 2))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [tone.top, tone.bottom], startPoint: UnitPoint(x: 0.5, y: 0), endPoint: UnitPoint(x: 0.5, y: 1)))
        .shadow(color: tone.glow, radius: g.D * 0.035)
        .shadow(color: black(p.dark ? 0.45 : 0.18), radius: g.D * 0.012, y: g.D * 0.006)
        .widgetAccentable()

        // Hub.
        let hub = g.D * 0.12
        Circle()
            .fill(LinearGradient(colors: p.dark ? [hex(0x34363D), hex(0x16171B)] : [hex(0xFFFFFF), hex(0xE3E4E9)], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(p.dark ? white(0.12) : black(0.10), lineWidth: 0.7))
            .shadow(color: black(p.dark ? 0.5 : 0.2), radius: g.D * 0.02, y: g.D * 0.008)
            .frame(width: hub, height: hub)
            .position(g.c)
        Circle().fill(tone.fill).frame(width: hub * 0.4, height: hub * 0.4)
            .shadow(color: tone.glow, radius: hub * 0.2)
            .position(g.c)
    }

    /// "3.7" with "%/h", "OUT" or "—".
    static func readout(perHour: Double?, ratio: Double?) -> (value: String, unit: String?) {
        guard let ratio, let perHour else { return ("—", nil) }
        guard ratio.isFinite else { return ("OUT", nil) }
        return (rate(perHour), "%/h")
    }

    /// Percent of the allowance per hour, without the sign: "0", "0.6", "3.7", "42".
    static func rate(_ perHour: Double) -> String {
        let pct = max(0, perHour) * 100
        if pct >= 9.95 { return "\(Int(pct.rounded()))" }
        if pct < 0.05 { return "0" }
        return pct.formatted(.number.precision(.fractionLength(1)))
    }
}
