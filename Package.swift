// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]
/// App extensions may only call extension-safe API.
let extensionSafe: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
        .executable(name: "headroom", targets: ["headroom"]),
        .executable(name: "HeadroomFanHelper", targets: ["HeadroomFanHelper"]),
        .executable(name: "HeadroomBench", targets: ["HeadroomBench"]),
        .executable(name: "HeadroomWidgets", targets: ["HeadroomWidgets"]),
        .executable(name: "HeadroomWidgetPreview", targets: ["HeadroomWidgetPreview"]),
        // Libraries the iPhone, iPad and Watch apps link (Mobile/project.yml).
        .library(name: "HeadroomKit", targets: ["HeadroomKit"]),
        .library(name: "HeadroomPresent", targets: ["HeadroomPresent"]),
        .library(name: "HeadroomSync", targets: ["HeadroomSync"]),
        .library(name: "HeadroomMobileUI", targets: ["HeadroomMobileUI"]),
        .library(name: "HeadroomWatchUI", targets: ["HeadroomWatchUI"]),
        .library(name: "HeadroomWidgetUI", targets: ["HeadroomWidgetUI", "HeadroomArt"]),
    ],
    dependencies: [
        // In-app updates for the menu bar app (never linked by the CLI).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure value types: models, pacing, pricing, snapshot schema, formatters.
        // Foundation only. The CLI links this and nothing that touches credentials or the network.
        .target(name: "HeadroomKit", resources: [.copy("Resources/pricing.json")], swiftSettings: strict),
        // Log ingestion, provider clients, credentials, store. Never linked by the CLI.
        .target(name: "HeadroomCore", dependencies: ["HeadroomKit"], swiftSettings: strict),
        .target(name: "HeadroomCLI", dependencies: ["HeadroomKit"], swiftSettings: strict),
        // Card and widget copy shared by the Mac, iOS and watchOS: the Presenter and its models. Foundation only.
        .target(name: "HeadroomPresent", dependencies: ["HeadroomKit"], swiftSettings: strict + extensionSafe),
        // iCloud sync: the SwiftData schema, payloads, and the reader that merges every Mac into one view per account.
        .target(name: "HeadroomSync", dependencies: ["HeadroomKit", "HeadroomPresent"], swiftSettings: strict + extensionSafe),
        // Vector art shared by the app and the widgets: the SVG path parser and the real brand marks.
        .target(name: "HeadroomArt", swiftSettings: strict),
        // The desktop widgets' SwiftUI views, drawn from `widgets.json`.
        .target(name: "HeadroomWidgetUI", dependencies: ["HeadroomKit", "HeadroomArt"], swiftSettings: strict + extensionSafe),
        // The iPhone and iPad app's screens and services (iOS; also builds on macOS for the PNG renderer).
        .target(name: "HeadroomMobileUI", dependencies: ["HeadroomWidgetUI", "HeadroomPresent", "HeadroomSync", "HeadroomKit"], swiftSettings: strict),
        // The Apple Watch app's screens and the phone relay's receiver.
        .target(name: "HeadroomWatchUI", dependencies: ["HeadroomWidgetUI", "HeadroomSync", "HeadroomKit"], swiftSettings: strict),
        // The WidgetKit extension (`Headroom.app/Contents/PlugIns/HeadroomWidgets.appex`). It enters
        // through `NSExtensionMain`, as Xcode links extensions: that sets up the launch the system
        // hands over, then runs the `@main` bundle. Entering at `main` directly traps on launch.
        .executableTarget(name: "HeadroomWidgets", dependencies: ["HeadroomWidgetUI", "HeadroomKit"],
                         swiftSettings: strict + extensionSafe,
                         linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        // Renders every widget in every state to PNGs for review (`HeadroomWidgetPreview <dir>`).
        .executableTarget(name: "HeadroomWidgetPreview", dependencies: ["HeadroomWidgetUI", "HeadroomKit", "HeadroomSync"], swiftSettings: strict),
        .executableTarget(name: "headroom", dependencies: ["HeadroomCLI"], swiftSettings: strict),
        // The SMC: fans and chip temperatures. IOKit only.
        .target(name: "HeadroomSMC", swiftSettings: strict),
        // Root LaunchDaemon that runs the fan curve; the app registers it with SMAppService.
        .executableTarget(name: "HeadroomFanHelper", dependencies: ["HeadroomSMC"], swiftSettings: strict),
        .executableTarget(name: "HeadroomApp", dependencies: ["HeadroomCore", "HeadroomKit", "HeadroomPresent", "HeadroomSync", "HeadroomWidgetUI", "HeadroomSMC", "HeadroomArt", .product(name: "Sparkle", package: "Sparkle")],
                         swiftSettings: strict,
                         linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "HeadroomBench", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomKitTests", dependencies: ["HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomSMCTests", dependencies: ["HeadroomSMC"], swiftSettings: strict),
        .testTarget(name: "HeadroomCLITests", dependencies: ["HeadroomCLI", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomAppTests", dependencies: ["HeadroomApp", "HeadroomKit", "HeadroomSync"], swiftSettings: strict),
        .testTarget(name: "HeadroomSyncTests", dependencies: ["HeadroomSync", "HeadroomPresent", "HeadroomKit"],
                    resources: [.copy("Fixtures")], swiftSettings: strict),
    ]
)
