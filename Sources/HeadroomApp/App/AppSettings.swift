import AppKit
import HeadroomKit
import HeadroomPresent
import HeadroomSMC

/// User preferences (Settings window). Backed by UserDefaults; nothing secret is stored here.
@MainActor
final class AppSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults === UserDefaults.standard { Self.adoptLegacySettings(into: defaults) }
    }

    /// Betas up to 0.1.0-beta.4 shipped as `com.headroom.app`; carry their settings over once.
    private static func adoptLegacySettings(into defaults: UserDefaults) {
        let legacy = "com.headroom.app"
        guard !defaults.bool(forKey: "adoptedLegacySettings"),
              let id = Bundle.main.bundleIdentifier, id != legacy else { return }
        for (key, value) in defaults.persistentDomain(forName: legacy) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "adoptedLegacySettings")
    }

    private func changed() { onChange?() }

    var enabledProviders: Set<Provider> {
        get {
            let disabled = Set((defaults.stringArray(forKey: "disabledProviders") ?? []).compactMap(Provider.init(rawValue:)))
            return Set(Provider.allCases).subtracting(disabled)
        }
        set {
            defaults.set(Provider.allCases.filter { !newValue.contains($0) }.map(\.rawValue), forKey: "disabledProviders")
            changed()
        }
    }

    var menuBarMode: MenuBarMode {
        get { defaults.string(forKey: "menuBarMode").flatMap(MenuBarMode.init(rawValue:)) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "menuBarMode"); changed() }
    }

    /// Monthly plan price override in USD (nil = the plan's list price).
    func planPriceOverride(_ p: Provider) -> Double? {
        let v = defaults.double(forKey: "planPrice.\(p.rawValue)")
        return defaults.object(forKey: "planPrice.\(p.rawValue)") == nil ? nil : v
    }

    func setPlanPriceOverride(_ value: Double?, for p: Provider) {
        if let value { defaults.set(value, forKey: "planPrice.\(p.rawValue)") } else { defaults.removeObject(forKey: "planPrice.\(p.rawValue)") }
        changed()
    }

    var statusChecks: Bool {
        get { defaults.object(forKey: "statusChecks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "statusChecks"); changed() }
    }

    var costOnShares: Bool {
        get { defaults.object(forKey: "costOnShares") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "costOnShares"); changed() }
    }

    /// Offer beta releases too. On by default for anyone already running a beta.
    var betaUpdates: Bool {
        get {
            let version = AppUpdater.currentVersion ?? ""
            return defaults.object(forKey: "betaUpdates") as? Bool ?? version.contains("-")
        }
        set { defaults.set(newValue, forKey: "betaUpdates"); changed() }
    }

    // MARK: Welcome

    /// Set once the welcome window has been finished (or skipped).
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    // MARK: 5-hour session

    /// Used share at which the 5-hour session starts warning (amber). 75% by default.
    var sessionWarnAt: Double {
        get { (defaults.object(forKey: "sessionWarnAt") as? Double).map { min(max($0, 0.3), 0.95) } ?? 0.75 }
        set { defaults.set(newValue, forKey: "sessionWarnAt"); changed() }
    }

    static let sessionWarnChoices: [Double] = [0.5, 0.6, 0.75, 0.9]

    var sessionDetail: SessionDetail {
        get { defaults.string(forKey: "sessionDetail").flatMap(SessionDetail.init(rawValue:)) ?? .detailed }
        set { defaults.set(newValue.rawValue, forKey: "sessionDetail"); changed() }
    }

    var policy: PacingPolicy { .sessionWarning(at: sessionWarnAt) }

    // MARK: Pace card

    /// The five-cell meter and the graph, for the week and the 5-hour session. All on by default.
    func shows(_ part: CardPart) -> Bool {
        defaults.object(forKey: "show.\(part.rawValue)") as? Bool ?? true
    }

    func setShows(_ part: CardPart, _ on: Bool) {
        defaults.set(on, forKey: "show.\(part.rawValue)")
        changed()
    }

    // MARK: Menu bar extras

    var meterFocus: MeterFocus {
        get { defaults.string(forKey: "meterFocus").flatMap(MeterFocus.init(rawValue:)) ?? .week }
        set { defaults.set(newValue.rawValue, forKey: "meterFocus"); changed() }
    }

    /// Show the 5-hour ring and countdown whenever a session is running, not only near the limit.
    var alwaysShowSessionTimer: Bool {
        get { defaults.bool(forKey: "alwaysShowSessionTimer") }
        set { defaults.set(newValue, forKey: "alwaysShowSessionTimer"); changed() }
    }

    var showPercentInMenuBar: Bool {
        get { defaults.bool(forKey: "showPercentInMenuBar") }
        set { defaults.set(newValue, forKey: "showPercentInMenuBar"); changed() }
    }

    var appearance: AppAppearance {
        get { defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance"); changed() }
    }

    /// Everything the presenters need from Settings.
    var presentation: PresentationOptions {
        PresentationOptions(sessionDetail: sessionDetail, meterFocus: meterFocus, alwaysShowSessionTimer: alwaysShowSessionTimer,
                            showPercent: showPercentInMenuBar, parts: Set(CardPart.allCases.filter(shows)))
    }

    // MARK: Notifications

    func notifies(_ kind: NotificationKind) -> Bool {
        defaults.object(forKey: "notify.\(kind.rawValue)") as? Bool ?? kind.defaultOn
    }

    func setNotifies(_ kind: NotificationKind, _ on: Bool) {
        defaults.set(on, forKey: "notify.\(kind.rawValue)")
        changed()
    }

    // MARK: Task tracking

    /// Read agent transcripts and keep `tasks.json`: the observer and the feed writer. On by default.
    var taskTracking: Bool {
        get { defaults.object(forKey: "taskTracking") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "taskTracking"); changed() }
    }

    func taskNotifies(_ kind: TaskNotificationKind) -> Bool {
        defaults.object(forKey: "notify.task.\(kind.rawValue)") as? Bool ?? kind.defaultOn
    }

    func setTaskNotifies(_ kind: TaskNotificationKind, _ on: Bool) {
        defaults.set(on, forKey: "notify.task.\(kind.rawValue)")
        changed()
    }

    /// How long a running task or run may go without activity before it reads as quiet (and the
    /// "went quiet" alert can fire). 15 minutes by default.
    var runQuietAfter: TimeInterval {
        get {
            let v = defaults.double(forKey: "runQuietAfter")
            return Self.runQuietChoices.contains(v) ? v : TaskFold.defaultStaleAfter
        }
        set { defaults.set(newValue, forKey: "runQuietAfter"); changed() }
    }

    static let runQuietChoices: [TimeInterval] = [10 * 60, 15 * 60, 30 * 60, 60 * 60]

    /// How the Runs tab lists runs. Ledger by default.
    var runsListStyle: RunsListStyle {
        get { RunsListStyle(rawValue: defaults.integer(forKey: "runsListStyle")) ?? .ledger }
        set { defaults.set(newValue.rawValue, forKey: "runsListStyle"); changed() }
    }

    /// How a run's own page draws it. Briefing by default.
    var runPageStyle: RunPageStyle {
        get { RunPageStyle(rawValue: defaults.integer(forKey: "runPageStyle")) ?? .briefing }
        set { defaults.set(newValue.rawValue, forKey: "runPageStyle"); changed() }
    }

    /// While a run is live, its progress (and a mark when one needs you) beside the meters. On by default.
    var showRunsInMenuBar: Bool {
        get { defaults.object(forKey: "showRunsInMenuBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showRunsInMenuBar"); changed() }
    }

    // MARK: iPhone & Watch

    /// Sync to the user's private iCloud for Headroom on iPhone, iPad and Apple Watch.
    var syncEnabled: Bool {
        get { defaults.bool(forKey: "sync.enabled") }
        set { defaults.set(newValue, forKey: "sync.enabled"); changed() }
    }

    /// Sync run titles and the titles of their most pressing rows, not only structure and state.
    /// Off by default: project names, notes and failure reasons never sync either way.
    var syncTaskNames: Bool {
        get { defaults.bool(forKey: "sync.taskNames") }
        set { defaults.set(newValue, forKey: "sync.taskNames"); changed() }
    }

    /// Also sync the wording of a question a run is waiting on, so the phone can say what's being
    /// asked. Off by default; only meaningful with task names on.
    var syncQuestionText: Bool {
        get { defaults.bool(forKey: "sync.questionText") }
        set { defaults.set(newValue, forKey: "sync.questionText"); changed() }
    }

    /// When this Mac first turned sync on (cleared by "Remove from iCloud").
    var syncSince: Date? {
        get { defaults.object(forKey: "sync.since") as? Date }
        set { defaults.set(newValue, forKey: "sync.since") }
    }

    // MARK: Keep awake (caffeinate)

    /// The assertions Keep Awake holds. Idle sleep only by default, like `caffeinate` itself.
    var awakeModes: Set<AwakeMode> {
        get {
            let modes = Set((defaults.stringArray(forKey: "awakeModes") ?? []).compactMap(AwakeMode.init(rawValue:)))
            return modes.isEmpty ? [.idle] : modes
        }
        set { defaults.set(AwakeMode.allCases.filter(newValue.contains).map(\.rawValue), forKey: "awakeModes") }
    }

    /// The last duration picked, so the menu can mark it.
    var awakeDuration: AwakeDuration {
        get { (defaults.object(forKey: "awakeDuration") as? Int).flatMap(AwakeDuration.init(rawValue:)) ?? .indefinitely }
        set { defaults.set(newValue.rawValue, forKey: "awakeDuration") }
    }

    /// Keep Awake was on when Headroom last ran; it turns back on at launch.
    var awakeActive: Bool {
        get { defaults.bool(forKey: "awakeActive") }
        set { defaults.set(newValue, forKey: "awakeActive") }
    }

    /// When the saved Keep Awake run ends (nil = until turned off).
    var awakeUntil: Date? {
        get { defaults.object(forKey: "awakeUntil") as? Date }
        set { defaults.set(newValue, forKey: "awakeUntil") }
    }

    // MARK: Fan control

    /// Fans sit at their lowest speed here and are macOS's below it.
    var fanMinTemp: Int {
        get { defaults.object(forKey: "fanMinTemp") as? Int ?? 45 }
        set { defaults.set(newValue, forKey: "fanMinTemp") }
    }

    /// Fans run flat out from here.
    var fanMaxTemp: Int {
        get { defaults.object(forKey: "fanMaxTemp") as? Int ?? 70 }
        set { defaults.set(newValue, forKey: "fanMaxTemp") }
    }

    /// What the fan curve follows.
    var fanSensor: FanSensor {
        get { defaults.string(forKey: "fanSensor").flatMap(FanSensor.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: "fanSensor") }
    }

    /// Defaults suit the averaged sensors, which run about 20 °C below the hottest core.
    static let fanMinTempChoices = Array(stride(from: 35, through: 75, by: 5))
    static let fanMaxTempChoices = Array(stride(from: 50, through: 95, by: 5))

    /// While Fan Control runs, the sensor's temperature and the fan speed sit beside the meters.
    var showFanInMenuBar: Bool {
        get { defaults.object(forKey: "showFanInMenuBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFanInMenuBar"); changed() }
    }

    /// Fan control was on when Headroom last ran; it turns back on at launch.
    var fanActive: Bool {
        get { defaults.bool(forKey: "fanActive") }
        set { defaults.set(newValue, forKey: "fanActive") }
    }

    /// User-set CLI paths (Settings → Command-line tools).
    func cliPath(_ tool: String) -> String? {
        let v = defaults.string(forKey: "cliPath.\(tool)")
        return (v?.isEmpty ?? true) ? nil : v
    }

    func setCLIPath(_ path: String?, for tool: String) {
        defaults.set(path, forKey: "cliPath.\(tool)")
        changed()
    }

    // Popover view state (remembered between openings).
    var activityMode: ActivityMode {
        get { ActivityMode(rawValue: defaults.integer(forKey: "activityMode")) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: "activityMode") }
    }

    var activityRange: ActivityRange {
        get { ActivityRange(rawValue: defaults.integer(forKey: "activityRange")) ?? .day }
        set { defaults.set(newValue.rawValue, forKey: "activityRange") }
    }

    var breakdown: BreakdownKind {
        get { BreakdownKind(rawValue: defaults.integer(forKey: "breakdown")) ?? .model }
        set { defaults.set(newValue.rawValue, forKey: "breakdown") }
    }

    var lastTab: Int {
        get { defaults.integer(forKey: "lastTab") }
        set { defaults.set(newValue, forKey: "lastTab") }
    }
}

enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String { rawValue.capitalized }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Task-run notifications; kept apart from `NotificationKind`, whose cases the Settings window lists.
enum TaskNotificationKind: String, CaseIterable, Sendable {
    case needsInput, stopped, criticalFailed, stale, finished

    var defaultOn: Bool { self == .needsInput || self == .stopped || self == .finished }

    var title: String {
        switch self {
        case .needsInput: "A run needs your input"
        case .stopped: "A run stopped with work left"
        case .criticalFailed: "A critical task failed"
        case .stale: "A run went quiet"
        case .finished: "A run finished"
        }
    }
}

enum NotificationKind: String, CaseIterable, Sendable {
    case sessionWarning, sessionLimit, sessionReset, weeklyTight, creditsExpiring

    var defaultOn: Bool { self != .weeklyTight }

    var title: String {
        switch self {
        case .sessionWarning: "5-hour session almost used"
        case .sessionLimit: "5-hour limit reached"
        case .sessionReset: "5-hour session reset"
        case .weeklyTight: "Week getting tight"
        case .creditsExpiring: "Reset credits about to lapse"
        }
    }
}
