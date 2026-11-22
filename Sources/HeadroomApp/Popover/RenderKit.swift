import AppKit
import HeadroomKit
import HeadroomPresent

/// An interactive area produced while rendering (tooltips, menus, clicks).
struct HitRegion {
    enum Action: Equatable {
        case none
        case breakdownMenu(Provider)
        case openWeek(Provider, Int)
        case refresh
        case settings
        case tab(Int)
        case activityMode(Int)
        case activityRange(Int)
        /// The × on an Activity card's span chip: back to the whole range.
        case clearSelection
        case update
        case dismissUpdate
        /// Show or hide a run card's finished rows (and the rows past the cap).
        case toggleRun(String)
        /// Open or close one row's details: run id, row id.
        case toggleRow(String, String)
        /// The "···" menu on a run card.
        case runMenu(String)
        /// A button in a run card's question block.
        case runButton(String, RunButton)
        /// List every finished run of the last day, or go back to the few.
        case moreRecent
        /// The empty Runs tab's "Connect your agents".
        case connectAgents
        /// Open a run's own page from the Runs list.
        case openRun(String)
        /// Back from a run's page to the list.
        case closeRun
        /// Show or hide the finished runs folded into one line (Two-line's summary).
        case toggleFinished
    }

    enum RunButton: Equatable { case openSession, copyResume }
    var rect: CGRect
    var tooltip: String?
    var action: Action = .none
    /// Draws a hover fill of this corner radius over `rect` while the pointer is on it.
    var hover: CGFloat?
}

/// Collects hit regions during a render pass.
final class RenderOutput {
    var regions: [HitRegion] = []
    func add(_ rect: CGRect, tooltip: String? = nil, action: HitRegion.Action = .none, hover: CGFloat? = nil) {
        regions.append(HitRegion(rect: rect, tooltip: tooltip, action: action, hover: hover))
    }
}

/// CSS-like vertical metrics for SF: baseline for a line box of `lineHeight` starting at `top`.
func baseline(top: CGFloat, font: NSFont, lineHeight: CGFloat? = nil) -> CGFloat {
    let content = font.ascender - font.descender // descender is negative
    let lh = lineHeight ?? content
    return top + (lh - content) / 2 + font.ascender
}

/// Wrapped paragraph (Core Text frame) with a fixed line height.
struct TextBlock {
    let string: NSAttributedString
    let width: CGFloat
    let lineHeight: CGFloat

    init(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat, lineHeight: CGFloat, kern: CGFloat = 0) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        self.init(NSAttributedString(string: s, attributes: attributes), width: width, lineHeight: lineHeight)
    }

    /// Mixed runs (a command in mono, say). Line height is applied over the whole string.
    init(_ s: NSAttributedString, width: CGFloat, lineHeight: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        para.lineBreakMode = .byWordWrapping
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        string = m
        self.width = width
        self.lineHeight = lineHeight
        let setter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
    }

    private let lines: [CTLine]

    var height: CGFloat { CGFloat(max(lines.count, 1)) * lineHeight }

    func draw(x: CGFloat, top: CGFloat, in ctx: CGContext) {
        // Nothing to draw, and asking an empty string for an attribute raises.
        guard string.length > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return }
        for (i, line) in lines.enumerated() {
            let b = baseline(top: top + CGFloat(i) * lineHeight, font: font, lineHeight: lineHeight)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x, y: b)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}

extension CGContext {
    /// CSS `inset 0 dy blur color` shadow inside `path`.
    func innerShadow(_ path: CGPath, color: NSColor, blur: CGFloat, dy: CGFloat) {
        saveGState()
        addPath(path)
        clip()
        let big = path.boundingBox.insetBy(dx: -40, dy: -40)
        let ring = CGMutablePath()
        ring.addRect(big)
        ring.addPath(path)
        // Flipped view: CG shadow offsets are in base space (y up), so negate.
        setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: color.cgColor)
        addPath(ring)
        setFillColor(color.withAlphaComponent(1).cgColor)
        fillPath(using: .evenOdd)
        restoreGState()
    }
}

/// Card surface (PLAN §3.3, redesign §2): glass gradient, hairline and top highlight; on a provider
/// card, a top-edge light in the provider's tone; on a Limits card, a top-right glow in its state color.
enum CardChrome {
    /// - Parameters:
    ///   - provider: draws the top-edge light and wash in this provider's tone (rule 3). Nil for
    ///     cards that belong to no provider.
    ///   - state: the Limits card's pacing state, for the top-right state glow (rule 4). Only the
    ///     Limits card passes it; every other card gets the edge light alone.
    static func draw(_ rect: CGRect, provider: Provider?, theme: Theme, ctx: CGContext, radius: CGFloat = 14, state: PacingState? = nil) {
        let shape = rounded(rect, radius)
        if theme.isDark {
            ctx.fillVertical(shape, theme.cardTop, theme.cardBottom)
        } else {
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: black(0.05).cgColor)
                ctx.fill(shape, .white)
            }
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: black(0.04).cgColor)
                ctx.fill(shape, .white)
            }
        }
        if let provider {
            // radial-gradient(75% 64px at 16% 0%, tone 11% / 9%, transparent)
            ctx.fillRadial(in: shape, center: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY),
                           radii: CGSize(width: rect.width * 0.75, height: 64),
                           color: theme.providerTone(provider, ProviderTone.edgeWash(dark: theme.isDark)))
        }
        if let state {
            // radial-gradient(260px 170px at 100% 0%, glow, transparent 72%)
            ctx.fillRadial(in: shape, center: CGPoint(x: rect.maxX, y: rect.minY), radii: CGSize(width: 260, height: 170),
                           color: theme.stateGlow(state), fadeAt: 0.72)
        }
        if theme.isDark {
            ctx.innerStroke(shape, theme.cardBorder, width: 1)
            ctx.withState {
                ctx.addPath(shape); ctx.clip()
                let top = rounded(rect.offsetBy(dx: 0, dy: 1), radius)
                let ring = CGMutablePath(); ring.addPath(shape); ring.addPath(top)
                ctx.addPath(ring)
                ctx.setFillColor(theme.cardHighlight.cgColor)
                ctx.fillPath(using: .evenOdd)
            }
        } else {
            ctx.stroke(rounded(rect.insetBy(dx: -0.5, dy: -0.5), radius + 0.5), theme.cardBorder, width: 1)
        }
        if let provider { drawEdgeLight(rect, provider: provider, theme: theme, ctx: ctx, radius: radius) }
    }

    /// The 1.5 pt top-edge light: clear at 3% of the width, the tone at 90% (dark) or 75% (light)
    /// at 20%, clear again from 72%. Clipped to the card's corners.
    static func drawEdgeLight(_ rect: CGRect, provider: Provider, theme: Theme, ctx: CGContext, radius: CGFloat = 14) {
        let tone = theme.providerTone(provider)
        let peak = tone.fade(CGFloat(ProviderTone.edgeLight(dark: theme.isDark)))
        ctx.withState {
            ctx.addPath(rounded(rect, radius)); ctx.clip()
            let line = CGPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1.5), transform: nil)
            ctx.fillLinear(line, [tone.alpha(0), tone.alpha(0), peak, tone.alpha(0)],
                           from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY),
                           locations: [0, 0.03, 0.20, 0.72])
        }
    }
}

/// The segmented capsule meter with the even-pace caret (PLAN §3.4).
enum MeterRenderer {
    static let height: CGFloat = 22

    static func draw(_ m: MeterModel, rect: CGRect, theme: Theme, ctx: CGContext, segmentHeight: CGFloat = 16, gap: CGFloat = 3, pad: CGFloat = 3, trackRadius: CGFloat = 12, endRadius: CGFloat = 9, innerRadius: CGFloat = 4, glow: CGFloat = 12) {
        let track = rounded(rect, trackRadius)
        ctx.fill(track, theme.meterTrack)
        if theme.isDark {
            ctx.innerShadow(track, color: black(0.45), blur: 2, dy: 1)
            ctx.innerStroke(track, theme.meterTrackBorder, width: 0.5)
        } else {
            ctx.innerShadow(track, color: black(0.08), blur: 2, dy: 1)
        }
        let colors = theme.pacing(m.state)
        let inner = rect.insetBy(dx: pad, dy: pad)
        let w = (inner.width - gap * 4) / 5
        ctx.withState {
            ctx.setAlpha(CGFloat(m.opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for i in 0..<5 {
                let r = CGRect(x: inner.minX + CGFloat(i) * (w + gap), y: inner.minY, width: w, height: segmentHeight)
                let shape = rounded(r, left: i == 0 ? endRadius : innerRadius, right: i == 4 ? endRadius : innerRadius)
                if i < m.cells {
                    ctx.glow(shape, color: colors.glow, blur: glow, base: colors.bottom)
                    ctx.fillVertical(shape, colors.top, colors.bottom)
                    ctx.withState {
                        ctx.addPath(shape); ctx.clip()
                        let hi = CGMutablePath(); hi.addPath(shape); hi.addPath(rounded(r.offsetBy(dx: 0, dy: 1), left: i == 0 ? endRadius : innerRadius, right: i == 4 ? endRadius : innerRadius))
                        ctx.addPath(hi); ctx.setFillColor(white(0.62).cgColor); ctx.fillPath(using: .evenOdd)
                        let lo = CGMutablePath(); lo.addPath(shape); lo.addPath(rounded(r.offsetBy(dx: 0, dy: -1), left: i == 0 ? endRadius : innerRadius, right: i == 4 ? endRadius : innerRadius))
                        ctx.addPath(lo); ctx.setFillColor(black(0.12).cgColor); ctx.fillPath(using: .evenOdd)
                    }
                } else {
                    ctx.fill(shape, theme.meterEmpty)
                }
            }
            ctx.endTransparencyLayer()
        }
    }

    /// Caret row under the meter: ▲ ON TRACK at fraction τ along the track.
    static func drawCaret(at tau: Double, trackRect: CGRect, top: CGFloat, theme: Theme, ctx: CGContext) {
        let color = theme.isDark ? rgb(0xF4F4F6, 0.45) : rgb(0x1C1C1E, 0.45)
        let usable = trackRect.insetBy(dx: 3, dy: 0)
        let x = usable.minX + usable.width * CGFloat(min(max(tau, 0), 1))
        let label = Text("ON TRACK", F.sf(8.5, 650), color, kern: 0.765)
        let caretRect = CGRect(x: x - 3.5, y: top + 3.5, width: 7, height: 5)
        let labelOnLeft = x + 4 + label.width + 4 > trackRect.maxX
        Glyph.caret(in: caretRect, color: color, ctx: ctx)
        let mid = top + 6
        if labelOnLeft {
            label.draw(x: x - 3.5 - 4, capCenter: mid, align: .right, in: ctx)
        } else {
            label.draw(x: x + 3.5 + 4, capCenter: mid, in: ctx)
        }
    }
}

/// Verdict badge: glowing dot + state name in a tinted capsule.
enum BadgeRenderer {
    static func size(_ title: String) -> CGSize {
        CGSize(width: 8 + 7 + 7 + Text(title, F.sf(12.5, 650), .black).width + 10, height: 23)
    }

    static func draw(_ title: String, state: PacingState, origin: CGPoint, theme: Theme, ctx: CGContext) {
        let c = theme.pacing(state).text
        let s = size(title)
        let r = CGRect(origin: origin, size: s)
        let capsule = rounded(r, s.height / 2)
        ctx.fill(capsule, c.fade(0.13))
        ctx.innerStroke(capsule, c.fade(0.38), width: 0.5)
        let dot = CGMutablePath()
        dot.addEllipse(in: CGRect(x: r.minX + 8, y: r.midY - 3.5, width: 7, height: 7))
        ctx.withState {
            ctx.setShadow(offset: .zero, blur: 8, color: c.cgColor)
            ctx.fill(dot, c)
        }
        Text(title, F.sf(12.5, 650), c).draw(x: r.minX + 8 + 7 + 7, capCenter: r.midY, in: ctx)
    }
}

/// Status dot with a soft halo (freshness and footer).
func drawStatusDot(center: CGPoint, color: NSColor, ctx: CGContext) {
    let halo = CGMutablePath()
    halo.addEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
    ctx.fill(halo, color.fade(0.16))
    let dot = CGMutablePath()
    dot.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
    ctx.fill(dot, color)
}

/// Draws into an offscreen bitmap and returns it (shares, previews, measurement).
@MainActor
func renderImage(size: CGSize, scale: CGFloat = 2, appearance: NSAppearance? = nil, _ body: @escaping (CGContext) -> Void) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = size
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    // The context already maps points to pixels via rep.size.
    // Flip to a top-left origin like the popover's views.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    let work = { body(ctx) }
    if let appearance { appearance.performAsCurrentDrawingAppearance(work) } else { work() }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Renders a view's content on the CPU into a bitmap and hands it to the view's layer as contents.
///
/// When AppKit draws a view through `draw(_:)`, CoreAnimation may promote frequently redrawn
/// content to its accelerated CG renderer, which maps a ~190 MB Metal shader archive into the
/// process (measured: 135–171 MB peaks). Layer contents set from a finished CGImage are only
/// composited, so all popover views render through here.
@MainActor
enum CPUCanvas {
    static func image(for view: NSView, rect: NSRect? = nil, _ body: (CGContext) -> Void) -> CGImage? {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let r = (rect ?? view.bounds).integral
        let w = Int(r.width * scale), h = Int(r.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        view.effectiveAppearance.performAsCurrentDrawingAppearance { body(ctx) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Sets the rendered image as the view's layer contents (call from `updateLayer`).
    static func update(_ view: NSView, _ body: (CGContext) -> Void) {
        guard let layer = view.layer else { return }
        let image = Self.image(for: view, body)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.contentsGravity = .topLeft
        CATransaction.commit()
    }
}
