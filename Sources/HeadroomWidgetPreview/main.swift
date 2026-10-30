import AppKit
import HeadroomKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

// Renders every widget, family, sample state and appearance to PNGs on a desktop-like backdrop:
//   HeadroomWidgetPreview <out-dir> [--live]
// `--live` adds the current `widgets.json` (what the installed widgets show right now);
// `--feed <file>` adds a feed written by `HeadroomApp --render widget-feed`, drawn at its own time.

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
    default: CGSize(width: 344, height: 344)
    }
}

func name(_ family: WidgetFamily) -> String {
    switch family {
    case .systemSmall: "small"
    case .systemMedium: "medium"
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
