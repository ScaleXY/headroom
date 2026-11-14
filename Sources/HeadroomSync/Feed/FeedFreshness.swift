import Foundation

/// The rule the Watch applies to a feed from the phone: only one stamped later than the one it
/// has is taken. The phone asks it first, so it doesn't build and send what would be dropped.
public enum FeedFreshness {
    public static func isNewer(_ generatedAt: Date, than last: Date?) -> Bool {
        guard let last else { return true }
        return generatedAt > last
    }
}
