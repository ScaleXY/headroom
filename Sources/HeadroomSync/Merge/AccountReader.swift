import Foundation
import HeadroomKit

/// Normalises what every Mac posted into one view per provider account.
///
/// Account facts (limits, resets, plan) are the same on every Mac that reads an account, so the
/// freshest reading wins. History is the union of what each Mac sampled. Activity comes from each
/// Mac's own logs, so it adds up. Writers never coordinate; all of this happens here.
public struct AccountReader: Sendable {
    public var now: Date
    /// A reading this old (and no Mac signed in) makes an account inactive.
    public static let inactiveAfter: TimeInterval = 7 * 86400
    /// Macs heard from within this window decide whether an account's fault shows.
    public static let recentWindow: TimeInterval = 30 * 60

    public init(now: Date) { self.now = now }

    public func read(_ records: SyncRecords) -> SyncSnapshot {
        let devices = Self.collapse(records.devices)
        let live = Self.collapse(records.live)
        let archives = Self.collapse(records.archives)
        let activity = Self.collapse(records.activity)
        let deviceByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceID, $0) })

        // Group every account-scoped record by provider account.
        var groups: [String: (provider: Provider, key: String, live: [Envelope<AccountLivePayload>],
                              archives: [Envelope<AccountArchivePayload>], activity: [Envelope<ActivityDayPayload>])] = [:]
        func id(_ p: Provider, _ k: String) -> String { p.rawValue + ":" + k }
        for e in live { guard let p = e.provider else { continue }; groups[id(p, e.accountKey), default: (p, e.accountKey, [], [], [])].live.append(e) }
        for e in archives { guard let p = e.provider else { continue }; groups[id(p, e.accountKey), default: (p, e.accountKey, [], [], [])].archives.append(e) }
        for e in activity { guard let p = e.provider else { continue }; groups[id(p, e.accountKey), default: (p, e.accountKey, [], [], [])].activity.append(e) }

        var accounts: [MergedAccount] = groups.map { gid, g in
            merge(id: gid, provider: g.provider, accountKey: g.key, live: g.live, archives: g.archives, activity: g.activity, devices: deviceByID)
        }
        Self.label(&accounts)
        accounts.sort { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.provider != b.provider { return a.provider < b.provider }
            return a.updatedAt > b.updatedAt
        }

        let infos = devices.map { d -> DeviceInfo in
            let mine = accounts.filter { $0.deviceIDs.contains(d.deviceID) }
            let current = Set(d.payload.currentAccounts.map { $0.key + ":" + $0.value })
            var faults: [String: Fault] = [:]
            for e in live where e.deviceID == d.deviceID {
                if let f = e.payload.fault, let p = e.provider { faults[id(p, e.accountKey)] = f }
            }
            return DeviceInfo(id: d.deviceID, name: d.payload.name, model: d.payload.model, appVersion: d.payload.appVersion,
                              lastSeenAt: d.lastSeenAt, state: d.payload.state, enabledProviders: d.payload.enabledProviders,
                              accounts: mine.map(\.id).sorted { current.contains($0) && !current.contains($1) }, faults: faults)
        }.sorted { $0.lastSeenAt > $1.lastSeenAt }

        return SyncSnapshot(accounts: accounts, devices: infos, unreadable: records.unreadable, tooNew: records.tooNew,
                            lastHeard: devices.map(\.lastSeenAt).max())
    }

    // MARK: One account

    func merge(id: String, provider: Provider, accountKey: String, live: [Envelope<AccountLivePayload>],
               archives: [Envelope<AccountArchivePayload>], activity: [Envelope<ActivityDayPayload>],
               devices: [String: DeviceEnvelope]) -> MergedAccount {
        let byFreshness = live.sorted { ($0.payload.reading?.fetchedAt ?? .distantPast, $0.updatedAt) > ($1.payload.reading?.fetchedAt ?? .distantPast, $1.updatedAt) }
        let chosen = byFreshness.first { $0.payload.reading != nil } ?? live.max { $0.updatedAt < $1.updatedAt }
        let device = chosen.flatMap { devices[$0.deviceID] }
        let name = { (deviceID: String) in devices[deviceID]?.payload.name ?? "Mac" }

        var history = Self.mergeHistory(live: live, chosen: chosen, archives: archives)
        var reading = chosen?.payload.reading
        var projected = false
        if let r = reading {
            let rolled = Self.rollOver(r, history: &history, now: now)
            reading = rolled.reading
            projected = rolled.projected
        }

        // A fault shows on the account only when every Mac heard from lately has one (or nothing read).
        let recent = live.filter { now.timeIntervalSince($0.updatedAt) <= Self.recentWindow }
        var fault: Fault?
        if reading == nil {
            fault = live.filter { $0.payload.fault != nil }.max { $0.updatedAt < $1.updatedAt }?.payload.fault
        } else if !recent.isEmpty, recent.allSatisfy({ $0.payload.fault != nil }) {
            fault = recent.max { $0.updatedAt < $1.updatedAt }?.payload.fault
        }
        var deviceFaults: [String: Fault] = [:]
        for e in live { if let f = e.payload.fault { deviceFaults[e.deviceID] = f } }

        let signedIn = devices.values.contains { $0.payload.currentAccounts[provider.rawValue] == accountKey }
        let readAt = reading?.fetchedAt ?? .distantPast
        let isActive = signedIn || now.timeIntervalSince(readAt) < Self.inactiveAfter

        let updatedAt = ([readAt] + live.map(\.updatedAt) + archives.map(\.updatedAt)).max() ?? .distantPast
        let deviceIDs = Array(Set(live.map(\.deviceID) + archives.map(\.deviceID) + activity.map(\.deviceID)))
            .sorted { (devices[$0]?.lastSeenAt ?? .distantPast) > (devices[$1]?.lastSeenAt ?? .distantPast) }

        return MergedAccount(
            id: id, provider: provider, accountKey: accountKey,
            email: live.filter { $0.payload.email != nil }.max { $0.updatedAt < $1.updatedAt }?.payload.email,
            label: "", shortLabel: "", deviceIDs: deviceIDs, sourceDevice: chosen.map { name($0.deviceID) },
            reading: reading, projected: projected, history: history, activity: Self.mergeActivity(activity),
            fault: fault, deviceFaults: deviceFaults, smoothedState: chosen?.payload.shownState,
            policy: device?.payload.policy ?? .standard, planMonthlyOverride: device?.payload.planPriceOverrides[provider.rawValue],
            outage: device?.payload.outages[provider.rawValue], isActive: isActive, updatedAt: updatedAt)
    }

    // MARK: History

    /// The chosen Mac's history, with every other Mac's samples for the same windows folded in.
    static func mergeHistory(live: [Envelope<AccountLivePayload>], chosen: Envelope<AccountLivePayload>?,
                             archives: [Envelope<AccountArchivePayload>]) -> AccountHistory {
        var h = AccountHistory()
        guard let base = chosen?.payload else {
            h.weeks = mergeWeeks(archives.map(\.payload.weeks))
            h.sessions = mergeSessions(archives.map(\.payload.sessions))
            return h
        }
        let others = live.filter { $0.deviceID != chosen?.deviceID }.map(\.payload)
        for w in base.windows {
            var merged = w.history
            for o in others {
                guard let ow = o.windows.first(where: { $0.id == w.id }), abs(ow.resetsAt.timeIntervalSince(w.resetsAt)) <= 3600 else { continue }
                merged.samples = mergeSamples(merged.samples, ow.series.samples)
            }
            h.windows[w.id] = merged
        }
        if let s = base.session {
            var merged = s.history
            for o in others {
                guard let os = o.session, abs(os.resetsAt.timeIntervalSince(s.resetsAt)) <= 600 else { continue }
                merged.samples = mergeSamples(merged.samples, os.series.samples)
            }
            h.session = merged
        }
        h.headlineID = base.headlineID
        h.earlyResetAt = base.earlyResetAt
        h.planThisWindow = base.planThisWindow
        // Each Mac only counts the limit hits it saw: the most any of them saw is a lower bound.
        let sameWeek = others.filter { o in
            guard let id = base.headlineID, let mine = base.windows.first(where: { $0.id == id }),
                  let theirs = o.windows.first(where: { $0.id == id }) else { return false }
            return abs(theirs.resetsAt.timeIntervalSince(mine.resetsAt)) <= 3600
        }
        h.sessionHitsThisWindow = ([base.sessionHitsThisWindow] + sameWeek.map(\.sessionHitsThisWindow)).max() ?? 0
        h.weeks = mergeWeeks(archives.map(\.payload.weeks))
        h.sessions = mergeSessions(archives.map(\.payload.sessions))
        return h
    }

    /// Union of two sample series, oldest first, dropping near-duplicates and thinning like `WindowHistory.append`.
    static func mergeSamples(_ a: [UsageSample], _ b: [UsageSample]) -> [UsageSample] {
        guard !b.isEmpty else { return a }
        guard !a.isEmpty else { return b }
        var out: [UsageSample] = []
        for s in (a + b).sorted(by: { $0.time < $1.time }) {
            if let last = out.last, s.time.timeIntervalSince(last.time) < 60, abs(s.used - last.used) < 0.0005 { continue }
            out.append(s)
        }
        while out.count > HistoryStore.maxSamples {
            let half = out.count / 2
            out = out[..<half].enumerated().filter { $0.offset % 2 == 0 }.map(\.element) + out[half...]
        }
        return out
    }

    /// Finished sessions from every Mac, matched by reset time.
    static func mergeSessions(_ lists: [[SessionRecord]]) -> [SessionRecord] {
        var out: [SessionRecord] = []
        for s in lists.joined().sorted(by: { $0.resetsAt < $1.resetsAt }) {
            if let i = out.lastIndex(where: { abs($0.resetsAt.timeIntervalSince(s.resetsAt)) <= 600 }) {
                var m = out[i]
                m.peakUsed = max(m.peakUsed, s.peakUsed)
                m.hitLimitAt = [m.hitLimitAt, s.hitLimitAt].compactMap { $0 }.min()
                m.samples = mergeSamples(m.samples, s.samples)
                out[i] = m
            } else {
                out.append(s)
            }
        }
        return Array(out.suffix(HistoryStore.maxSessions))
    }

    /// Finished weeks from every Mac, matched by scheduled end.
    static func mergeWeeks(_ lists: [[WeekRecord]]) -> [WeekRecord] {
        var out: [WeekRecord] = []
        for w in lists.joined().sorted(by: { $0.scheduledEnd < $1.scheduledEnd }) {
            if let i = out.lastIndex(where: { abs($0.scheduledEnd.timeIntervalSince(w.scheduledEnd)) <= 3600 }) {
                var m = out[i]
                m.finalUsed = max(m.finalUsed, w.finalUsed)
                m.ranOutAt = [m.ranOutAt, w.ranOutAt].compactMap { $0 }.min()
                m.earlyReset = m.earlyReset || w.earlyReset
                m.sessionHits = max(m.sessionHits, w.sessionHits)
                m.plan = m.plan ?? w.plan
                var samples = mergeSamples(m.samples, w.samples)
                if samples.count > HistoryStore.weekSampleLimit + 1 {
                    let stride = Double(samples.count) / Double(HistoryStore.weekSampleLimit)
                    samples = (0..<HistoryStore.weekSampleLimit).map { samples[min(samples.count - 1, Int(Double($0) * stride))] } + [samples[samples.count - 1]]
                }
                m.samples = samples
                out[i] = m
            } else {
                out.append(w)
            }
        }
        return Array(out.suffix(HistoryStore.maxWeeks))
    }

    // MARK: Activity

    /// Activity summed across Macs. Two Macs that read the same logs (a synced `~/.claude`) post
    /// identical days; once a busy day gives them away, their identical days count once.
    static func mergeActivity(_ days: [Envelope<ActivityDayPayload>]) -> [ActivitySlot] {
        var mirrored: Set<[String]> = []
        let byDay = Dictionary(grouping: days, by: \.payload.day)
        for group in byDay.values {
            for (i, a) in group.enumerated() {
                for b in group[(i + 1)...] where a.deviceID != b.deviceID && a.payload.slots == b.payload.slots
                    && a.payload.slots.filter({ $0.tokens.total > 0 }).count >= 8 {
                    mirrored.insert([a.deviceID, b.deviceID].sorted())
                }
            }
        }
        var kept: [Envelope<ActivityDayPayload>] = []
        for d in days.sorted(by: { $0.deviceID < $1.deviceID }) {
            let mirror = kept.contains { k in
                k.payload.day == d.payload.day && mirrored.contains([k.deviceID, d.deviceID].sorted()) && k.payload.slots == d.payload.slots
            }
            if !mirror { kept.append(d) }
        }
        var sums: [String: ActivitySlot] = [:]
        for s in kept.flatMap(\.payload.slots) {
            let key = String(s.slot) + "|" + s.model
            if var m = sums[key] {
                m.tokens += s.tokens
                m.micros += s.micros
                m.unpricedTokens += s.unpricedTokens
                m.classMicros = zip(m.classMicros + [0, 0, 0, 0], s.classMicros + [0, 0, 0, 0]).prefix(4).map { $0 + $1 }
                sums[key] = m
            } else {
                sums[key] = s
            }
        }
        return sums.values.sorted { ($0.slot, $0.model) < ($1.slot, $1.model) }
    }

    // MARK: Time

    /// Long windows whose reset has passed (with no reading since) start afresh, by the clock.
    /// The 5-hour session needs nothing: `SessionForecast` already treats a passed reset as idle.
    static func rollOver(_ reading: LimitReading, history: inout AccountHistory, now: Date) -> (reading: LimitReading, projected: Bool) {
        var r = reading
        var projected = false
        for i in r.windows.indices where r.windows[i].kind != .session {
            guard let resetsAt = r.windows[i].resetsAt, resetsAt.addingTimeInterval(120) < now else { continue }
            let length = r.windows[i].effectiveDuration
            var next = resetsAt
            while next <= now { next = next.addingTimeInterval(length) }
            r.windows[i].used = 0
            r.windows[i].resetsAt = next
            history.windows[r.windows[i].id] = WindowHistory(id: r.windows[i].id, resetsAt: next, duration: length)
            projected = true
        }
        return (r, projected)
    }

    // MARK: Labels

    /// Emails where known; otherwise provider and plan, numbered when two would read the same.
    static func label(_ accounts: inout [MergedAccount]) {
        let order = accounts.indices.sorted { accounts[$0].updatedAt < accounts[$1].updatedAt }
        var used: [String: Int] = [:]
        for i in order {
            let a = accounts[i]
            if let email = a.email {
                accounts[i].label = email
            } else {
                var base = a.provider.displayName
                if let pill = a.reading?.plan?.pill { base += " · " + pill }
                used[base, default: 0] += 1
                accounts[i].label = used[base]! > 1 ? base + " · \(used[base]!)" : base
            }
        }
        let perProvider = Dictionary(grouping: accounts.filter(\.isActive), by: \.provider).mapValues(\.count)
        for i in accounts.indices {
            let a = accounts[i]
            if (perProvider[a.provider] ?? 0) <= 1 {
                accounts[i].shortLabel = a.provider.displayName
            } else if let local = a.email?.split(separator: "@").first {
                accounts[i].shortLabel = a.provider.displayName + " · " + local
            } else {
                accounts[i].shortLabel = a.label
            }
        }
    }

    // MARK: Duplicates

    /// One record per natural key: the newest, in case a writer hasn't deduped yet.
    static func collapse<P>(_ items: [Envelope<P>]) -> [Envelope<P>] {
        var newest: [String: Envelope<P>] = [:]
        for e in items where (newest[e.key]?.updatedAt ?? .distantPast) <= e.updatedAt { newest[e.key] = e }
        return Array(newest.values)
    }

    static func collapse(_ items: [DeviceEnvelope]) -> [DeviceEnvelope] {
        var newest: [String: DeviceEnvelope] = [:]
        for e in items where (newest[e.deviceID]?.updatedAt ?? .distantPast) <= e.updatedAt { newest[e.deviceID] = e }
        return Array(newest.values)
    }
}
