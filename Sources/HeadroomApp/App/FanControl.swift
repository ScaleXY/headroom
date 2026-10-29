import Foundation
import HeadroomSMC
import ServiceManagement
@preconcurrency import XPC

/// A more aggressive fan curve than macOS's, for long AI runs: lowest speed at the min temperature,
/// full speed at the max, a straight line between, following the chosen sensor (FanSensor).
///
/// Writing fan speeds needs root, so the curve runs in Headroom's fan helper, a LaunchDaemon
/// registered with SMAppService that the user approves once in System Settings. The helper gives
/// the fans back to macOS when Headroom turns it off, quits or crashes. Whether it's on is saved,
/// so it comes back on at the next launch.
@MainActor
final class FanControl {
    enum State: Equatable {
        case off
        /// Waiting for the user to allow the helper in System Settings.
        case needsApproval
        case on
        case failed(String)
    }

    private let settings: AppSettings
    private let service = SMAppService.daemon(plistName: FanHelper.plistName)
    private let reader = Reader()
    private var connection: xpc_connection_t?
    private var approvalPoll: Timer?
    private var readoutTimer: Timer?
    private(set) var state: State = .off
    /// The menu bar readout, while Fan Control is running and Settings shows it; nil otherwise.
    private(set) var readout: FanReadout?
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Whether this Mac has fans at all (MacBook Airs don't).
    static let macHasFans = Reader().fanCount > 0

    var hasFans: Bool { Self.macHasFans }
    var isOn: Bool { state != .off }

    var curve: FanCurve { FanCurve(minTemp: Double(settings.fanMinTemp), maxTemp: Double(settings.fanMaxTemp)) }

    /// The chosen sensor and the fan speeds right now (reading needs no privileges).
    func reading() -> FanReading { reader.read(settings.fanSensor) }

    // MARK: Menu bar readout

    /// Starts or stops the menu bar readout to match the state and Settings.
    func updateReadout() {
        let wanted = state == .on && settings.showFanInMenuBar
        guard wanted != (readoutTimer != nil) else { return }
        readoutTimer?.invalidate()
        readoutTimer = nil
        guard wanted else {
            if readout != nil { readout = nil; onChange?() }
            return
        }
        refreshReadout()
        readoutTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReadout() }
        }
    }

    /// Reads off the main thread: a pass over every die sensor takes tens of milliseconds.
    private func refreshReadout() {
        reader.readInBackground(settings.fanSensor) { [weak self] reading in
            guard let self, self.readoutTimer != nil else { return }
            let next = FanReadout(reading)
            guard next != self.readout else { return }
            self.readout = next
            self.onChange?()
        }
    }

    /// At launch: turns back on if it was on when Headroom last quit. Doesn't open System Settings.
    func restore() {
        guard settings.fanActive, hasFans else { return }
        start(interactive: false)
    }

    /// Turns on, or sends a changed curve if already on. The first time, macOS asks the user to
    /// allow the helper; `interactive` opens System Settings at the right page for that.
    func start(interactive: Bool = true) {
        settings.fanActive = true
        switch service.status {
        case .enabled:
            send(curve)
        case .requiresApproval:
            awaitApproval(interactive: interactive)
        default:
            if let problem = Self.installProblem() { return set(.failed(problem)) }
            var reason = ""
            do { try service.register() } catch {
                diag.error("fan helper registration: \(error.localizedDescription, privacy: .public)")
                reason = " (\(error.localizedDescription))"
            }
            switch service.status {
            case .enabled: send(curve)
            case .requiresApproval: awaitApproval(interactive: interactive)
            default: set(.failed("Couldn't install the fan helper\(reason)."))
            }
        }
    }

    /// SMAppService registers the helper from inside the running app bundle, and the helper only
    /// talks to Headroom signed by its team. A bare `swift run` binary has neither.
    private static func installProblem() -> String? {
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(FanHelper.plistName)")
        guard FileManager.default.fileExists(atPath: plist.path) else { return "Fan Control only works in Headroom.app (make install)." }
        guard FanHelper.signingTeam() != nil else { return "Fan Control needs a signed Headroom.app (make install)." }
        return nil
    }

    /// Turned off by the user: fans go back to macOS and it stays off at the next launch.
    func stop() {
        settings.fanActive = false
        disconnect()
        set(.off)
    }

    /// Quitting: the helper gives the fans back, but it's on again at the next launch.
    func suspendForQuit() { disconnect() }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Approval

    private func awaitApproval(interactive: Bool) {
        set(.needsApproval)
        if interactive { openLoginItems() }
        guard approvalPoll == nil else { return }
        approvalPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.state == .needsApproval else { return self.endApprovalPoll() }
                if self.service.status == .enabled {
                    self.endApprovalPoll()
                    self.send(self.curve)
                }
            }
        }
    }

    private func endApprovalPoll() {
        approvalPoll?.invalidate()
        approvalPoll = nil
    }

    // MARK: Helper connection

    private func send(_ curve: FanCurve) {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "op", "curve")
        xpc_dictionary_set_double(message, "min", curve.minTemp)
        xpc_dictionary_set_double(message, "max", curve.maxTemp)
        xpc_dictionary_set_string(message, "sensor", settings.fanSensor.rawValue)
        xpc_connection_send_message_with_reply(connect(), message, .main) { reply in
            let reply = XPCObject(object: reply)
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.settings.fanActive else { return }
                if xpc_get_type(reply.object) != XPC_TYPE_DICTIONARY {
                    self.set(.failed("Couldn't reach the fan helper."))
                } else if let error = xpc_dictionary_get_string(reply.object, "error") {
                    self.set(.failed(String(cString: error)))
                } else {
                    self.set(.on)
                }
            }
        }
    }

    private func connect() -> xpc_connection_t {
        if let connection { return connection }
        let c = xpc_connection_create_mach_service(FanHelper.machService, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        // Talk only to our own helper.
        if let team = FanHelper.signingTeam() {
            _ = xpc_connection_set_peer_code_signing_requirement(c, FanHelper.requirement(identifier: FanHelper.helperIdentifier, team: team))
        }
        let weak = XPCObject(object: c)
        xpc_connection_set_event_handler(c) { event in
            let event = XPCObject(object: event)
            MainActor.assumeIsolated { [weak self] in
                guard let self, let connection = self.connection, connection === weak.object else { return }
                if event.object === XPC_ERROR_CONNECTION_INTERRUPTED {
                    // The helper restarted (and gave the fans back): hand it the curve again.
                    if self.settings.fanActive { self.send(self.curve) }
                } else if event.object === XPC_ERROR_CONNECTION_INVALID {
                    self.connection = nil
                    if self.settings.fanActive { self.set(.failed("Couldn't reach the fan helper.")) }
                }
            }
        }
        xpc_connection_activate(c)
        connection = c
        return c
    }

    /// Cancelling the connection is the signal: the helper gives the fans back.
    private func disconnect() {
        endApprovalPoll()
        guard let connection else { return }
        self.connection = nil
        xpc_connection_cancel(connection)
    }

    private func set(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        updateReadout()
        onChange?()
    }

}

/// XPC objects are thread-safe; this carries them onto the main actor.
private struct XPCObject: @unchecked Sendable { let object: xpc_object_t }

struct FanReading: Sendable {
    var temperature: Double?
    var speeds: [Double]
}

/// What the menu bar shows: whole degrees and the fastest fan to the nearest 100 rpm, so it
/// redraws only when something visibly changes.
struct FanReadout: Hashable {
    var temperature: Int?
    var rpm: Int?

    init(temperature: Int?, rpm: Int?) {
        self.temperature = temperature
        self.rpm = rpm
    }

    init(_ reading: FanReading) {
        temperature = reading.temperature.map { Int($0.rounded()) }
        rpm = reading.speeds.max().map { Int(($0 / 100).rounded()) * 100 }
    }

    var degrees: String { temperature.map { "\($0)°" } ?? "–°" }
    /// "3.4k", or "980" below a thousand.
    var speed: String {
        guard let rpm else { return "–" }
        return rpm < 1000 ? "\(rpm)" : String(format: "%.1fk", Double(rpm) / 1000)
    }

    var spoken: String {
        [temperature.map { "\($0) degrees" }, rpm.map { "fan \($0) rpm" }].compactMap(\.self).joined(separator: ", ")
    }
}

/// The SMC, read on its own queue (Thermals isn't thread-safe).
private final class Reader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.scalexy.headroom.fan-reader", qos: .utility)
    private let thermals = try? Thermals()

    var fanCount: Int { queue.sync { thermals?.fanCount ?? 0 } }

    func read(_ sensor: FanSensor) -> FanReading { queue.sync { unsafeRead(sensor) } }

    func readInBackground(_ sensor: FanSensor, then done: @escaping @MainActor @Sendable (FanReading) -> Void) {
        queue.async {
            let reading = self.unsafeRead(sensor)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(reading) } }
        }
    }

    private func unsafeRead(_ sensor: FanSensor) -> FanReading {
        guard let thermals else { return FanReading(speeds: []) }
        return FanReading(temperature: thermals.temperature(sensor), speeds: (0..<thermals.fanCount).compactMap(thermals.speed))
    }
}
