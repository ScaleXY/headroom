import XCTest

/// The ten App Store screenshots, in upload order. The capture script pairs each name with its
/// headline for the captioned set.
final class ScreenshotTests: CaptureCase {
    static let work = "claude:claude-demo-work"

    func testScreenshots() {
        if isPad { pad() } else { phone() }
    }

    /// iPhone, and the iPhone Duo's outer display.
    private func phone() {
        launch()
        let height = app.frame.height
        shot("01-now")

        launch(open: "headroom://account/\(Self.codex)")
        shot("02-pace")

        launch(open: "headroom://account/\(Self.claude)")
        shot("03-session")
        scroll(toText: "Burn-o-meter", top: height * 0.29)
        shot("04-burn")

        launch(open: "headroom://account/\(Self.codex)")
        scroll(toText: "Past weeks", top: height * 0.16)
        shot("05-history")

        launch()
        go("Activity")
        shot("06-activity")
        app.buttons["7D"].tap()
        shot("07-activity-week")

        if isDuo {
            // The Duo's simulator has no Lock Screen to capture: show the on-pace work account.
            launch(open: "headroom://account/\(Self.work)", scenario: "twoClaudeAccounts")
            shot("08-on-pace")
        } else {
            warmUpLiveActivity()
            launch(open: "headroom://account/\(Self.claude)")
            startTracking()
            pause(1.5)
            lockAndWake()
            shot("08-lock-screen", settle: 0.3)
            unlock()
            stopTracking()
        }

        launch()
        go("Macs")
        shot("09-macs")

        launch(appearance: "light")
        shot("10-light")
    }

    /// iPad in landscape: the sidebar beside the cards.
    private func pad() {
        launch(scenario: "twoClaudeAccounts")
        shot("01-now")

        launch(open: "headroom://account/\(Self.codex)")
        shot("02-pace")

        launch(open: "headroom://account/\(Self.claude)")
        shot("03-session")
        scroll(toText: "Burn-o-meter", top: 150)
        shot("04-burn")

        launch(open: "headroom://account/\(Self.work)", scenario: "twoClaudeAccounts")
        shot("05-on-pace")

        launch()
        go("Activity")
        shot("06-activity")
        app.buttons["30D"].tap()
        shot("07-activity-month")

        launch(open: "headroom://account/\(Self.codex)", appearance: "light")
        shot("08-light-account")

        launch()
        go("Macs")
        shot("09-macs")

        launch(appearance: "light", scenario: "twoClaudeAccounts")
        shot("10-light")
    }
}
