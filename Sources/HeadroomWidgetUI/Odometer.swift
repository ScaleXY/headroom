import HeadroomKit
import SwiftUI

/// A mechanical odometer: each digit on its own drum, the neighbors just showing above and below.
struct Odometer: View {
    /// "12.4M": digits roll, everything else sits between the drums.
    var text: String
    var height: CGFloat = 26
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: height * 0.08) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                if let d = ch.wholeNumberValue {
                    drum(d, p)
                } else if ch == "." || ch == "," {
                    Circle().fill(p.ink.opacity(0.8)).frame(width: height * 0.12, height: height * 0.12)
                        .frame(height: height, alignment: .bottom).padding(.bottom, height * 0.2)
                } else {
                    Text(String(ch)).font(.system(size: height * 0.62, weight: .bold).monospacedDigit()).foregroundStyle(p.muted)
                        .frame(height: height).padding(.leading, height * 0.06)
                }
            }
        }
    }

    private func drum(_ d: Int, _ p: Palette) -> some View {
        let w = height * 0.66
        let shape = RoundedRectangle(cornerRadius: height * 0.16, style: .continuous)
        let face = p.dark ? [hex(0x0B0C0F), hex(0x26282E), hex(0x0B0C0F)] : [hex(0xD9DADF), hex(0xFFFFFF), hex(0xD9DADF)]
        return ZStack {
            shape.fill(LinearGradient(colors: face, startPoint: .top, endPoint: .bottom))
            VStack(spacing: height * 0.18) {
                digit((d + 9) % 10, p).opacity(0.28)
                digit(d, p)
                digit((d + 1) % 10, p).opacity(0.28)
            }
            // The drum's curve: shade toward the edges.
            shape.fill(LinearGradient(stops: [.init(color: black(p.dark ? 0.55 : 0.18), location: 0), .init(color: .clear, location: 0.3),
                                              .init(color: .clear, location: 0.7), .init(color: black(p.dark ? 0.55 : 0.18), location: 1)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(p.dark ? white(0.08) : black(0.08), lineWidth: 0.6)
        }
        .frame(width: w, height: height)
        .clipShape(shape)
        .shadow(color: black(p.dark ? 0.4 : 0.1), radius: 1.5, y: 1)
    }

    private func digit(_ d: Int, _ p: Palette) -> some View {
        Text("\(d)").font(.system(size: height * 0.62, weight: .semibold).monospacedDigit()).foregroundStyle(p.ink)
            .frame(height: height * 0.62)
    }
}

/// Tokens per hour across the last day, the current hour lit.
struct HourBars: View {
    var tokens: [Int64]
    var provider: Provider
    var tone: Tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), b = BrandColors.of(provider)
        let top = max(tokens.max() ?? 0, 1)
        GeometryReader { g in
            let n = max(tokens.count, 1)
            let gap: CGFloat = 2, w = (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            ZStack(alignment: .bottomLeading) {
                ForEach(tokens.indices, id: \.self) { i in
                    let v = Double(tokens[i]) / Double(top)
                    let h = max(2, g.size.height * CGFloat(v))
                    let last = i == tokens.count - 1
                    RoundedRectangle(cornerRadius: min(2, w / 2), style: .continuous)
                        .fill(tokens[i] == 0 ? AnyShapeStyle(p.meterEmpty)
                              : last ? AnyShapeStyle(tone.fill)
                              : AnyShapeStyle(LinearGradient(colors: [b.light.opacity(p.dark ? 0.85 : 0.9), b.base.opacity(p.dark ? 0.55 : 0.7)],
                                                             startPoint: .top, endPoint: .bottom)))
                        .shadow(color: last ? tone.glow : .clear, radius: 3)
                        .frame(width: w, height: tokens[i] == 0 ? 2 : h)
                        .offset(x: CGFloat(i) * (w + gap))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
    }
}
