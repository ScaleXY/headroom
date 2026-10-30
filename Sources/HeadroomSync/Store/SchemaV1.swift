import Foundation
import SwiftData

// The records Macs write to the private iCloud database. CloudKit's production schema only ever
// grows, so the columns stay to keys, timestamps and a version; content lives in the encrypted,
// versioned `payload`. No relationships and no unique constraints: CloudKit allows neither. Each
// record has exactly one writer, the Mac named by `deviceID`, so writes never conflict.

public enum HeadroomSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [DeviceRecord.self, AccountLiveRecord.self, AccountArchiveRecord.self, ActivityDayRecord.self]
    }

    /// One per Mac: identity, heartbeat and the settings readers need.
    @Model
    public final class DeviceRecord {
        public var deviceID: String = ""
        public var updatedAt: Date = Date.distantPast
        /// Heartbeat, every 10 minutes while the Mac is awake.
        public var lastSeenAt: Date = Date.distantPast
        public var payloadVersion: Int = 1
        /// `DevicePayload`.
        @Attribute(.allowsCloudEncryption) public var payload: Data? = nil

        public init(deviceID: String) { self.deviceID = deviceID }
    }

    /// One per (Mac, provider, account): the latest reading and the current windows.
    @Model
    public final class AccountLiveRecord {
        public var deviceID: String = ""
        public var provider: String = ""
        @Attribute(.allowsCloudEncryption) public var accountKey: String = ""
        public var readingAt: Date? = nil
        public var updatedAt: Date = Date.distantPast
        public var payloadVersion: Int = 1
        /// `AccountLivePayload`.
        @Attribute(.allowsCloudEncryption) public var payload: Data? = nil

        public init(deviceID: String, provider: String, accountKey: String) {
            self.deviceID = deviceID; self.provider = provider; self.accountKey = accountKey
        }
    }

    /// One per (Mac, provider, account): finished weeks and sessions.
    @Model
    public final class AccountArchiveRecord {
        public var deviceID: String = ""
        public var provider: String = ""
        @Attribute(.allowsCloudEncryption) public var accountKey: String = ""
        public var updatedAt: Date = Date.distantPast
        public var payloadVersion: Int = 1
        /// `AccountArchivePayload`.
        @Attribute(.allowsCloudEncryption) public var payload: Data? = nil

        public init(deviceID: String, provider: String, accountKey: String) {
            self.deviceID = deviceID; self.provider = provider; self.accountKey = accountKey
        }
    }

    /// One per (Mac, provider, account, UTC day): quarter-hour token and cost buckets by model.
    @Model
    public final class ActivityDayRecord {
        public var deviceID: String = ""
        public var provider: String = ""
        @Attribute(.allowsCloudEncryption) public var accountKey: String = ""
        /// `floor(epochSeconds / 86400)`.
        public var day: Int = 0
        public var updatedAt: Date = Date.distantPast
        public var payloadVersion: Int = 1
        /// `ActivityDayPayload`.
        @Attribute(.allowsCloudEncryption) public var payload: Data? = nil

        public init(deviceID: String, provider: String, accountKey: String, day: Int) {
            self.deviceID = deviceID; self.provider = provider; self.accountKey = accountKey; self.day = day
        }
    }
}

public enum HeadroomMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [HeadroomSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public typealias DeviceRecord = HeadroomSchemaV1.DeviceRecord
public typealias AccountLiveRecord = HeadroomSchemaV1.AccountLiveRecord
public typealias AccountArchiveRecord = HeadroomSchemaV1.AccountArchiveRecord
public typealias ActivityDayRecord = HeadroomSchemaV1.ActivityDayRecord
