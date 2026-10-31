import Foundation
import HeadroomKit
import HeadroomPresent

/// Synced records built from the Mac's own mockup scenarios: demo mode, App Review, previews and
/// the parity tests. Times are relative to `now`, so countdowns tick as they would live.
@MainActor
public enum DemoRecords {
    public enum Scenario: String, CaseIterable, Sendable {
        /// Claude on two Macs, Codex on one.
        case twoMacs
        /// Two Claude accounts (personal and work) and Codex.
        case twoClaudeAccounts
        /// Two Claude accounts and Codex, plus a Codex work account paused at its 5-hour limit:
        /// every state at once, for the App Store's Apple Watch screenshots.
        case showcase
    }

    public static let laptopID = "demo-macbook-pro"
    public static let desktopID = "demo-mac-studio"

    /// The scenario the App Store screenshots ask for with `-HeadroomDemoScenario <name>`; two Macs otherwise.
    public static var launchScenario: Scenario {
        UserDefaults.standard.string(forKey: "HeadroomDemoScenario").flatMap(Scenario.init(rawValue:)) ?? .twoMacs
    }

    public static func make(_ scenario: Scenario = .twoMacs, now: Date = Date()) -> SyncRecords {
        var out = SyncRecords()
        let claude = Demo.claudeMockup(now: now)
        let codex = Demo.codexMockup(now: now)
        let pricing = PricingEngine.standard()
        let aggregates = Demo.activityAggregates(now: now, pricing: pricing)

        let personal = "claude-demo-personal", work = "claude-demo-work", codexKey = "codex-demo", codexWork = "codex-demo-work"
        var desktop = [Provider.claude.rawValue: scenario == .twoMacs ? personal : work]
        if scenario == .showcase { desktop[Provider.codex.rawValue] = codexWork }
        out.devices = [
            device(laptopID, name: "MacBook Pro", model: "Mac15,7", now: now,
                   current: [Provider.claude.rawValue: personal, Provider.codex.rawValue: codexKey]),
            device(desktopID, name: "Mac Studio", model: "Mac14,13", now: now.addingTimeInterval(-6 * 60), current: desktop),
        ]

        add(&out, claude, key: personal, email: "you@example.com", device: laptopID, now: now)
        add(&out, codex, key: codexKey, email: "you@example.com", device: laptopID, now: now)
        switch scenario {
        case .twoMacs:
            // The desktop saw the same account a few minutes earlier, with its own, sparser samples.
            var older = claude
            if var r = older.reading { r.fetchedAt = now.addingTimeInterval(-6 * 60); older.reading = r }
            older.samples = older.samples.mapValues { s in s.enumerated().filter { $0.offset % 3 == 0 }.map(\.element) }
            add(&out, older, key: personal, email: "you@example.com", device: desktopID, now: now.addingTimeInterval(-6 * 60), activity: false)
            out.activity += activity(aggregates.filter { $0.provider == .claude }, key: personal, device: desktopID, now: now, scale: 0.35)
        case .twoClaudeAccounts, .showcase:
            if scenario == .showcase {
                let paused = Demo.state(.codex, used: 0.86, elapsedH: 118, session: 1.0, now: now)
                add(&out, paused, key: codexWork, email: "you@work.example", device: desktopID, now: now.addingTimeInterval(-6 * 60), activity: false)
            }
            var team = Demo.state(.claude, used: 0.41, elapsedH: 70, session: 0.18, now: now)
            if var r = team.reading { r.plan = PlanInfo(raw: "team", pill: "TEAM", monthlyPriceUSD: 30); team.reading = r }
            add(&out, team, key: work, email: "you@work.example", device: desktopID, now: now.addingTimeInterval(-6 * 60), activity: false)
            out.activity += activity(aggregates.filter { $0.provider == .claude }, key: work, device: desktopID, now: now, scale: 0.5)
        }
        out.activity += activity(aggregates.filter { $0.provider == .claude }, key: personal, device: laptopID, now: now, scale: 1)
        out.activity += activity(aggregates.filter { $0.provider == .codex }, key: codexKey, device: laptopID, now: now, scale: 1)
        return out
    }

    /// The history a Mac would hold for this input: its windows, session and past sessions.
    public static func history(for input: PaceInput, weeks: [WeekRecord] = []) -> AccountHistory {
        var h = AccountHistory()
        guard let reading = input.reading else { return h }
        for w in reading.windows where w.kind != .session {
            guard let resetsAt = w.resetsAt else { continue }
            var wh = WindowHistory(id: w.id, resetsAt: resetsAt, duration: w.effectiveDuration)
            wh.samples = input.samples[w.id] ?? []
            h.windows[w.id] = wh
        }
        if let s = reading.session, let resetsAt = s.resetsAt, resetsAt > reading.fetchedAt {
            var wh = WindowHistory(id: LimitWindow.sessionID(), resetsAt: resetsAt, duration: s.effectiveDuration)
            wh.samples = input.samples[LimitWindow.sessionID()] ?? []
            h.session = wh
        }
        h.sessions = input.pastSessions
        h.headlineID = reading.headline?.id
        h.earlyResetAt = input.earlyResetAt
        h.weeks = weeks
        return h
    }

    /// Six plausible finished weeks before the current one.
    static func weeks(before start: Date, plan: String?) -> [WeekRecord] {
        let finals: [Double] = [0.82, 1.0, 0.64, 0.91, 0.55, 1.0]
        return finals.enumerated().map { i, used in
            let end = start.addingTimeInterval(-Double(finals.count - 1 - i) * 7 * 86400)
            let begin = end.addingTimeInterval(-7 * 86400)
            let samples = (0...14).map { k in UsageSample(time: begin.addingTimeInterval(Double(k) * 12 * 3600), used: min(used, used * Double(k) / 14)) }
            let ranOut = used >= 1 ? end.addingTimeInterval(-Double(10 + i) * 3600) : nil
            return WeekRecord(start: begin, end: end, scheduledEnd: end, finalUsed: used, ranOutAt: ranOut, sessionHits: i % 3,
                              earlyReset: false, plan: plan, samples: samples)
        }
    }

    static func device(_ id: String, name: String, model: String, now: Date, current: [String: String]) -> DeviceEnvelope {
        DeviceEnvelope(deviceID: id, updatedAt: now, lastSeenAt: now,
                       payload: DevicePayload(name: name, model: model, appVersion: "0.4.0", enabledProviders: [.claude, .codex],
                                              currentAccounts: current, sessionWarnAt: 0.75, planPriceOverrides: [:], outages: [:],
                                              state: .awake, syncSince: now.addingTimeInterval(-30 * 86400)))
    }

    static func add(_ out: inout SyncRecords, _ input: PaceInput, key: String, email: String, device: String, now: Date, activity: Bool = true) {
        guard var reading = input.reading else { return }
        reading.accountKey = key
        let weeks = reading.headline?.windowStart.map { Self.weeks(before: $0, plan: reading.plan?.pill) } ?? []
        let history = history(for: input, weeks: weeks)
        out.live.append(Envelope(deviceID: device, provider: input.provider, accountKey: key, updatedAt: now,
                                 payload: PayloadBuilder.live(reading: reading, history: history, fault: input.fault, faultAt: now,
                                                              isCurrent: true, email: email)))
        out.archives.append(Envelope(deviceID: device, provider: input.provider, accountKey: key, updatedAt: now,
                                     payload: PayloadBuilder.archive(history)))
    }

    static func activity(_ aggregates: [HourAggregate], key: String, device: String, now: Date, scale: Double) -> [Envelope<ActivityDayPayload>] {
        let slots = aggregates.map { a -> (provider: Provider, accountKey: String, slot: ActivitySlot) in
            func s(_ v: Int64) -> Int64 { Int64((Double(v) * scale).rounded()) }
            let t = a.tokens
            let slot = ActivitySlot(slot: ActivitySlot.slot(for: a.hour), model: a.model,
                                    tokens: TokenCounts(newInput: s(t.newInput), cacheWrite5m: s(t.cacheWrite5m), cacheWrite1h: s(t.cacheWrite1h),
                                                        cacheRead: s(t.cacheRead), output: s(t.output)),
                                    micros: s(a.micros), unpricedTokens: a.priced ? 0 : s(t.total),
                                    classMicros: [s(a.classMicros.input), s(a.classMicros.cacheWrite), s(a.classMicros.cacheRead), s(a.classMicros.output)])
            return (a.provider, key, slot)
        }
        return PayloadBuilder.activityDays(slots).map { k, payload in
            Envelope(deviceID: device, provider: k.provider, accountKey: k.accountKey, day: k.day, updatedAt: now, payload: payload)
        }
    }
}
