import AppKit
import Foundation
import Testing
@testable import HeadroomApp

@MainActor @Suite struct CanvasFadeTests {
    /// The welcome window can close mid-fade (Return held down through its steps): the 60 Hz fade
    /// timer has to stop with the view, not tick for as long as the app runs.
    @Test func aFadeStopsWhenItsViewGoesAway() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        weak var gone: CanvasControlView?
        var timer: Timer?
        autoreleasepool {
            let view = CanvasControlView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
            window.contentView?.addSubview(view)
            view.crossfade()
            timer = view.fadeTimer
            gone = view
            view.removeFromSuperview()
        }
        #expect(timer?.isValid == true && gone == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(timer?.isValid == false)
    }
}
