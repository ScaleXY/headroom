import AppKit
import HeadroomArt
import HeadroomKit

/// The real Claude and OpenAI marks, read from `assets/brand/*.svg` (copied into the app's
/// Resources by `make app`). 24×24 viewBox.
@MainActor
enum BrandMark {
    static func path(_ provider: Provider) -> CGPath {
        BrandPaths.path(named: provider == .claude ? "claude" : "openai")
    }

    /// Draws the mark filling `rect` (square) in `color`.
    static func draw(_ provider: Provider, in rect: CGRect, color: NSColor, ctx: CGContext) {
        let s = rect.width / 24
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: s, y: s)
        guard let scaled = path(provider).copy(using: &t) else { return }
        ctx.fill(scaled, color)
    }

    /// The provider tile (spec §2 rule 1): the real mark in the provider's tone on a neutral
    /// Headroom tile. Dark: `#34363C`→`#232428` with a 0.5 pt white 12% inner stroke, a 1 pt white 10%
    /// top highlight and a small drop shadow. Light: `#FFFFFF`→`#F1F1F4` with a 0.5 pt black 8% stroke.
    static func drawTile(_ provider: Provider, in rect: CGRect, theme: Theme, ctx: CGContext, shadow: Bool = true) {
        let k = rect.width / 26
        let r = rect.width * 0.3
        let shape = rounded(rect, r)
        if shadow {
            // 0 1px 3px rgba(0,0,0,.35 / .10), scaled from the 26 pt mockup tile.
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -1 * k), blur: 3 * k, color: theme.markTileShadow.cgColor)
                ctx.fill(shape, theme.markTileBottom)
            }
        }
        ctx.fillVertical(shape, theme.markTileTop, theme.markTileBottom)
        // inset 0 1px 0 highlight along the top edge.
        ctx.withState {
            ctx.addPath(shape); ctx.clip()
            let ring = CGMutablePath(); ring.addPath(shape); ring.addPath(rounded(rect.offsetBy(dx: 0, dy: 1), r))
            ctx.addPath(ring)
            ctx.setFillColor(theme.markTileHighlight.cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.innerStroke(shape, theme.markTileStroke, width: 0.5)
        let markSide = rect.width * 0.58
        let m = CGRect(x: rect.midX - markSide / 2, y: rect.midY - markSide / 2, width: markSide, height: markSide)
        draw(provider, in: m, color: theme.providerTone(provider), ctx: ctx)
    }
}

/// The Headroom meter-H (`assets/icon.svg`), drawn natively so the glow survives at any size.
enum HeadroomMark {
    static let cellColors: [UInt32] = [0x4A8EFF, 0x7DB4FF, 0xECEDF1, 0xFFC248, 0xFF6982]

    /// Draws the full app-icon tile into `rect` (square). 64-unit geometry from the SVG.
    static func draw(in rect: CGRect, ctx: CGContext, dropShadow: Bool = true) {
        let s = rect.width / 64
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        let bg = rounded(R(0, 0, 64, 64), 15 * s)
        if dropShadow {
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * s * 64 / 26), blur: 5 * s * 64 / 26, color: black(0.25).cgColor)
                ctx.fill(bg, rgb(0x1A1C22))
            }
        }
        ctx.fillLinear(bg, [rgb(0x2E313B), rgb(0x0E0F13)], from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.stroke(rounded(R(0.5, 0.5, 63, 63), 14.5 * s), white(0.12), width: max(s, 0.5))

        var lit: [(CGRect, NSColor)] = []
        var ghost: [(CGRect, NSColor)] = []
        for x in [16.0, 38.0] {
            for i in 0..<5 {
                let y = 51.8 - 6.2 - 8.7 * Double(i)
                let cell = (R(x, y, 10, 6.2), rgb(cellColors[i]))
                if i < 3 { lit.append(cell) } else { ghost.append(cell) }
            }
        }
        // Glow: blurred copy of the lit cells at 55% (feGaussianBlur stdDeviation 1.8).
        ctx.withState {
            ctx.setAlpha(0.55)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for (r, c) in lit {
                ctx.setShadow(offset: .zero, blur: 1.8 * 2 * s, color: c.cgColor)
                ctx.fill(rounded(r, 2.6 * s), c)
            }
            ctx.endTransparencyLayer()
        }
        for (r, c) in lit { ctx.fill(rounded(r, 2.6 * s), c) }
        ctx.fill(rounded(R(24, 28.8, 16, 5), 2.2 * s), rgb(0xECEDF1))
        for (r, c) in ghost { ctx.fill(rounded(r, 2.6 * s), c.alpha(0.27)) }
    }
}
