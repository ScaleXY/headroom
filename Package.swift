// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
        .executable(name: "headroom", targets: ["headroom"]),
        .executable(name: "HeadroomFanHelper", targets: ["HeadroomFanHelper"]),
        .executable(name: "HeadroomBench", targets: ["HeadroomBench"]),
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
        .executableTarget(name: "headroom", dependencies: ["HeadroomCLI"], swiftSettings: strict),
        // The SMC: fans and chip temperatures. IOKit only.
        .target(name: "HeadroomSMC", swiftSettings: strict),
        // Root LaunchDaemon that runs the fan curve; the app registers it with SMAppService.
        .executableTarget(name: "HeadroomFanHelper", dependencies: ["HeadroomSMC"], swiftSettings: strict),
        .executableTarget(name: "HeadroomApp", dependencies: ["HeadroomCore", "HeadroomKit", "HeadroomSMC", .product(name: "Sparkle", package: "Sparkle")],
                         swiftSettings: strict,
                         linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "HeadroomBench", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomKitTests", dependencies: ["HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore", "HeadroomKit"], swiftSettings: strict),
        .testTarget(name: "HeadroomSMCTests", dependencies: ["HeadroomSMC"], swiftSettings: strict),
        .testTarget(name: "HeadroomCLITests", dependencies: ["HeadroomCLI", "HeadroomKit"], swiftSettings: strict),
    ]
)
