import CloudKit
import Foundation
import HeadroomCore
import HeadroomSync
import IOKit
import Security

/// Whether this build can sync. iCloud needs entitlements that only Headroom's own signing profile
/// carries; a build from source runs without them, and must never touch CloudKit (it would trap).
enum SyncCapability {
    enum Unavailable: Equatable {
        /// Built without Headroom's signing profile.
        case unsignedBuild
        /// No iCloud account on this Mac.
        case noAccount
        /// iCloud is restricted (Screen Time, MDM) or temporarily unavailable.
        case restricted
        case couldNotDetermine
    }

    /// Whether the running binary carries the iCloud container entitlement.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        return (value as? [String])?.contains(SyncContainer.cloudKitIdentifier) ?? false
    }

    /// Nil when sync can run now.
    static func check() async -> Unavailable? {
        guard isEntitled else { return .unsignedBuild }
        do {
            switch try await CKContainer(identifier: SyncContainer.cloudKitIdentifier).accountStatus() {
            case .available: return nil
            case .noAccount: return .noAccount
            case .restricted, .temporarilyUnavailable: return .restricted
            default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }
}

/// This Mac, as other devices see it.
enum DeviceIdentity {
    /// Stable across reinstalls and wiped Application Support, and reveals nothing about the hardware.
    static let deviceID: String = {
        AccountKey.make(prefix: "mac", parts: ["headroom-device", platformUUID ?? Host.current().localizedName ?? "unknown"])
    }()

    /// The computer name ("Athul's MacBook Pro").
    static var name: String { Host.current().localizedName ?? "Mac" }

    /// `hw.model` ("Mac15,7").
    static var model: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &chars, &size, nil, 0) == 0 else { return nil }
        return String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static var platformUUID: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}
