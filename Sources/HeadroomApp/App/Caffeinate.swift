import Foundation

/// The sleep assertions `caffeinate(8)` can hold, one per flag.
enum AwakeMode: String, CaseIterable, Sendable {
    case display, idle, disk, system, user

    var flag: String {
        switch self {
        case .display: "-d"
        case .idle: "-i"
        case .disk: "-m"
        case .system: "-s"
        case .user: "-u"
        }
    }

    var title: String {
        switch self {
        case .display: "Display sleep"
        case .idle: "Idle sleep"
        case .disk: "Disk sleep"
        case .system: "System sleep (on power adapter)"
        case .user: "Declare user active"
        }
    }

    var help: String {
        switch self {
        case .display: "Keeps the display from sleeping."
        case .idle: "Keeps the Mac from sleeping when idle. This is caffeinate's default."
        case .disk: "Keeps the disk from idle sleeping."
        case .system: "Keeps the Mac from sleeping at all. Only applies while on AC power."
        case .user: "Turns the display on as if you'd touched the Mac, and keeps it from idle sleeping."
        }
    }
}

/// How long to stay awake. Raw values are minutes; 0 and -1 are special.
enum AwakeDuration: Int, CaseIterable, Sendable {
    case fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60, twoHours = 120, fiveHours = 300, eightHours = 480
    /// Until the soonest 5-hour session among the enabled providers resets.
    case sessionReset = -1
    case indefinitely = 0

    var title: String {
        switch self {
        case .sessionReset: "Until the 5-hour session resets"
        case .indefinitely: "Indefinitely"
        default: rawValue < 60 ? "\(rawValue) minutes" : rawValue == 60 ? "1 hour" : "\(rawValue / 60) hours"
        }
    }

    /// When it ends, given the next session reset; nil = no end.
    func end(from now: Date, sessionReset: Date?) -> Date? {
        switch self {
        case .indefinitely: nil
        case .sessionReset: sessionReset
        default: now.addingTimeInterval(TimeInterval(rawValue * 60))
        }
    }
}

/// Keeps the Mac awake by running `/usr/bin/caffeinate`. The child is tied to Headroom's pid
/// (`-w`), so it never outlives the app, and ends itself at the chosen time (`-t`). Whether it's
/// on is saved, so it comes back on at the next launch for whatever time is left.
@MainActor
final class Caffeinate {
    static let executable = URL(fileURLWithPath: "/usr/bin/caffeinate")

    private let settings: AppSettings
    private var process: Process?
    private(set) var modes: Set<AwakeMode> = []
    /// When the current run ends on its own; nil while off or running indefinitely.
    private(set) var until: Date?
    var onChange: (() -> Void)?

    var isOn: Bool { process != nil }

    init(settings: AppSettings) {
        self.settings = settings
    }

    static func arguments(modes: Set<AwakeMode>, until: Date?, now: Date = Date(), pid: Int32 = getpid()) -> [String] {
        var args = AwakeMode.allCases.filter(modes.contains).map(\.flag)
        if let until { args += ["-t", String(max(1, Int(until.timeIntervalSince(now).rounded(.up))))] }
        return args + ["-w", String(pid)]
    }

    /// At launch: turns back on if it was on when Headroom last quit and its time hasn't run out.
    func restore(now: Date = Date()) {
        guard settings.awakeActive else { return }
        let until = settings.awakeUntil
        if let until, until <= now { settings.awakeActive = false; return }
        start(modes: settings.awakeModes, until: until)
    }

    /// Starts (or restarts) with these assertions until `until` (nil = until turned off).
    func start(modes: Set<AwakeMode>, until: Date?) {
        end()
        if let until, until <= Date() { saveOff(); onChange?(); return }
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = Self.arguments(modes: modes, until: until)
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Ran out (or was killed): off for good. A stop or restart has already let go of `p`.
                    guard let self, self.process === p else { return }
                    self.process = nil
                    self.until = nil
                    self.saveOff()
                    self.onChange?()
                }
            }
        }
        do {
            try process.run()
            self.process = process
            self.modes = modes
            self.until = until
            settings.awakeActive = true
            settings.awakeUntil = until
        } catch {
            diag.error("caffeinate failed to start")
            saveOff()
        }
        onChange?()
    }

    /// Turned off by the user: stays off at the next launch.
    func stop() {
        guard isOn else { return }
        end()
        saveOff()
        onChange?()
    }

    /// Quitting: ends caffeinate now but keeps it on for the next launch.
    func suspendForQuit() { end() }

    private func end() {
        guard let process else { return }
        self.process = nil
        until = nil
        if process.isRunning { process.terminate() }
    }

    private func saveOff() {
        settings.awakeActive = false
        settings.awakeUntil = nil
    }
}
