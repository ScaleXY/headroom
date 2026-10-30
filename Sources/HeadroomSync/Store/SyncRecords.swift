import Foundation
import HeadroomKit

/// A decoded record: its natural key, when it was written, and its payload.
public struct Envelope<Payload: Sendable>: Sendable {
    public var deviceID: String
    public var provider: Provider?
    public var accountKey: String
    public var day: Int?
    public var updatedAt: Date
    public var payload: Payload

    public init(deviceID: String, provider: Provider? = nil, accountKey: String = "", day: Int? = nil, updatedAt: Date, payload: Payload) {
        self.deviceID = deviceID; self.provider = provider; self.accountKey = accountKey; self.day = day
        self.updatedAt = updatedAt; self.payload = payload
    }

    /// The natural key: one writer, one record.
    public var key: String { [deviceID, provider?.rawValue ?? "", accountKey, day.map(String.init) ?? ""].joined(separator: "|") }
}

/// Device heartbeat alongside its payload.
public struct DeviceEnvelope: Sendable {
    public var deviceID: String
    public var updatedAt: Date
    public var lastSeenAt: Date
    public var payload: DevicePayload

    public init(deviceID: String, updatedAt: Date, lastSeenAt: Date, payload: DevicePayload) {
        self.deviceID = deviceID; self.updatedAt = updatedAt; self.lastSeenAt = lastSeenAt; self.payload = payload
    }
}

/// Everything synced, decoded: what readers merge.
public struct SyncRecords: Sendable {
    public var devices: [DeviceEnvelope] = []
    public var live: [Envelope<AccountLivePayload>] = []
    public var archives: [Envelope<AccountArchivePayload>] = []
    public var activity: [Envelope<ActivityDayPayload>] = []
    /// Records skipped because they came from a newer app or couldn't be decrypted or decoded.
    public var unreadable = 0
    /// Records whose payload came from a newer, incompatible app.
    public var tooNew = 0

    public init() {}

    public var isEmpty: Bool { devices.isEmpty && live.isEmpty }
}

/// Anything that can hand readers the synced records: the SwiftData mirror or a fixture.
public protocol SyncReading: Sendable {
    func records() async throws -> SyncRecords
}

/// Fixed records: demo mode, App Review, previews and tests.
public struct FixtureSyncStore: SyncReading {
    public var fixture: SyncRecords

    public init(_ fixture: SyncRecords) { self.fixture = fixture }

    public func records() async throws -> SyncRecords { fixture }
}
