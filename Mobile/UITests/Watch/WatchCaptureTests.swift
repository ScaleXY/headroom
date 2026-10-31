import XCTest

/// The Apple Watch screenshots: each account's page on the showcase sample data, most urgent
/// first, at its top (the 5-hour ring), its week, and its foot. The capture script picks the ten
/// it uploads. It passes `HR_SHOT_DIR` and `HR_TZ` through `TEST_RUNNER_` environment variables.
@MainActor
final class WatchCaptureTests: XCTestCase {
    var app = XCUIApplication()
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var shotDir: URL { URL(fileURLWithPath: env["HR_SHOT_DIR"] ?? NSTemporaryDirectory()) }

    override func setUp() async throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
    }

    func launch(scenario: String) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-HeadroomDemoScenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleICUForce24HourTime", "NO"]
        if let tz = env["HR_TZ"] { app.launchEnvironment["TZ"] = tz }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        Thread.sleep(forTimeInterval: 2.5)
    }

    func shot(_ name: String, settle: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: settle)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertNoThrow(try data.write(to: shotDir.appendingPathComponent("\(name).png")))
    }

    var height: CGFloat { app.frame.height }

    func text(_ label: String) -> XCUIElement { app.staticTexts[label].firstMatch }

    func onScreen(_ el: XCUIElement) -> Bool { el.exists && el.frame.minY >= 0 && el.frame.maxY <= height }

    /// Pages open lazily, at their top: swipe up a page at a time until this one shows.
    func page(showing label: String) -> Bool {
        for _ in 0..<12 {
            if onScreen(text(label)) { return true }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// Small crown steps within the page until `until` holds, giving up if `stay` (a label on
    /// this page) scrolls away, which would mean the crown carried on into the next page.
    func crownWithinPage(stay: XCUIElement, max steps: Int = 30, until: () -> Bool) -> Bool {
        for _ in 0..<steps {
            if until() { Thread.sleep(forTimeInterval: 0.6); return true }
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.05, velocity: .slow)
            Thread.sleep(forTimeInterval: 0.4)
            if !stay.exists { return false }
        }
        return until()
    }

    /// Each account's page, found by its 5-hour line, at the top, at its week, and at its foot.
    func testScreenshots() {
        let pages = [("codex", "90% left", "59%"), ("claude", "16% left", "82%"),
                     ("paused", "0% left", "14%"), ("team", "82% left", "59%")]
        for (name, session, week) in pages {
            launch(scenario: "showcase")
            XCTAssertTrue(page(showing: session), "\(name): page")
            shot("\(name)-top")
            let weekText = text(week)
            XCTAssertTrue(crownWithinPage(stay: weekText) { weekText.frame.minY <= height * 0.24 }, "\(name): week")
            shot("\(name)-week")
            let updated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Updated'")).firstMatch
            XCTAssertTrue(crownWithinPage(stay: weekText) { onScreen(updated) && updated.frame.maxY <= height * 0.97 }, "\(name): foot")
            shot("\(name)-foot")
        }
    }
}
