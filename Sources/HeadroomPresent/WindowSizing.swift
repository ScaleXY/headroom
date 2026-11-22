import Foundation

/// The popover's height and scroll position (redesign §4): one resting height for every tab, and
/// scroll to grow.
///
/// - The resting height is the Limits tab's natural height, capped at 660 pt and at the screen.
///   Every tab opens and switches at it; a shorter tab keeps it, with the footer at the bottom.
/// - Scrolling down first grows the window downward (top edge fixed), 1:1 with the scroll, up to the
///   tab's natural height or the screen. Only then does the content scroll.
/// - Scrolling up first scrolls the content back to the top; continuing then shrinks the window
///   toward the resting height, never below it.
///
/// Heights are in points. `chrome` is everything that isn't the scrolling card stack (header,
/// controls, banner, footer and padding), so the viewport is `height - chrome`.
public struct WindowSizing: Equatable, Sendable {
    /// The resting height never exceeds this, so the popover never fills a laptop screen.
    public static let restingCap: Double = 660

    /// min(Limits tab's natural height, 660, screen max).
    public static func resting(limitsNatural: Double, screenMax: Double) -> Double {
        max(0, min(limitsNatural, restingCap, screenMax))
    }

    public var resting: Double
    public var screenMax: Double
    public var chrome: Double
    /// The card stack's full height on the current tab.
    public var content: Double
    public private(set) var height: Double
    /// How far the card stack is scrolled.
    public private(set) var offset: Double

    public init(resting: Double, screenMax: Double, chrome: Double, content: Double, height: Double? = nil, offset: Double = 0) {
        self.resting = resting
        self.screenMax = screenMax
        self.chrome = chrome
        self.content = content
        self.height = height ?? resting
        self.offset = offset
        clamp()
    }

    /// The current tab's own height: its chrome and all of its cards.
    public var natural: Double { chrome + content }
    /// The tallest the window may grow on this tab: its natural height, or the screen.
    public var limit: Double { max(resting, min(natural, screenMax)) }
    public var viewport: Double { max(0, height - chrome) }
    public var maxOffset: Double { max(0, content - viewport) }
    /// Content sits below the visible area (the fade and the "Scroll for more" cue).
    public var hasMoreBelow: Bool { maxOffset - offset > 4 }

    /// Applies a scroll of `down` points (positive: toward the bottom of the content). `shrink`
    /// false keeps the window from shrinking (momentum after a flick to the top).
    public mutating func scroll(down: Double, shrink: Bool = true) {
        var dy = down
        if dy > 0 {
            let room = limit - height
            if room > 0 {
                let grow = min(dy, room)
                height += grow
                dy -= grow
            }
            offset = min(offset + dy, maxOffset)
        } else if dy < 0 {
            let back = min(-dy, offset)
            offset -= back
            dy += back
            if shrink, dy < 0, height > resting { height = max(resting, height + dy) }
        }
        clamp()
    }

    /// Back to the resting height, scrolled to the top (opening, switching tabs).
    public mutating func reset() {
        height = resting
        offset = 0
        clamp()
    }

    /// Keeps the height between the resting height and the limit, and the offset in range, after
    /// the content, the resting height or the screen changed.
    public mutating func clamp() {
        height = min(max(height, resting), limit)
        offset = min(max(offset, 0), maxOffset)
    }
}
