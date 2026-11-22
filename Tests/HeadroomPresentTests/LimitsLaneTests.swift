import Foundation
import Testing
import HeadroomKit
@testable import HeadroomPresent

/// The Limits card's one chart: the lane under the week, its keys, caption and stat strip.
@MainActor @Suite struct LimitsLaneTests {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US")
        return c
    }
    let now = Demo.now
    var presenter: Presenter { Presenter(now: now, calendar: Self.calendar, locale: Locale(identifier: "en_US")) }
    func clock(_ d: Date) -> String { TimeFormat.clock(d, calendar: Self.calendar, locale: Locale(identifier: "en_US")) }

    // MARK: Session lane

    @Test func sessionsAreClippedToTheWindow() throws {
        var input = Demo.limitsSession(0.42, now: now)
        let windowStart = try #require(input.reading?.headline?.windowStart)
        let h = 3600.0
        input.pastSessions = [
            // Entirely before the window: left out.
            SessionRecord(start: windowStart.addingTimeInterval(-8 * h), resetsAt: windowStart.addingTimeInterval(-3 * h), peakUsed: 0.9, hitLimitAt: nil),
            // Straddles the window's start: clipped to it.
            SessionRecord(start: windowStart.addingTimeInterval(-2 * h), resetsAt: windowStart.addingTimeInterval(3 * h), peakUsed: 0.5, hitLimitAt: nil),
            // Inside, hit the limit.
            SessionRecord(start: windowStart.addingTimeInterval(20 * h), resetsAt: windowStart.addingTimeInterval(25 * h), peakUsed: 1,
                          hitLimitAt: windowStart.addingTimeInterval(23.5 * h)),
        ]
        let card = presenter.paceCard(input)
        let lane = try #require(card.lane)
        #expect(lane.kind == .sessions)
        #expect(lane.sessions.count == 2)
        #expect(lane.sessions[0].start == 0)
        #expect(abs(lane.sessions[0].end - 3) < 1e-9)
        #expect(lane.sessions[1].start == 20 && lane.sessions[1].end == 25)
        #expect(lane.sessions[1].hitLimit)
        #expect(lane.sessions[1].tooltip.contains("hit the limit, paused"))
        #expect(lane.sessions[0].tooltip.hasSuffix("· peaked at 50%"))
        #expect(lane.warnAt == 0.75)
    }

    @Test func runningSessionComesFromTheReadingOnce() throws {
        var input = Demo.limitsSession(0.42, now: now)
        let reset = try #require(input.reading?.session?.resetsAt)
        // A stored copy of the running session (its reset drifted a little) isn't drawn twice.
        input.pastSessions.append(SessionRecord(start: reset.addingTimeInterval(-5 * 3600 + 30), resetsAt: now.addingTimeInterval(-60), peakUsed: 0.4, hitLimitAt: nil))
        let lane = try #require(presenter.paceCard(input).lane)
        let current = try #require(lane.current)
        #expect(!lane.sessions.contains { $0.end > current.start + 0.2 })
        #expect(abs(current.used - 0.42) < 1e-9)
        #expect(current.level == .normal)
        #expect(current.projectedUsed != nil)
        #expect(current.tooltip.contains("42% used so far"))
    }

    @Test func blockedSessionHitsTheLimitWithoutARunOut() throws {
        let card = presenter.paceCard(Demo.limitsSession(1, now: now))
        let current = try #require(card.lane?.current)
        #expect(current.hitLimit)
        #expect(current.runsOutAt == nil && current.projectedUsed == nil)
        #expect(current.tooltip.contains("hit the limit, paused"))
        let lane = try #require(card.lane)
        #expect(lane.limitHits == lane.sessions.filter(\.hitLimit).count + 1)
    }

    @Test func runsOutMarksTheRunOutInsideTheSession() throws {
        let current = try #require(presenter.paceCard(Demo.limitsRunsOut(now: now)).lane?.current)
        let out = try #require(current.runsOutAt)
        #expect(out > current.start && out < current.end)
    }

    @Test func noSessionRunning() throws {
        let card = presenter.paceCard(Demo.limitsIdle(now: now))
        #expect(card.lane?.kind == .sessions)
        #expect(card.lane?.current == nil)
        #expect(card.chartCaption == nil)
        #expect(card.stats.map(\.value)[1...2] == ["Full", "5h"])
        #expect(card.stats.map(\.sub)[1...2] == ["nothing used", "available"])
    }

    // MARK: Daily lane

    @Test func dailyUseIsTheDropInWhatsLeft() throws {
        let cal = Self.calendar
        // A window starting Monday 6 PM: a 6-hour first day, then whole days.
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18))!
        let nowT = 6.0 + 24 + 12 // Wednesday noon
        let points = [
            GlideModel.Point(t: 0, used: 0),
            GlideModel.Point(t: 6, used: 0.02),     // Monday evening: 2%
            GlideModel.Point(t: 30, used: 0.32),    // Tuesday: 30% (heavy)
            GlideModel.Point(t: nowT, used: 0.36),  // Wednesday so far: 4%
        ]
        let g = GlideModel(hours: 168, windowStart: start, nowT: nowT, points: points, projectionEnd: (168, 0.2), runsOut: false, state: .onPace)
        let p = Presenter(now: start.addingTimeInterval(nowT * 3600), calendar: cal, locale: Locale(identifier: "en_US"))
        let lane = p.dailyLane(g)
        #expect(lane.kind == .daily)
        #expect(lane.days.count == 8) // 6 h, six whole days, 18 h
        #expect(lane.days.first?.start == 0 && lane.days.first?.end == 6)
        #expect(lane.days.last?.end == 168)
        let used = lane.days.map(\.used)
        #expect(abs((used[0] ?? 0) - 0.02) < 1e-9)
        #expect(abs((used[1] ?? 0) - 0.30) < 1e-9)
        #expect(abs((used[2] ?? 0) - 0.04) < 1e-9)
        #expect(used[3...].allSatisfy { $0 == nil })
        #expect(abs(lane.days[1].even - 24.0 / 168) < 1e-9)
        #expect(lane.days[1].isHeavy && !lane.days[0].isHeavy)
        #expect(lane.days[2].isToday && lane.days.filter(\.isToday).count == 1)
        #expect(lane.days[1].label == "30%")
        #expect(lane.days[1].tooltip == "Tuesday · 30% of the week (an even day is 14%)")
        #expect(lane.days[2].tooltip == "Wednesday so far · 4% of the week (an even day is 14%)")
        #expect(lane.days[4].tooltip == nil)
    }

    @Test func noFiveHourWindowGetsTheDailyLane() throws {
        let card = presenter.paceCard(Demo.limitsDaily(now: now))
        let lane = try #require(card.lane)
        #expect(lane.kind == .daily)
        #expect(card.keys.map(\.text) == ["This week", "used each day", "an even day"])
        #expect(card.stats.map(\.label) == ["WEEK", "TODAY", "PER DAY", "BUSIEST"])
        let busiest = try #require(lane.days.compactMap(\.used).max())
        #expect(card.stats[3].value == presenter.percent(busiest))
        #expect(card.stats[1].value == presenter.percent(lane.days.first(where: \.isToday)?.used ?? 0))
        #expect(card.chartCaption == nil)
        // Days add up to what's been used.
        let total = lane.days.compactMap(\.used).reduce(0, +)
        #expect(abs(total - 0.53) < 0.005)
    }

    // MARK: Keys, caption, stat strip

    @Test func keysFollowTheLane() {
        let card = presenter.paceCard(Demo.limitsSession(0.42, now: now))
        #expect(card.keys.map(\.text) == ["This week", "5-hour sessions", "warns at 75%", "limit hit"])
        #expect(card.keys.map(\.mark) == [.line, .bar, .dash, .cross])
        var input = Demo.limitsSession(0.42, now: now)
        input.pastSessions = []
        #expect(presenter.paceCard(input).keys.map(\.text) == ["This week", "5-hour sessions", "warns at 75%"])
    }

    @Test func captionOnlyWhenSomethingApplies() throws {
        #expect(presenter.paceCard(Demo.limitsSession(0.42, now: now)).chartCaption == nil)
        let runsOut = try #require(presenter.paceCard(Demo.limitsRunsOut(now: now)).chartCaption)
        #expect(runsOut.hasPrefix("This 5-hour session runs out around "))
        #expect(runsOut.hasSuffix(" before the reset."))
        let input = Demo.limitsSession(1, now: now)
        let reset = try #require(input.reading?.session?.resetsAt)
        let blocked = try #require(presenter.paceCard(input).chartCaption)
        #expect(blocked == "Paused until \(clock(reset)). 54% of the week is still left after it.")
    }

    @Test func statStripWithASessionLimit() throws {
        let input = Demo.limitsSession(0.84, now: now)
        let card = presenter.paceCard(input)
        let reset = try #require(input.reading?.session?.resetsAt)
        #expect(card.stats.map(\.label) == ["WEEK", "5-HOUR", "RESETS", "LIMITS HIT"])
        #expect(card.stats.map(\.value) == ["54%", "16%", "2h 12m", "\(card.lane?.limitHits ?? -1)"])
        #expect(card.stats.map(\.sub) == ["left", "left", clock(reset), "this week"])
        #expect(card.stats[1].tone == .amber)
        #expect(card.stats[3].tone == .rose)
        if case .state = card.stats[0].tone {} else { Issue.record("WEEK is in the state color") }
        let blocked = presenter.paceCard(Demo.limitsSession(1, now: now))
        #expect(blocked.stats[1] == StatCell(label: "5-HOUR", value: "Paused", sub: "limit reached", tone: .rose))
        // The stat strip carries the session: no separate row.
        #expect(!card.rows.contains { $0.label == "5-hour session" })
    }

    @Test func bannerStaysOnceTheSessionWarns() {
        #expect(presenter.paceCard(Demo.limitsSession(0.84, now: now)).session != nil)
        #expect(presenter.paceCard(Demo.limitsSession(0.42, now: now)).session == nil)
    }

    // MARK: Settings

    @Test func cardPartsKeepTheirSavedNames() {
        #expect(CardPart.allCases.map(\.rawValue) == ["weekMeter", "weekGraph", "sessionMeter", "sessionGraph"])
        // Settings saved before the lane still decode, including the retired session meter.
        #expect(["weekMeter", "weekGraph", "sessionMeter", "sessionGraph"].compactMap(CardPart.init(rawValue:)).count == 4)
        #expect(CardPart.toggles == [.weekMeter, .weekGraph, .sessionGraph])
    }

    @Test func sessionGraphTogglesTheLane() {
        var options = PresentationOptions()
        options.parts.remove(.sessionGraph)
        let p = Presenter(now: now, calendar: Self.calendar, locale: Locale(identifier: "en_US"), options: options)
        let card = p.paceCard(Demo.limitsSession(0.42, now: now))
        #expect(card.lane == nil)
        #expect(card.keys.map(\.text) == ["This week"])
        // The stat strip still counts the week's limit hits.
        #expect(card.stats.count == 4 && card.stats[3].value != "0")
    }
}
