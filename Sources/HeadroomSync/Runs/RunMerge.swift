import Foundation
import HeadroomKit
import HeadroomPresent

/// Every Mac's runs in one list for the Runs section, each labelled with its Mac's name.
public enum RunMerge {
    /// A Mac not heard from for this long (or asleep, or quit) can't vouch for its live runs.
    public static let quietAfter: TimeInterval = AccountReader.recentWindow

    /// Live runs on Macs still heard from, most pressing first; then live runs on Macs gone
    /// quiet ("last seen 2h ago"); then finished runs, newest first. Anything not updated in the
    /// last day drops out, as it does on the Mac.
    public static func digests(_ devices: [DeviceEnvelope], now: Date) -> [RunDigest] {
        var out: [RunDigest] = []
        for d in devices {
            guard let runs = d.payload.runs else { continue }
            let quiet = d.payload.state != .awake || now.timeIntervalSince(d.lastSeenAt) > quietAfter
            for r in runs where now.timeIntervalSince(r.updatedAt) < RunSummaryBuilder.finishedWindow {
                out.append(r.digest(deviceID: d.deviceID, mac: d.payload.name, lastSeen: quiet ? d.lastSeenAt : nil))
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

/// What a phone has already said about runs, so each needs-input episode and each finish gets
/// at most one notification however often syncs arrive. Kept between launches by the app.
public struct RunAlertLedger: Codable, Sendable, Hashable {
    public enum Kind: String, Sendable { case needsInput, finished }

    /// Off until the first look: runs already waiting or finished then were there before this
    /// device was paying attention, and never alert.
    public var primed = false
    /// Runs in a needs-input episode that's been handled. Leaving the state ends the episode.
    public var waiting: Set<String> = []
    /// Finished runs already handled, and when (forgotten after two days).
    public var finished: [String: Date] = [:]

    /// A finish older than this when it first arrives is old news.
    public static let finishFreshness: TimeInterval = 3600

    public init() {}

    /// Notes what `runs` say now and returns the alerts due. A switch that's off still uses up
    /// the episode, so turning it on later never replays old news.
    public mutating func observe(_ runs: [RunDigest], now: Date, needsInput: Bool, finished notifyFinished: Bool) -> [(kind: Kind, run: RunDigest)] {
        var due: [(kind: Kind, run: RunDigest)] = []
        var stillWaiting: Set<String> = []
        for r in runs {
            if !r.state.isTerminal, r.state == .waiting, r.waitReason == .input {
                stillWaiting.insert(r.id)
                // A quiet Mac can't say the agent is still waiting; it alerts once the Mac is back.
                guard r.lastSeen == nil, !waiting.contains(r.id) else { continue }
                waiting.insert(r.id)
                if primed, needsInput { due.append((.needsInput, r)) }
            } else if r.state.isTerminal, finished[r.id] == nil {
                finished[r.id] = now
                if primed, notifyFinished, now.timeIntervalSince(r.updatedAt) < Self.finishFreshness { due.append((.finished, r)) }
            }
        }
        waiting.formIntersection(stillWaiting)
        finished = finished.filter { now.timeIntervalSince($0.value) < 2 * 86400 }
        primed = true
        return due
    }
}
