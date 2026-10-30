import AppKit
import HeadroomKit
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

// Renders every widget, family, sample state and appearance to PNGs on a desktop-like backdrop:
//   HeadroomWidgetPreview <out-dir> [--live]
// `--live` adds the current `widgets.json` (what the installed widgets show right now);
// `--feed <file>` adds a feed written by `HeadroomApp --render widget-feed`, drawn at its own time;
// `--mobile` draws the iPhone, iPad and Watch surfaces instead: complications in color and tinted,
// the Lock Screen, the session Live Activity and the iPhone-only widgets, from the demo accounts.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: HeadroomWidgetPreview <out-dir> [--live]")
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func size(_ family: WidgetFamily) -> CGSize {
    switch family {
    case .systemSmall: CGSize(width: 164, height: 164)
    case .systemMedium: CGSize(width: 344, height: 164)
    case .systemExtraLarge: CGSize(width: 715, height: 330)
    default: CGSize(width: 344, height: 344)
    }
}

func name(_ family: WidgetFamily) -> String {
    switch family {
    case .systemSmall: "small"
    case .systemMedium: "medium"
    case .systemExtraLarge: "xl"
    default: "large"
    }
}

/// One widget as it sits on the desktop: its surface, clipped to the system's corner radius, with a shadow.
struct Tile: View {
    var kind: HeadroomWidgetKind
    var family: WidgetFamily
    var feed: WidgetFeed?
    var now: Date

    var body: some View {
        let s = size(family)
        ZStack {
            HeadroomWidgetView.surface(kind: kind, feed: feed)
            HeadroomWidgetView(kind: kind, family: family, feed: feed, now: now)
        }
        .frame(width: s.width, height: s.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// A wallpaper-ish backdrop so the widget edge reads as it would on a desktop.
struct Backdrop: View {
    var dark: Bool
    var body: some View {
        LinearGradient(colors: dark ? [Color(red: 0.10, green: 0.13, blue: 0.31), Color(red: 0.23, green: 0.16, blue: 0.36), Color(red: 0.06, green: 0.18, blue: 0.27)]
                                    : [Color(red: 0.84, green: 0.89, blue: 0.97), Color(red: 0.96, green: 0.89, blue: 0.93), Color(red: 0.85, green: 0.93, blue: 0.91)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

@MainActor
func render(_ view: some View, to file: String) {
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let cg = r.cgImage else { print("failed: \(file)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(file))
}

var now = Date()

if args.contains("--mobile") {
    var mobileCount = 0
    for scenario in DemoRecords.Scenario.allCases {
        let feed = ReaderFeed.build(AccountReader(now: now).read(DemoRecords.make(scenario, now: now)), now: now)
        let focus = feed.focus
        let second = feed.providers.first { $0.key != focus?.key && ($0.week != nil || $0.session != nil) }
        // Complications: every kind and shape, in full color and tinted, on dark and light faces.
        for dark in [true, false] {
            for tint in [AccessoryTint.color, .mono] {
                let sheet = VStack(alignment: .leading, spacing: 18) {
                    ForEach(ComplicationKind.allCases, id: \.self) { kind in
                        HStack(alignment: .center, spacing: 18) {
                            Text(kind.title).font(.system(size: 11, weight: .semibold)).frame(width: 96, alignment: .leading)
                            ForEach(kind.shapes.filter { $0 != .corner }, id: \.self) { shape in
                                ComplicationView(kind: kind, shape: shape, provider: focus, second: second, generatedAt: feed.generatedAt, now: now)
                                    .frame(width: shape == .circular ? 72 : (shape == .rectangular ? 172 : 230), height: shape == .circular ? 72 : (shape == .rectangular ? 76 : 20))
                            }
                        }
                    }
                }
                .foregroundStyle(dark ? .white : .black)
                .padding(28)
                .background(Backdrop(dark: dark))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.accessoryTint, tint)
                .environment(\.staticTimers, true)
                render(sheet, to: "mobile-complications-\(scenario.rawValue)-\(tint == .color ? "color" : "tinted")-\(dark ? "dark" : "light").png")
                mobileCount += 1
            }
        }
        // The Lock Screen and the Live Activity in each presentation.
        render(LockScreenPreview(feed: feed, now: now).frame(width: 300, height: 640), to: "mobile-lockscreen-\(scenario.rawValue).png")
        if let focus, let state = SessionActivityState.from(focus, generatedAt: feed.generatedAt) {
            let activity = VStack(alignment: .leading, spacing: 20) {
                SessionActivityLockScreen(provider: focus.id, label: focus.shortLabel ?? focus.id.displayName, state: state, now: now)
                    .frame(width: 360).background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.5)))
                HStack(spacing: 40) {
                    SessionActivityCompactLeading(provider: focus.id, state: state)
                    SessionActivityCompactTrailing(state: state, now: now)
                }
                .padding(.horizontal, 18).frame(height: 36).background(Capsule().fill(.black))
                SessionActivityRing(state: state).frame(width: 22, height: 22).padding(7).background(Circle().fill(.black))
                SessionActivityExpandedBottom(state: state, now: now).frame(width: 340).padding(16).background(RoundedRectangle(cornerRadius: 30).fill(.black))
                SessionActivityWatch(provider: focus.id, state: state, now: now).padding(12).background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.12)))
            }
            .padding(28).background(Backdrop(dark: true)).environment(\.colorScheme, .dark).environment(\.staticTimers, true)
            render(activity, to: "mobile-liveactivity-\(scenario.rawValue).png")
            mobileCount += 2
        }
        // The iPhone and iPad widgets that the Mac doesn't have.
        for dark in [true, false] {
            let sheet = VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 28) {
                    ForEach([WidgetFamily.systemMedium, .systemLarge], id: \.self) { f in Tile(kind: .accounts, family: f, feed: feed, now: now) }
                    ForEach([WidgetFamily.systemMedium, .systemLarge], id: \.self) { f in Tile(kind: .activity, family: f, feed: feed, now: now) }
                }
                HStack(alignment: .top, spacing: 28) {
                    Tile(kind: .session, family: .systemLarge, feed: feed, now: now)
                    Tile(kind: .pace, family: .systemExtraLarge, feed: feed, now: now)
                }
                HStack(alignment: .top, spacing: 28) {
                    Tile(kind: .accounts, family: .systemExtraLarge, feed: feed, now: now)
                    Tile(kind: .activity, family: .systemExtraLarge, feed: feed, now: now)
                }
            }
            .padding(36).background(Backdrop(dark: dark)).environment(\.colorScheme, dark ? .dark : .light).environment(\.staticTimers, true)
            .environment(\.drawnOffscreen, true)
            render(sheet, to: "mobile-widgets-\(scenario.rawValue)-\(dark ? "dark" : "light").png")
            mobileCount += 1
        }
    }
    print("rendered \(mobileCount) image(s) to \(out.path)")
    exit(0)
}

var feeds: [(String, WidgetFeed?)] = WidgetSamples.Scenario.allCases.map { ($0.rawValue, WidgetSamples.feed($0, now: now)) }
feeds.append(("empty", nil))
if args.contains("--live"), let live = WidgetFeed.read() { feeds.insert(("live", live), at: 0) }
if let i = args.firstIndex(of: "--feed"), i + 1 < args.count, let feed = WidgetFeed.read(from: URL(fileURLWithPath: args[i + 1])) {
    // A fixture feed only: everything is drawn at the moment it was built.
    feeds = [("feed", feed)]
    now = feed.generatedAt
}

var count = 0
for (label, feed) in feeds {
    for dark in [true, false] {
        // One sheet per state and appearance: every widget and family together.
        let sheet = VStack(alignment: .leading, spacing: 28) {
            ForEach(HeadroomWidgetKind.allCases, id: \.self) { kind in
                HStack(alignment: .top, spacing: 28) {
                    ForEach(kind.families.indices, id: \.self) { i in
                        Tile(kind: kind, family: kind.families[i], feed: feed, now: now)
                    }
                }
            }
        }
        .padding(36)
        .background(Backdrop(dark: dark))
        .environment(\.colorScheme, dark ? .dark : .light)
        render(sheet, to: "widgets-\(label)-\(dark ? "dark" : "light").png")
        count += 1
    }
}
// Each widget on its own too, for close inspection.
for kind in HeadroomWidgetKind.allCases {
    for family in kind.families {
        for (label, feed) in feeds.prefix(2) {
            let v = Tile(kind: kind, family: family, feed: feed, now: now).padding(24).background(Backdrop(dark: true))
                .environment(\.colorScheme, .dark)
            render(v, to: "\(kind.rawValue)-\(name(family))-\(label).png")
            count += 1
        }
    }
}
print("rendered \(count) image(s) to \(out.path)")
