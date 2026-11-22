import Foundation

/// Provider tones: Claude's clay and Codex's jade, recut onto Headroom's palette (the same
/// lightness and chroma as the state colors; only the hue is the provider's). One source for the
/// Mac (`Brand.tone`) and SwiftUI (`BrandColors.tone`, `Palette.providerTone`).
///
/// A tone is a signature, never a signal: it draws marks, plan pills, the card's top-edge light
/// and data where the provider is the subject (Activity). It never glows, tints a card or overrides
/// a state color.
public enum ProviderTone {
    /// sRGB hex of the provider's tone for one appearance.
    public static func hex(_ provider: Provider, dark: Bool) -> UInt32 {
        switch (provider, dark) {
        case (.claude, true): 0xE89270
        case (.claude, false): 0xC06240
        case (.codex, true): 0x6ACAA7
        case (.codex, false): 0x268769
        }
    }

    // MARK: Strengths (alpha of the tone)

    /// Activity data: cached reads, new input and output.
    public static let cachedReads = 0.26
    public static let newInput = 0.62
    public static let output = 1.0
    /// Activity's by-model bars.
    public static let modelBar = 0.85
    /// Past weeks: lit cells, and the current week's lit cells.
    public static let pastWeek = 0.80
    public static let pastWeekCurrent = 0.32
    /// Plan pill fill and its 0.5 pt inner stroke.
    public static let pillFill = 0.10
    public static let pillStroke = 0.42

    /// The card's 1.5 pt top-edge light at its brightest.
    public static func edgeLight(dark: Bool) -> Double { dark ? 0.90 : 0.75 }
    /// The soft wash under the edge light.
    public static func edgeWash(dark: Bool) -> Double { dark ? 0.11 : 0.09 }
}

extension PacingState {
    /// The Limits card's top-right state glow (sRGB hex and alpha) for one appearance.
    public func cardGlow(dark: Bool) -> (hex: UInt32, alpha: Double) {
        switch (self, dark) {
        case (.plenty, true): (0x4A8EFF, 0.16)
        case (.plenty, false): (0x2270F0, 0.08)
        case (.onPace, true): (0xFFFFFF, 0.07)
        case (.onPace, false): (0x000000, 0.025)
        case (.tight, true): (0xF4A51F, 0.17)
        case (.tight, false): (0xE99200, 0.08)
        case (.veryTight, true): (0xEE3459, 0.20)
        case (.veryTight, false): (0xDD2448, 0.08)
        }
    }
}
