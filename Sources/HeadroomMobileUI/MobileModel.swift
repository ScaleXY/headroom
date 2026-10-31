import Foundation
import HeadroomKit
import HeadroomSync
import Observation
import SwiftUI
#if canImport(CloudKit)
import CloudKit
#endif

/// System, light or dark, as on the Mac.
public enum MobileAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    public var title: String { rawValue.capitalized }
    public var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Whether iCloud can bring this device the Macs' records.
public enum ICloudState: Equatable, Sendable {
    case checking
    case available
    case noAccount
    case restricted
    /// This build carries no iCloud entitlement (a simulator or CI build).
    case unsupported
    case unknown
}

/// Choices that belong to this device. They live in the App Group so widgets can read them.
@MainActor
@Observable
public final class MobilePreferences {
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: FeedFile.appGroup) ?? .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: "appearance").flatMap(MobileAppearance.init(rawValue:)) ?? .system
        hiddenAccounts = Set(defaults.stringArray(forKey: "hiddenAccounts") ?? [])
        demo = defaults.bool(forKey: "demo")
        notifySessionBack = defaults.object(forKey: "notify.sessionBack") as? Bool ?? true
        notifyWeekRenews = defaults.bool(forKey: "notify.weekRenews")
        autoTrackSessions = defaults.bool(forKey: "liveActivity.auto")
    }

    public var appearance: MobileAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Accounts hidden from Now (they stay in Settings, to bring back).
    public var hiddenAccounts: Set<String> { didSet { defaults.set(Array(hiddenAccounts).sorted(), forKey: "hiddenAccounts") } }
    /// Sample data instead of iCloud (the empty state's "Explore" button, and App Review).
    public var demo: Bool { didSet { defaults.set(demo, forKey: "demo") } }
    /// "Your 5-hour session is back", at the reset of a session that warned.
    public var notifySessionBack: Bool { didSet { defaults.set(notifySessionBack, forKey: "notify.sessionBack") } }
    /// An hour before the week renews with a fifth or more unused.
    public var notifyWeekRenews: Bool { didSet { defaults.set(notifyWeekRenews, forKey: "notify.weekRenews") } }
    /// Start the session Live Activity when the app opens during a session.
    public var autoTrackSessions: Bool { didSet { defaults.set(autoTrackSessions, forKey: "liveActivity.auto") } }
}

/// Everything the iPhone and iPad screens read: the merged accounts, this device's choices, and
/// iCloud's state. The app shell plugs in the live store and the platform services.
@MainActor
@Observable
public final class MobileModel {
    public let reader: SyncReaderModel
    public let prefs: MobilePreferences
    public private(set) var iCloud: ICloudState = .checking
    /// Accounts with a running session Live Activity.
    public var tracking: Set<String> = []

    /// Starts or stops an account's Live Activity (set by the app shell; nil where unsupported).
    @ObservationIgnored public var setTracking: ((String, Bool) -> Void)?
    @ObservationIgnored private let live: (any SyncReading)?
    @ObservationIgnored private let cloudKit: Bool

    /// `live` is the iCloud mirror, or nil in builds that can't sync (only demo data then).
    public init(live: (any SyncReading)?, cloudKit: Bool, prefs: MobilePreferences = MobilePreferences()) {
        self.live = live
        self.cloudKit = cloudKit && live != nil
        self.prefs = prefs
        let demo = prefs.demo || live == nil
        reader = SyncReaderModel(source: demo ? FixtureSyncStore(DemoRecords.make(DemoRecords.launchScenario)) : live!, isDemo: demo)
        if !self.cloudKit { iCloud = .unsupported }
    }

    /// A model on demo data, for previews and the PNG renderer.
    public static func demo(_ scenario: DemoRecords.Scenario = .twoMacs, now: Date = Date()) -> MobileModel {
        let m = MobileModel(live: nil, cloudKit: false, prefs: MobilePreferences(defaults: UserDefaults(suiteName: "headroom.preview") ?? .standard))
        Task { await m.reader.use(FixtureSyncStore(DemoRecords.make(scenario, now: now)), isDemo: true) }
        return m
    }

    public func start() {
        reader.start()
        Task { await refreshICloud() }
    }

    /// Switches between sample data and iCloud.
    public func setDemo(_ on: Bool) async {
        prefs.demo = on
        if on || live == nil {
            await reader.use(FixtureSyncStore(DemoRecords.make(DemoRecords.launchScenario)), isDemo: true)
        } else if let live {
            await reader.use(live, isDemo: false)
        }
    }

    public func refreshICloud() async {
        guard cloudKit else { iCloud = .unsupported; return }
        #if canImport(CloudKit)
        do {
            iCloud = switch try await CKContainer(identifier: SyncContainer.cloudKitIdentifier).accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted, .temporarilyUnavailable: .restricted
            default: .unknown
            }
        } catch {
            iCloud = .unknown
        }
        #endif
    }

    // MARK: What the screens show

    public var visibleAccounts: [MergedAccount] {
        reader.activeAccounts.filter { !prefs.hiddenAccounts.contains($0.id) }
    }

    public var hiddenOrInactive: [MergedAccount] {
        reader.accounts.filter { !$0.isActive || prefs.hiddenAccounts.contains($0.id) }
    }

    /// Accounts in the order the cards appear: blocked first, then the tighter.
    public var orderedAccounts: [MergedAccount] {
        visibleAccounts.sorted { a, b in urgency(a) > urgency(b) }
    }

    func urgency(_ a: MergedAccount) -> Double {
        guard let p = reader.feed.account(a.id) else { return -1 }
        if p.blockedUntil != nil { return 100 }
        let session = p.session.map { $0.isIdle ? 0 : Double($0.level.rawValue) * 1.5 } ?? 0
        return Double(p.week?.state.rawValue ?? 0) * 2 + session + (1 - (p.week?.left ?? 1))
    }

    public func device(_ id: String) -> DeviceInfo? { reader.snapshot.device(id) }
}
