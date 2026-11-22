import Testing
@testable import HeadroomPresent

/// One resting height and scroll to grow (redesign §4).
@Suite struct WindowSizingTests {
    @Test func restingHeightIsTheLimitsTabCapped() {
        #expect(WindowSizing.resting(limitsNatural: 540, screenMax: 884) == 540)
        #expect(WindowSizing.resting(limitsNatural: 900, screenMax: 884) == 660)
        #expect(WindowSizing.resting(limitsNatural: 900, screenMax: 600) == 600)
    }

    /// Activity: 1400 pt of cards under 130 pt of chrome, on an 884 pt screen, resting at 660.
    func activity(height: Double? = nil, offset: Double = 0) -> WindowSizing {
        WindowSizing(resting: 660, screenMax: 884, chrome: 130, content: 1400, height: height, offset: offset)
    }

    @Test func opensAtRestWithMoreBelow() {
        let s = activity()
        #expect(s.height == 660 && s.offset == 0)
        #expect(s.limit == 884)
        #expect(s.hasMoreBelow)
    }

    @Test func scrollingDownGrowsFirstThenScrolls() {
        var s = activity()
        s.scroll(down: 100)
        #expect(s.height == 760 && s.offset == 0)
        s.scroll(down: 200) // 124 more to the screen edge, then 76 of scrolling
        #expect(s.height == 884 && s.offset == 76)
        s.scroll(down: 10_000)
        #expect(s.offset == s.maxOffset && s.offset == 1400 - (884 - 130))
        #expect(!s.hasMoreBelow)
    }

    @Test func scrollingUpReturnsToTheTopThenShrinksToRest() {
        var s = activity(height: 884, offset: 50)
        s.scroll(down: -80) // 50 to the top, then 30 of shrinking
        #expect(s.offset == 0 && s.height == 854)
        s.scroll(down: -10_000)
        #expect(s.height == 660)
    }

    @Test func momentumDoesNotShrink() {
        var s = activity(height: 800, offset: 20)
        s.scroll(down: -100, shrink: false)
        #expect(s.offset == 0 && s.height == 800)
    }

    @Test func growsOnlyToTheTabsOwnHeight() {
        var s = WindowSizing(resting: 600, screenMax: 884, chrome: 80, content: 650) // natural 730
        s.scroll(down: 500)
        #expect(s.height == 730 && s.offset == 0)
        #expect(!s.hasMoreBelow)
    }

    @Test func aShortTabKeepsTheRestingHeight() {
        var s = WindowSizing(resting: 600, screenMax: 884, chrome: 120, content: 200)
        #expect(s.height == 600 && s.limit == 600)
        s.scroll(down: 50)
        #expect(s.height == 600 && s.offset == 0)
    }

    @Test func resetReturnsToRestAndTop() {
        var s = activity(height: 884, offset: 300)
        s.reset()
        #expect(s.height == 660 && s.offset == 0)
    }

    @Test func clampFollowsShrinkingContent() {
        var s = activity(height: 884, offset: 600)
        s.content = 500 // natural 630: back to the resting height, nothing to scroll
        s.clamp()
        #expect(s.height == 660 && s.offset == 0)
    }
}
