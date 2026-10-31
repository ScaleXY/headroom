import XCTest

/// The three app preview flows. The capture script records the screen while each runs and keeps
/// what falls between the `start` and `end` marks. Every move is slow and held, so the video
/// reads without sound and without quick cuts.
final class PreviewTests: CaptureCase {
    /// 1. The week: the cards, then one account in full.
    func testPreviewPace() {
        launch(scenario: isPad ? "twoClaudeAccounts" : "twoMacs")
        mark("start")
        pause(2.5)
        glide(isPad ? 300 : 360, speed: 180)
        pause(1.6)
        glide(isPad ? -300 : -360, speed: 240)
        pause(1)
        if isPad { app.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS 'tight'")).firstMatch.tap() } else { card("Codex").tap() }
        pause(2.4)
        glide(isPad ? 260 : 330, speed: 170)
        pause(1.8)
        glide(isPad ? 360 : 420, speed: 190)
        pause(1.8)
        glide(isPad ? 420 : 460, speed: 200)
        pause(2.4)
        mark("end")
    }

    /// 2. The 5-hour session: the warning, then the Live Activity on the Lock Screen (iPhone).
    func testPreviewSession() {
        if !isPad && !isDuo { warmUpLiveActivity() }
        launch()
        mark("start")
        pause(2)
        if isPad {
            app.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS 'plenty'")).firstMatch.tap()
        } else {
            glide(isDuo ? 330 : 470, speed: 200)
            pause(1.5)
            card("Claude").tap()
        }
        pause(3)
        glide(isPad ? 300 : 380, speed: 170)
        pause(1.6)
        let track = app.buttons["Track This Session on the Lock Screen"]
        if !isPad, !isDuo, track.exists, track.isHittable {
            track.tap()
            pause(1.8)
            lockAndWake()
            pause(3.2)
            mark("end")
            unlock()
            stopTracking()
        } else {
            glide(isPad ? 380 : 420, speed: 190)
            pause(2.2)
            glide(isPad ? 380 : 420, speed: 190)
            pause(2.4)
            mark("end")
        }
    }

    /// 3. Activity: tokens and cost by range, past weeks, then the Macs.
    func testPreviewActivity() {
        launch()
        mark("start")
        pause(1.5)
        go("Activity")
        pause(2.6)
        app.buttons["7D"].tap()
        pause(2.4)
        app.buttons["30D"].tap()
        pause(2.4)
        glide(isPad ? 380 : 440, speed: 190)
        pause(2.2)
        go("Macs")
        pause(2.6)
        go("Now")
        pause(1.8)
        mark("end")
    }
}
