import AppIntents

/// Siri and Shortcuts phrases.
struct HeadroomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckHeadroomIntent(), phrases: ["Check \(.applicationName)", "How much is left in \(.applicationName)"],
                    shortTitle: "Check Headroom", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: TrackSessionIntent(), phrases: ["Track my session in \(.applicationName)"],
                    shortTitle: "Track 5-Hour Session", systemImageName: "livephoto")
    }
}
