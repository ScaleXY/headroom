import AppKit
import HeadroomKit
import HeadroomPresent

/// A run's own page, opened from the Runs list, in the style Settings picks (Briefing, Lanes).
@MainActor
enum RunPageRenderer {
    /// The run as one card. Returns the height.
    @discardableResult
    static func draw(_ card: RunCardModel, style: RunPageStyle, origin: CGPoint, width: CGFloat, theme t: Theme, ctx: CGContext?,
                     out: RenderOutput? = nil) -> CGFloat {
        0 // Drawn by the page workstream.
    }
}
