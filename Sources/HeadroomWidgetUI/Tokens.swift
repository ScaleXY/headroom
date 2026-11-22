import HeadroomKit
import SwiftUI

/// sRGB color from a hex literal, as in the app's `rgb(_:_:)`.
func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255, opacity: alpha)
}

func white(_ a: Double) -> Color { Color(.sRGB, white: 1, opacity: a) }
func black(_ a: Double) -> Color { Color(.sRGB, white: 0, opacity: a) }

/// The app's design tokens (`Theme`), resolved for one appearance.
public struct Palette {
    public let dark: Bool

    public init(_ scheme: ColorScheme) { dark = scheme == .dark }

    public var ink: Color { dark ? hex(0xF4F4F6) : hex(0x1C1C1E) }
    public var muted: Color { dark ? hex(0xF4F4F6, 0.58) : hex(0x1C1C1E, 0.55) }
    public var muted2: Color { dark ? hex(0xF4F4F6, 0.40) : hex(0x1C1C1E, 0.40) }
    public var faint: Color { dark ? hex(0xF4F4F6, 0.26) : hex(0x1C1C1E, 0.26) }

    public var cardSolid: Color { dark ? hex(0x1C1D22) : hex(0xFFFFFF) }
    public var groupFill: Color { dark ? black(0.22) : black(0.035) }
    public var groupBorder: Color { dark ? white(0.07) : black(0.05) }
    public var separator: Color { dark ? white(0.07) : black(0.07) }

    public var meterTrack: Color { dark ? black(0.32) : black(0.06) }
    public var meterTrackBorder: Color { dark ? white(0.06) : .clear }
    public var meterEmpty: Color { dark ? white(0.07) : black(0.085) }

    public var chartGrid: Color { dark ? white(0.05) : black(0.055) }
    public var chartLabel: Color { dark ? hex(0xF4F4F6, 0.42) : hex(0x1C1C1E, 0.45) }
    public var chartPill: Color { dark ? white(0.10) : black(0.06) }
    public var chartDash: Color { dark ? hex(0xF4F4F6, 0.30) : hex(0x1C1C1E, 0.28) }
    public var chipFill: Color { dark ? white(0.07) : black(0.045) }
    public var chipBorder: Color { dark ? white(0.07) : black(0.04) }

    public var ok: Color { hex(0x30D158) }
    public var stale: Color { hex(0xFFB020) }
    public var amber: Color { dark ? hex(0xFFC248) : hex(0xB87200) }
    public var rose: Color { dark ? hex(0xFF6982) : hex(0xD21F45) }
    public var azure: Color { dark ? hex(0x6AA8FF) : hex(0x1F6FEB) }

    public func tone(_ state: PacingState) -> Tone {
        switch (state, dark) {
        case (.plenty, true): Tone(top: hex(0x8CC2FF), bottom: hex(0x4A8EFF), glow: hex(0x4A8EFF, 0.55), text: hex(0x6AA8FF))
        case (.plenty, false): Tone(top: hex(0x64A8FF), bottom: hex(0x2270F0), glow: hex(0x2270F0, 0.30), text: hex(0x1F6FEB))
        case (.onPace, true): Tone(top: hex(0xFFFFFF), bottom: hex(0xD3D6DD), glow: white(0.28), text: hex(0xECEDF1))
        case (.onPace, false): Tone(top: hex(0x50535B), bottom: hex(0x25272C), glow: black(0.16), text: hex(0x2A2C31))
        case (.tight, true): Tone(top: hex(0xFFDA7A), bottom: hex(0xF4A51F), glow: hex(0xF4A51F, 0.50), text: hex(0xFFC248))
        case (.tight, false): Tone(top: hex(0xFFCB55), bottom: hex(0xE99200), glow: hex(0xE99200, 0.30), text: hex(0xB87200))
        case (.veryTight, true): Tone(top: hex(0xFF8FA2), bottom: hex(0xEE3459), glow: hex(0xEE3459, 0.55), text: hex(0xFF6982))
        case (.veryTight, false): Tone(top: hex(0xFF6F86), bottom: hex(0xDD2448), glow: hex(0xDD2448, 0.30), text: hex(0xD21F45))
        }
    }

    /// The provider's tone (Claude clay, Codex jade) at `strength` opacity: marks, plan pills, the
    /// card's top-edge light and Activity data. Named strengths live on `ProviderTone`
    /// (`cachedReads`, `newInput`, `output`, `modelBar`, `pastWeek`, `pillFill`, `pillStroke`, ...).
    /// A tone is a signature: it never glows.
    public func providerTone(_ provider: Provider, _ strength: Double = 1) -> Color {
        hex(ProviderTone.hex(provider, dark: dark), strength)
    }

    /// The Limits card's top-right glow in the state color (signals glow; tones never do).
    public func stateGlow(_ state: PacingState) -> Color {
        let g = state.cardGlow(dark: dark)
        return hex(g.hex, g.alpha)
    }

    /// The Limits lane's neutral bars: ink at 34% (26% on light, where ink is darker).
    public var laneBar: Color { ink.opacity(dark ? 0.34 : 0.26) }
    /// The running session's outline below the warning level, and the lane's key.
    public var laneBarStrong: Color { ink.opacity(dark ? 0.62 : 0.55) }

    /// A 5-hour session's bar: neutral, amber from the warning level, rose once it hit the limit.
    public func laneSession(peak: Double, hit: Bool, warnAt: Double = 0.75) -> Color {
        hit || peak >= 0.999 ? rose : peak >= warnAt - 1e-9 ? amber : laneBar
    }

    /// The neutral mark tile `BrandTile` draws (the mark sits on it in the provider's tone).
    public var markTileTop: Color { dark ? hex(0x34363C) : hex(0xFFFFFF) }
    public var markTileBottom: Color { dark ? hex(0x232428) : hex(0xF1F1F4) }
    public var markTileStroke: Color { dark ? white(0.12) : black(0.08) }
    public var markTileHighlight: Color { dark ? white(0.10) : white(1) }
    public var markTileShadow: Color { dark ? black(0.35) : black(0.10) }

    /// The 5-hour level's color: the forecast's pacing tone until it warns, then amber and rose.
    public func session(_ s: WidgetSession) -> Tone {
        switch s.level {
        case .normal: tone(s.tone)
        case .amber: tone(.tight)
        case .rose, .blocked: tone(.veryTight)
        }
    }
}

public struct Tone {
    public let top: Color
    public let bottom: Color
    public let glow: Color
    /// Text, dot and chart line color.
    public let text: Color

    public var fill: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom) }

    public init(top: Color, bottom: Color, glow: Color, text: Color) {
        self.top = top
        self.bottom = bottom
        self.glow = glow
        self.text = text
    }
}

/// Brand identity colors (`Brand` in the app): identity only, never a pacing state. In the UI a
/// provider is drawn in its tone (`BrandColors.tone`, `Palette.providerTone`); these stay for pure identity.
public struct BrandColors {
    public let base: Color, light: Color, tileTop: Color, tileBottom: Color, markInk: Color, orbDark: Color, orbLight: Color

    public static func of(_ p: Provider) -> BrandColors {
        switch p {
        case .claude: BrandColors(base: hex(0xD97757), light: hex(0xF0A084), tileTop: hex(0xE8956F), tileBottom: hex(0xC65F3C),
                                  markInk: hex(0xFFF6EF), orbDark: hex(0xD97757, 0.24), orbLight: hex(0xD97757, 0.13))
        case .codex: BrandColors(base: hex(0x10A37F), light: hex(0x3FD0A3), tileTop: hex(0x22C496), tileBottom: hex(0x0A7D61),
                                 markInk: hex(0xFFFFFF), orbDark: hex(0x10A37F, 0.20), orbLight: hex(0x10A37F, 0.11))
        }
    }

    public func pill(_ p: Palette) -> Color { p.dark ? light : base }

    /// The provider's tone for `palette` at `strength` opacity (same as `Palette.providerTone`).
    public static func tone(_ provider: Provider, _ palette: Palette, _ strength: Double = 1) -> Color {
        palette.providerTone(provider, strength)
    }

    public init(base: Color, light: Color, tileTop: Color, tileBottom: Color, markInk: Color, orbDark: Color, orbLight: Color) {
        self.base = base; self.light = light; self.tileTop = tileTop; self.tileBottom = tileBottom
        self.markInk = markInk; self.orbDark = orbDark; self.orbLight = orbLight
    }
}

extension WidgetSession {
    /// The forecast as a pacing color (`SessionForecast.pacingState`).
    public var tone: PacingState {
        switch outlook {
        case .idle: .plenty
        case .blocked: .veryTight
        case .runsOut: left < 0.15 ? .veryTight : .tight
        case .lasts: left < 0.10 ? .tight : .onPace
        case .comfortable: (leftAtReset ?? left) >= 0.4 ? .plenty : .onPace
        }
    }
}

/// Type in the app's voice: SF with the mockup's weights and tracking.
public enum Fonts {
    /// Small capitals label: "ON TRACK", "5-HOUR".
    public static func caps(_ size: CGFloat = 8.5, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight) }
    public static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight).monospacedDigit() }
    public static func text(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}
