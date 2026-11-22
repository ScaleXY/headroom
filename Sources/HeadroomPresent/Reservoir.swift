import Foundation
import HeadroomKit

/// The Limits card's reservoir: a rounded track filled from the left to what's left, the big
/// number, and the renewal in a frosted tag at the right end. One source for the Mac's renderer
/// and the iPhone's view: the colors per state, the sizes, and the rule that keeps text off the
/// fill's edge.
public enum Reservoir {
    // MARK: Sizes (points)

    public static let height: Double = 88
    public static let radius: Double = 20
    /// The big number, its raised "%" and the line under it.
    public static let numberSize: Double = 48
    public static let percentScale: Double = 0.42
    public static let labelSize: Double = 11.5
    /// Where the number sits inside the fill, the room it keeps from the fill's edge, and its
    /// gap past the edge when it rides on the track.
    public static let insideX: Double = 18
    public static let insideGap: Double = 16
    public static let outsideGap: Double = 14
    public static let outsideMinX: Double = 16
    /// The renewal tag: height, corners, inset from the right end, text padding, and the gap the
    /// number keeps from it.
    public static let tagHeight: Double = 58
    public static let tagRadius: Double = 15
    public static let tagInset: Double = 11
    public static let tagPadding: Double = 13
    public static let tagMinText: Double = 62
    public static let tagGap: Double = 10
    /// The lit edge at the end of the fill: its width and its inset from the top and bottom.
    public static let edgeWidth: Double = 2
    public static let edgeInset: Double = 9

    /// The tag's width for its widest line of text.
    public static func tagWidth(textWidth: Double) -> Double {
        let text = max(textWidth, tagMinText)
        return (text + tagPadding * 2).rounded(.up)
    }

    /// How far the fill reaches across a track `width` wide at `percentLeft`.
    public static func fillWidth(percentLeft: Int, width: Double) -> Double {
        let clamped = Double(min(max(percentLeft, 0), 100))
        return width * clamped / 100
    }

    /// No lit edge at a full reservoir.
    public static func isFull(percentLeft: Int) -> Bool { percentLeft >= 100 }

    // MARK: Placement

    /// The closest the number may come to the fill's edge when a wide tag leaves no room past it.
    public static let insideMinGap: Double = 10
    /// The smallest the number is drawn when it can neither sit inside nor ride past the edge in full.
    public static let minScale: Double = 0.6

    public struct Placement: Equatable, Sendable {
        /// On the fill (in the state's ink) or on the track past the fill's edge (in the state's color).
        public var inside: Bool
        /// The number's left edge.
        public var x: Double
        /// The room for the line under the number before it would meet the fill's edge or the tag.
        public var labelRoom: Double
        /// The number's size relative to `numberSize`: 1 except in a squeeze (see `place`).
        public var scale: Double

        public init(inside: Bool, x: Double, labelRoom: Double, scale: Double = 1) {
            self.inside = inside
            self.x = x
            self.labelRoom = labelRoom
            self.scale = scale
        }
    }

    /// Where the number goes so no text ever crosses the fill's edge or runs under the tag.
    ///
    /// 1. Inside the fill at `insideX`, when the whole block (the number with its "%" and the line
    ///    under it) fits there with `insideGap` to spare.
    /// 2. Otherwise just past the edge, `outsideGap` beyond it, when the block fits before the tag.
    /// 3. When a wide tag leaves room for neither, inside with `insideMinGap` to spare, if the number
    ///    fits there; the line under it is cut to its room.
    /// 4. Failing that, past the edge with the number drawn smaller to clear the tag.
    /// - Parameters:
    ///   - fill: the fill's width (0 when the fill isn't drawn).
    ///   - number: the width of the number with its "%" at full size.
    ///   - label: the width of the line under it.
    ///   - right: the furthest any text may reach: the tag's left edge less `tagGap`, or the track's end.
    public static func place(fill: Double, number: Double, label: Double, right: Double) -> Placement {
        let block = max(number, label)
        let insideLimit = min(fill - insideGap, right)
        if insideX + block <= insideLimit {
            return Placement(inside: true, x: insideX, labelRoom: insideLimit - insideX)
        }
        let outsideX = max(outsideMinX, fill + outsideGap)
        let outsideRoom = max(0, right - outsideX)
        if block <= outsideRoom {
            return Placement(inside: false, x: outsideX, labelRoom: outsideRoom)
        }
        let squeezedLimit = min(fill - insideMinGap, right)
        if insideX + number <= squeezedLimit {
            return Placement(inside: true, x: insideX, labelRoom: squeezedLimit - insideX)
        }
        let fit = number > 0 ? outsideRoom / number : 1
        return Placement(inside: false, x: outsideX, labelRoom: outsideRoom, scale: min(1, max(minScale, fit)))
    }

    // MARK: Colors

    /// sRGB hex and alpha.
    public struct Color: Equatable, Sendable {
        public var hex: UInt32
        public var alpha: Double

        public init(_ hex: UInt32, _ alpha: Double = 1) {
            self.hex = hex
            self.alpha = alpha
        }
    }

    /// One state's fill: a horizontal gradient from `deep` at the left to `light` at the edge, its
    /// glow, the ink for text on it, and the state's color for text on the track.
    public struct Palette: Equatable, Sendable {
        public var light: Color
        public var deep: Color
        public var ink: Color
        public var text: Color
        public var glow: Color
        /// Text on the track uses the card's ink rather than `text` (On track: the state color is near-white).
        public var plainOnTrack: Bool
    }

    public static func palette(_ state: PacingState, dark: Bool) -> Palette {
        switch (state, dark) {
        case (.plenty, true):
            Palette(light: Color(0x8EC3FF), deep: Color(0x3F86FB), ink: Color(0xFFFFFF), text: Color(0x6AA8FF), glow: Color(0x4A8EFF, 0.45), plainOnTrack: false)
        case (.onPace, true):
            // Pearl, a step darker than white, so the slab doesn't glare.
            Palette(light: Color(0xE6E8ED), deep: Color(0xAEB2BC), ink: Color(0x141519), text: Color(0xECEDF1), glow: Color(0xECEDF1, 0.18), plainOnTrack: true)
        case (.tight, true):
            Palette(light: Color(0xFFD877), deep: Color(0xEE9C14), ink: Color(0x2A1A00), text: Color(0xFFC248), glow: Color(0xF4A51F, 0.42), plainOnTrack: false)
        case (.veryTight, true):
            Palette(light: Color(0xFF8EA1), deep: Color(0xE62E54), ink: Color(0xFFFFFF), text: Color(0xFF6982), glow: Color(0xEE3459, 0.45), plainOnTrack: false)
        case (.plenty, false):
            Palette(light: Color(0x5CA3FF), deep: Color(0x1F6BE8), ink: Color(0xFFFFFF), text: Color(0x1F6FEB), glow: Color(0x2270F0, 0.25), plainOnTrack: false)
        case (.onPace, false):
            // Graphite.
            Palette(light: Color(0x4C4F57), deep: Color(0x25272C), ink: Color(0xFFFFFF), text: Color(0x2A2C31), glow: Color(0x000000, 0.12), plainOnTrack: true)
        case (.tight, false):
            Palette(light: Color(0xFFCB55), deep: Color(0xE38D00), ink: Color(0x2A1A00), text: Color(0xB87200), glow: Color(0xE99200, 0.25), plainOnTrack: false)
        case (.veryTight, false):
            Palette(light: Color(0xFF6F86), deep: Color(0xD81E45), ink: Color(0xFFFFFF), text: Color(0xD21F45), glow: Color(0xDD2448, 0.25), plainOnTrack: false)
        }
    }

    /// The recessed track and its hairline.
    public static func track(dark: Bool) -> (fill: Color, stroke: Color) {
        dark ? (Color(0x000000, 0.36), Color(0xFFFFFF, 0.07)) : (Color(0x000000, 0.055), Color(0x000000, 0.06))
    }

    /// The frosted tag: fill, hairline, shadow, and (dark only) a top highlight.
    public static func tag(dark: Bool) -> (fill: Color, stroke: Color, shadow: Color, highlight: Color?) {
        dark ? (Color(0x0C0D10, 0.58), Color(0xFFFFFF, 0.10), Color(0x000000, 0.35), Color(0xFFFFFF, 0.09))
            : (Color(0xFFFFFF, 0.84), Color(0x000000, 0.07), Color(0x000000, 0.08), nil)
    }
}
