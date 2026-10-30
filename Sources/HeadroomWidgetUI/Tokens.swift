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
struct Palette {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    var ink: Color { dark ? hex(0xF4F4F6) : hex(0x1C1C1E) }
    var muted: Color { dark ? hex(0xF4F4F6, 0.58) : hex(0x1C1C1E, 0.55) }
    var muted2: Color { dark ? hex(0xF4F4F6, 0.40) : hex(0x1C1C1E, 0.40) }
    var faint: Color { dark ? hex(0xF4F4F6, 0.26) : hex(0x1C1C1E, 0.26) }

    var cardSolid: Color { dark ? hex(0x1C1D22) : hex(0xFFFFFF) }
    var groupFill: Color { dark ? black(0.22) : black(0.035) }
    var groupBorder: Color { dark ? white(0.07) : black(0.05) }
    var separator: Color { dark ? white(0.07) : black(0.07) }

    var meterTrack: Color { dark ? black(0.32) : black(0.06) }
    var meterTrackBorder: Color { dark ? white(0.06) : .clear }
    var meterEmpty: Color { dark ? white(0.07) : black(0.085) }

    var chartGrid: Color { dark ? white(0.05) : black(0.055) }
    var chartLabel: Color { dark ? hex(0xF4F4F6, 0.42) : hex(0x1C1C1E, 0.45) }
    var chartPill: Color { dark ? white(0.10) : black(0.06) }
    var chartDash: Color { dark ? hex(0xF4F4F6, 0.30) : hex(0x1C1C1E, 0.28) }
    var chipFill: Color { dark ? white(0.07) : black(0.045) }
    var chipBorder: Color { dark ? white(0.07) : black(0.04) }

    var ok: Color { hex(0x30D158) }
    var stale: Color { hex(0xFFB020) }
    var amber: Color { dark ? hex(0xFFC248) : hex(0xB87200) }
    var rose: Color { dark ? hex(0xFF6982) : hex(0xD21F45) }
    var azure: Color { dark ? hex(0x6AA8FF) : hex(0x1F6FEB) }

    func tone(_ state: PacingState) -> Tone {
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

    /// The 5-hour level's color: the forecast's pacing tone until it warns, then amber and rose.
    func session(_ s: WidgetSession) -> Tone {
        switch s.level {
        case .normal: tone(s.tone)
        case .amber: tone(.tight)
        case .rose, .blocked: tone(.veryTight)
        }
    }
}

struct Tone {
    let top: Color
    let bottom: Color
    let glow: Color
    /// Text, dot and chart line color.
    let text: Color

    var fill: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom) }
}

/// Brand identity colors (`Brand` in the app): identity only, never a pacing state.
struct BrandColors {
    let base: Color, light: Color, tileTop: Color, tileBottom: Color, markInk: Color, orbDark: Color, orbLight: Color

    static func of(_ p: Provider) -> BrandColors {
        switch p {
        case .claude: BrandColors(base: hex(0xD97757), light: hex(0xF0A084), tileTop: hex(0xE8956F), tileBottom: hex(0xC65F3C),
                                  markInk: hex(0xFFF6EF), orbDark: hex(0xD97757, 0.24), orbLight: hex(0xD97757, 0.13))
        case .codex: BrandColors(base: hex(0x10A37F), light: hex(0x3FD0A3), tileTop: hex(0x22C496), tileBottom: hex(0x0A7D61),
                                 markInk: hex(0xFFFFFF), orbDark: hex(0x10A37F, 0.20), orbLight: hex(0x10A37F, 0.11))
        }
    }

    func pill(_ p: Palette) -> Color { p.dark ? light : base }
}

extension WidgetSession {
    /// The forecast as a pacing color (`SessionForecast.pacingState`).
    var tone: PacingState {
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
enum Fonts {
    /// Small capitals label: "EVEN PACE", "5-HOUR".
    static func caps(_ size: CGFloat = 8.5, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight) }
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight).monospacedDigit() }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}
