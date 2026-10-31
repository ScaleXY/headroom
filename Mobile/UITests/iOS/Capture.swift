import XCTest

/// Shared plumbing for the App Store captures. Headroom runs on its sample data with the
/// sample-data note hidden, in a clock zone where it's 9:41, like the status bar the capture
/// script pins.
///
/// The capture script passes, through `TEST_RUNNER_` environment variables:
/// - `HR_SHOT_DIR`: where screenshots go (the simulator writes straight to the Mac's disk);
/// - `HR_MARKS`: a file that collects when each preview flow starts and ends, to trim recordings;
/// - `HR_TZ`: the clock zone, the same one the script set for the whole simulator.
@MainActor
class CaptureCase: XCTestCase {
    var app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    static let codex = "codex:codex-demo"
    static let claude = "claude:claude-demo-personal"

    var env: [String: String] { ProcessInfo.processInfo.environment }
    var shotDir: URL { URL(fileURLWithPath: env["HR_SHOT_DIR"] ?? NSTemporaryDirectory()) }
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// The iPhone Duo's outer display: a phone layout on a wide screen, with no Lock Screen to capture.
    var isDuo: Bool { !isPad && springboard.frame.width / max(springboard.frame.height, 1) > 0.6 }

    override func setUp() async throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    /// Launches Headroom fresh on `open` (a `headroom://` link; Now by default, so no restored
    /// tab or sidebar selection carries over). `appearance` is system, light or dark.
    func launch(open url: String = "headroom://now", appearance: String = "dark", scenario: String = "twoMacs") {
        for _ in 0..<3 {
            app.terminate()
            app = XCUIApplication()
            app.launchArguments = ["-HeadroomScreenshots", "YES", "-HeadroomDemoScenario", scenario, "-HeadroomOpen", url,
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleICUForce24HourTime", "NO",
                                   "-appearance", appearance]
            if let tz = env["HR_TZ"] { app.launchEnvironment["TZ"] = tz }
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            pause(2)
            // The sample-data note means this launch didn't get its arguments; go again.
            if !app.buttons["Use iCloud"].exists { return }
        }
        XCTFail("The sample-data note is still showing")
    }

    // MARK: Output

    /// Saves the whole screen, status bar included, at the device's pixel size. (Landscape iPad
    /// shots arrive in the portrait framebuffer; the script turns them upright.)
    func shot(_ name: String, settle: TimeInterval = 1.2) {
        pause(settle)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertNoThrow(try data.write(to: shotDir.appendingPathComponent("\(name).png")))
    }

    func dump(_ name: String, of target: XCUIApplication? = nil) {
        let url = shotDir.appendingPathComponent("\(name).txt")
        try? (target ?? app).debugDescription.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Records when a preview flow starts or ends (seconds since 1970), for trimming the recording.
    func mark(_ label: String) {
        guard let path = env["HR_MARKS"] else { return }
        let line = String(format: "%@ %.3f\n", label, Date().timeIntervalSince1970)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: Navigation

    func card(_ provider: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", provider + ",")).firstMatch
    }

    /// A section: a tab (or the Duo's tab rail) on a phone, a sidebar row on an iPad.
    func go(_ section: String) {
        let tab = app.tabBars.buttons[section]
        if tab.exists { tab.tap(); return }
        let row = app.cells.staticTexts[section]
        if row.exists { row.tap(); return }
        app.buttons[section].firstMatch.tap()
    }

    /// The point drags start from: the middle of the content (the detail column on an iPad).
    func contentPoint(y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: isPad ? 0.62 : 0.5, dy: y))
    }

    /// Scrolls by `points` (positive moves the content up) at `speed` points a second, holding at
    /// the end. Above about 300 points a second the scroll view coasts on after the finger lifts.
    func glide(_ points: CGFloat, speed: CGFloat = 260, hold: TimeInterval = 0.4) {
        let height = app.frame.height
        let travel = min(abs(points), height * 0.62) / height
        let from: CGFloat = points > 0 ? 0.8 : 0.8 - travel
        let to: CGFloat = points > 0 ? 0.8 - travel : 0.8
        contentPoint(y: from).press(forDuration: 0.05, thenDragTo: contentPoint(y: to),
                                    withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: hold)
    }

    /// Scrolls until the text `label` sits `top` points below the top of the screen. (A drag
    /// loses about 10 points to touch slop before the content moves.)
    func scroll(toText label: String, top: CGFloat) {
        let text = app.staticTexts[label].firstMatch
        for _ in 0..<6 {
            guard text.exists else { glide(400, speed: 300); continue }
            let delta = text.frame.minY - top
            if abs(delta) < 6 { return }
            glide(delta + (delta > 0 ? 10 : -10), speed: 300)
        }
    }

    /// Lock, then wake to the Lock Screen, accepting the Live Activities prompts (the first one,
    /// and the later "continue to allow"). The Lock Screen dims its countdowns soon after waking;
    /// a tap on the wallpaper brings it back to full brightness.
    func lockAndWake() {
        func cycle() {
            XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
            pause(0.8)
            XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
            pause(0.8)
        }
        cycle()
        for label in ["Always Allow", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 1) {
                button.tap()
                pause(0.6)
                cycle()
            }
        }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        pause(0.5)
    }

    /// Starts and stops a Live Activity once, accepting its prompts, so the recorded one appears
    /// on the Lock Screen at once.
    func warmUpLiveActivity() {
        launch(open: "headroom://account/\(Self.claude)")
        startTracking()
        pause(1.5)
        lockAndWake()
        pause(1.5)
        unlock()
        stopTracking()
        pause(1)
    }

    func unlock() {
        XCUIDevice.shared.press(.home)
        pause(1)
        app.activate()
        pause(1)
    }

    /// Starts the session Live Activity from the account page (stopping a leftover one first).
    func startTracking() {
        let stop = app.buttons["Stop Tracking This Session"]
        if stop.exists { stop.tap(); pause(1) }
        let track = app.buttons["Track This Session on the Lock Screen"]
        if !track.isHittable { scroll(toText: "Burn-o-meter", top: app.frame.height * 0.5) }
        track.tap()
    }

    func stopTracking() {
        let stop = app.buttons["Stop Tracking This Session"]
        if stop.waitForExistence(timeout: 3) {
            if !stop.isHittable { scroll(toText: "Burn-o-meter", top: app.frame.height * 0.5) }
            stop.tap()
        }
    }
}
