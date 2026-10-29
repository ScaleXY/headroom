import AppKit
import HeadroomKit

/// The update banner under the popover header: what's new, one button, and a quiet way to put it off.
/// While it downloads and installs, the button gives way to progress.
@MainActor
enum UpdateBannerRenderer {
    static let height: CGFloat = 58
    /// Space the banner takes in the popover, gap included.
    static let space: CGFloat = height + 10

    static func shows(_ updater: AppUpdater?) -> Bool {
        guard let updater, let version = updater.state.version else { return false }
        switch updater.state {
        case .downloading, .installing: return true
        default: return updater.snoozed != version
        }
    }

    static func draw(_ state: AppUpdater.State, rect r: CGRect, theme t: Theme, ctx: CGContext, out: RenderOutput?, hovered: HitRegion.Action? = nil) {
        guard let version = state.version else { return }
        let accent = t.pacing(.plenty)
        CardChrome.draw(r, provider: nil, theme: t, ctx: ctx, radius: 18)
        let shape = rounded(r, 18)
        // A blue wash from the icon side, like the provider orbs.
        ctx.fillRadial(in: shape, center: CGPoint(x: r.minX, y: r.midY), radii: CGSize(width: 220, height: 90),
                       color: accent.bottom.fade(t.isDark ? 0.22 : 0.12), fadeAt: 0.85)
        ctx.innerStroke(shape, accent.bottom.fade(t.isDark ? 0.45 : 0.3), width: 1)

        let icon = CGRect(x: r.minX + 12, y: r.midY - 17, width: 34, height: 34)
        let iconShape = rounded(icon, 10)
        ctx.glow(iconShape, color: accent.glow.fade(0.8), blur: 10, base: accent.bottom)
        ctx.fillVertical(iconShape, accent.top, accent.bottom)
        ctx.withState {
            ctx.addPath(iconShape); ctx.clip()
            ctx.fill(CGPath(rect: CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: 0.75), transform: nil), white(0.4))
        }
        CanvasControlView.drawSymbol("arrow.down", in: icon.insetBy(dx: 9.5, dy: 9), color: .white, weight: .bold, ctx: ctx)

        let (title, detail) = copy(state, version: version)
        let tx = icon.maxX + 12
        var progress: Double?? = nil
        switch state {
        case .available, .ready:
            // Later: a small close glyph in the corner.
            let close = CGRect(x: r.maxX - 23, y: r.minY + 8, width: 15, height: 15)
            if hovered == .dismissUpdate { ctx.fill(CGPath(ellipseIn: close.insetBy(dx: -3, dy: -3), transform: nil), t.isDark ? white(0.08) : black(0.06)) }
            CanvasControlView.drawSymbol("xmark", in: close.insetBy(dx: 3.5, dy: 3.5), color: t.muted, weight: .bold, ctx: ctx)
            out?.add(close.insetBy(dx: -5, dy: -5), tooltip: "Remind me later", action: .dismissUpdate)
            let label = { if case .ready = state { "Restart" } else { "Update" } }()
            let b = pill(label, right: r.maxX - 32, mid: r.midY, hover: hovered == .update, theme: t, ctx: ctx)
            out?.add(b, action: .update)
        case .downloading(_, let p):
            progress = .some(p)
        case .installing:
            progress = .some(nil)
        default: break
        }
        Text(title, F.sf(13, 650), t.ink, kern: -0.1).draw(x: tx, capCenter: r.midY - 8, in: ctx)
        Text(detail, F.sf(11.5, 500), t.muted).draw(x: tx, capCenter: r.midY + 10, in: ctx)

        if let p = progress {
            let track = CGRect(x: tx, y: r.maxY - 9, width: r.maxX - 16 - tx, height: 3)
            ctx.fill(rounded(track, 1.5), t.meterTrack)
            // Unknown progress (installing) fills the track; the copy says what's happening.
            let fill = CGRect(x: track.minX, y: track.minY, width: max(3, track.width * (p ?? 1)), height: track.height)
            ctx.fillVertical(rounded(fill, 1.5), accent.top, accent.bottom)
        }
    }

    static func copy(_ state: AppUpdater.State, version v: String) -> (String, String) {
        switch state {
        case .ready: ("Restart to update", "Version \(v) is ready")
        case .downloading(_, let p): ("Downloading \(v)", p.map { "\(Int(($0 * 100).rounded()))% · Headroom reopens when done" } ?? "Headroom reopens when done")
        case .installing: ("Installing \(v)", "Headroom reopens on its own.")
        default: ("Update available", "Version \(v)")
        }
    }

    /// A compact ink pill, the popover's version of Settings' primary button.
    private static func pill(_ title: String, right: CGFloat, mid: CGFloat, hover: Bool, theme t: Theme, ctx: CGContext) -> CGRect {
        let font = F.sf(12, 650)
        let label = Text(title, font, .black)
        let r = CGRect(x: right - label.width - 24, y: mid - 13, width: label.width + 24, height: 26)
        let shape = rounded(r, 13)
        let accent = t.pacing(.plenty)
        ctx.withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: accent.glow.fade(hover ? 0.9 : 0.6).cgColor)
            ctx.fill(shape, accent.bottom)
        }
        ctx.fillVertical(shape, hover ? accent.top.blended(withFraction: 0.15, of: .white) ?? accent.top : accent.top, accent.bottom)
        Text(title, font, .white).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
        return r
    }
}
