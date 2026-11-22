import Foundation
import HeadroomKit
import HeadroomPresent

/// Every Mac's runs in one list for the Runs section, each labelled with its Mac's name.
public enum RunMerge {
    /// A Mac not heard from for this long (or asleep, or quit) can't vouch for its live runs.
    public static let quietAfter: TimeInterval = AccountReader.recentWindow

    /// Live runs on Macs still heard from, most pressing first; then live runs on Macs gone
    /// quiet ("Mac last seen 2h ago"); then finished runs, newest first. Anything not updated in
    /// the last day drops out, as it does on the Mac. Finished runs are priced from `activity`,
    /// what each Mac's own models have cost per token lately.
    public static func digests(_ devices: [DeviceEnvelope], now: Date, activity: [Envelope<ActivityDayPayload>] = []) -> [RunDigest] {
        var out: [RunDigest] = []
        for d in devices {
            guard let runs = d.payload.runs else { continue }
            let quiet = d.payload.state != .awake || now.timeIntervalSince(d.lastSeenAt) > quietAfter
            var rates: [String: Double]?
            for r in runs where now.timeIntervalSince(r.updatedAt) < RunSummaryBuilder.finishedWindow {
                var digest = r.digest(deviceID: d.deviceID, mac: d.payload.name, lastSeen: quiet ? d.lastSeenAt : nil, activeAt: d.payload.activeAt)
                if let receipt = digest.receipt, !receipt.tokensByModel.isEmpty {
                    if rates == nil { rates = RunCost.rates(activity, deviceID: d.deviceID, now: now) }
                    digest.cost = RunCost.dollars(receipt.tokensByModel, rates: rates ?? [:])
                }
                out.append(digest)
            }
        }
        func group(_ d: RunDigest) -> Int { d.state.isTerminal ? 2 : d.lastSeen == nil ? 0 : 1 }
        return out.sorted { a, b in
            if group(a) != group(b) { return group(a) < group(b) }
            if group(a) == 2 { return (a.updatedAt, b.id) > (b.updatedAt, a.id) }
            return (a.attention, b.updatedAt, a.id) < (b.attention, a.updatedAt, b.id)
        }
    }
}

/// What a run's tokens cost. A run syncs tokens by model, not by kind (input, cache, output), so
/// each model is priced at what it actually cost per token on that Mac over the last week; a model
/// with no recent activity falls back to its list rates at a typical agent mix.
public enum RunCost {
    /// Micro-dollars per token by model, from one Mac's activity over the last `days`.
    public static func rates(_ activity: [Envelope<ActivityDayPayload>], deviceID: String, now: Date, days: Int = 7) -> [String: Double] {
        let since = Int((now.timeIntervalSince1970 / 86400).rounded(.down)) - days
        var micros: [String: Int64] = [:], tokens: [String: Int64] = [:]
        for e in activity where e.deviceID == deviceID && e.payload.day >= since {
            for s in e.payload.slots {
                let priced = s.tokens.total - s.unpricedTokens
                guard priced > 0, s.micros > 0 else { continue }
                // Two spellings of one model are one model: summed, not whichever came last.
                let model = ModelID.normalize(s.model)
                micros[model, default: 0] += s.micros
                tokens[model, default: 0] += priced
            }
        }
        return micros.reduce(into: [:]) { out, m in
            if let t = tokens[m.key], t > 0 { out[m.key] = Double(m.value) / Double(t) }
        }
    }

    /// Dollars for `tokens`; nil when no model could be priced.
    public static func dollars(_ tokens: [String: Int64], rates: [String: Double], engine: PricingEngine = engine) -> Double? {
        var micros = 0.0
        var priced = false
        for (model, count) in tokens where count > 0 {
            if let rate = rates[ModelID.normalize(model)] {
                micros += rate * Double(count); priced = true
            } else if engine.isPriced(model: model) {
                micros += Double(engine.price(tokens: mix(count), model: model).micros); priced = true
            }
        }
        return priced ? micros / 1_000_000 : nil
    }

    /// Bundled rates, loaded once.
    public static let engine = PricingEngine(table: .load(overrideURL: nil))

    /// How an agent's tokens usually split: mostly cache reads.
    static func mix(_ n: Int64) -> TokenCounts {
        let d = Double(n)
        return TokenCounts(newInput: Int64(d * 0.02), cacheWrite5m: Int64(d * 0.06), cacheRead: Int64(d * 0.89), output: Int64(d * 0.03))
    }
}

/// What a phone has already said about runs, so each needs-input episode, each stop and each
/// finish gets at most one notification however often syncs arrive. Kept between launches.
public struct RunAlertLedger: Codable, Sendable, Hashable {
    public enum Kind: String, Sendable { case needsInput, finished, stopped }

    /// One notification to post, now or (`deliverAt`) once its Mac's user has been away a while.
    public struct Alert: Sendable, Hashable {
        public var kind: Kind
        public var run: RunDigest
        public var deliverAt: Date?
    }

    /// The alerts due now or later, and the runs whose held alert should be withdrawn: answered
    /// before it went out.
    public struct Decision: Sendable, Hashable {
        public var due: [Alert] = []
        public var withdraw: [String] = []
    }

    /// Off until the first look: runs already waiting or finished then were there before this
    /// device was paying attention, and never alert.
    public var primed = false
    /// Runs in a needs-input episode that's been handled. Leaving the state ends the episode.
    public var waiting: Set<String> = []
    /// Finished runs already handled, and when they last alerted (forgotten after two days).
    public var finished: [String: Date] = [:]
    /// Runs in a stopped-with-work-left episode that's been handled.
    public var stopped: Set<String> = []
    /// Finished runs that came back to life: their next finish may alert again.
    public var reopened: Set<String> = []
    /// Needs-input alerts held while you were at the Mac, and when they go out.
    public var held: [String: Date] = [:]

    /// A finish older than this when it first arrives is old news.
    public static let finishFreshness: TimeInterval = 3600
    /// A run finishes again (a new batch of agents) at most this often, as far as alerts go.
    public static let finishSpacing: TimeInterval = 1800
    /// While the Mac's user touched it this recently, the phone stays quiet: they'll see it there.
    public static let activeHold: TimeInterval = 120

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primed = try c.decodeIfPresent(Bool.self, forKey: .primed) ?? false
        waiting = try c.decodeIfPresent(Set<String>.self, forKey: .waiting) ?? []
        finished = try c.decodeIfPresent([String: Date].self, forKey: .finished) ?? [:]
        stopped = try c.decodeIfPresent(Set<String>.self, forKey: .stopped) ?? []
        reopened = try c.decodeIfPresent(Set<String>.self, forKey: .reopened) ?? []
        held = try c.decodeIfPresent([String: Date].self, forKey: .held) ?? [:]
    }

    /// Notes what `runs` say now and returns the alerts due. A switch that's off still uses up
    /// the episode, so turning it on later never replays old news.
    /// As on the Mac: a session's own plan list says it stopped or finished only once it has had a
    /// quarter of an hour of work; a plan the agent declared always does.
    static func worthWatching(_ r: RunDigest) -> Bool { !r.mirrored || (r.workingSeconds ?? 0) >= 15 * 60 }

    public mutating func observe(_ runs: [RunDigest], now: Date, needsInput: Bool, finished notifyFinished: Bool,
                                 stopped notifyStopped: Bool = false) -> Decision {
        var out = Decision()
        var stillWaiting: Set<String> = [], stillStopped: Set<String> = []
        for r in runs {
            if !r.isSettled, r.state == .waiting, r.waitReason == .input {
                stillWaiting.insert(r.id)
                // Back at work after finishing, even if first seen asking: its next finish is news.
                if finished[r.id] != nil { reopened.insert(r.id) }
                // A quiet Mac can't say the agent is still waiting; it alerts once the Mac is back.
                guard r.lastSeen == nil else { continue }
                let release = r.macActiveAt.map { $0.addingTimeInterval(Self.activeHold) }
                if waiting.contains(r.id) {
                    // Still at the Mac: push the held alert back.
                    if let due = held[r.id], due > now, let release, release > due {
                        held[r.id] = release
                        if primed, needsInput { out.due.append(Alert(kind: .needsInput, run: r, deliverAt: release)) }
                    }
                    continue
                }
                waiting.insert(r.id)
                // Nothing is held on the first look or with the switch off: the episode is used up,
                // so a later sync can't bring it back as a delayed alert.
                if let release, release > now {
                    if primed, needsInput {
                        held[r.id] = release
                        out.due.append(Alert(kind: .needsInput, run: r, deliverAt: release))
                    }
                } else if primed, needsInput {
                    out.due.append(Alert(kind: .needsInput, run: r))
                }
            } else if r.isSettled {
                let fresh = now.timeIntervalSince(r.updatedAt) < Self.finishFreshness
                if let last = finished[r.id] {
                    guard reopened.remove(r.id) != nil, now.timeIntervalSince(last) >= Self.finishSpacing else { continue }
                }
                finished[r.id] = now
                if primed, notifyFinished, fresh, Self.worthWatching(r) { out.due.append(Alert(kind: .finished, run: r)) }
            } else {
                if finished[r.id] != nil { reopened.insert(r.id) }
                // A turn that ended after real work, with the session still there. A session that
                // simply ends settles without a word.
                if r.yourTurn {
                    stillStopped.insert(r.id)
                    if stopped.insert(r.id).inserted, primed, notifyStopped, r.turnWorthTelling, Self.worthWatching(r),
                       now.timeIntervalSince(r.updatedAt) < Self.finishFreshness {
                        out.due.append(Alert(kind: .stopped, run: r))
                    }
                }
            }
        }
        // Answered (or gone) before a held alert went out: take it back.
        out.withdraw = held.filter { !stillWaiting.contains($0.key) && $0.value > now }.map(\.key).sorted()
        held = held.filter { stillWaiting.contains($0.key) && $0.value > now }
        waiting.formIntersection(stillWaiting)
        stopped.formIntersection(stillStopped.union(runs.filter { $0.state == .stopped && $0.lastSeen != nil }.map(\.id)))
        finished = finished.filter { now.timeIntervalSince($0.value) < 2 * 86400 }
        reopened = reopened.filter { finished[$0] != nil }
        primed = true
        return out
    }
}
