import Foundation
import HeadroomSMC
import os
@preconcurrency import XPC

// Headroom's fan helper: a LaunchDaemon (root, so it can write the SMC) that the app registers with
// SMAppService. It follows the app's fan curve and gives the fans back to macOS when the app lets
// go, quits or crashes. Only Headroom signed by the same team may connect.
// See FanHelper for the messages.

let log = Logger(subsystem: FanHelper.label, category: "helper")

/// While the helper has the fans this file exists, so if the helper dies holding them, its next
/// start (launchd restarts it after a crash) hands them back. /var/run is cleared at boot.
let holdingMarker = "/var/run/\(FanHelper.label).holding"

@MainActor
final class Controller {
    static let interval: TimeInterval = 2

    private let thermals: Thermals
    private var governor: FanGovernor?
    private var sensor = FanSensor.default
    private var owner: xpc_connection_t?
    private var timer: Timer?
    private var holding = false

    init(thermals: Thermals) {
        self.thermals = thermals
        if FileManager.default.fileExists(atPath: holdingMarker) {
            log.notice("previous run held the fans; releasing")
            release()
        }
        exitWhenIdle()
    }

    func follow(_ curve: FanCurve, sensor: FanSensor, for peer: xpc_connection_t) -> String? {
        guard curve.isValid else { return "The min temperature must be below the max." }
        guard thermals.fanCount > 0 else { return "This Mac has no fans." }
        owner = peer
        self.sensor = sensor
        if governor == nil { governor = FanGovernor(curve: curve) } else { governor?.curve = curve }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
                MainActor.assumeIsolated { _ = self.tick() }
            }
        }
        return tick()
    }

    /// The owner let go or went away.
    func stop(for peer: xpc_connection_t) {
        guard owner.map({ $0 === peer }) ?? false else { return }
        owner = nil
        governor = nil
        timer?.invalidate()
        timer = nil
        if holding { release() }
        exitWhenIdle()
    }

    /// Shutdown, or the app unregistered the helper.
    func terminate() -> Never {
        if holding { release() }
        exit(0)
    }

    /// Nothing to do until the app asks again, and launchd starts the helper when it does.
    private func exitWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated { if self.owner == nil { exit(0) } }
        }
    }

    func handle(_ message: xpc_object_t, from peer: xpc_connection_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            // Invalidated or interrupted: the app quit, crashed or failed the signing check.
            stop(for: peer)
            return
        }
        var error: String?
        switch xpc_dictionary_get_string(message, "op").map({ String(cString: $0) }) {
        case "curve":
            let curve = FanCurve(minTemp: xpc_dictionary_get_double(message, "min"), maxTemp: xpc_dictionary_get_double(message, "max"))
            let sensor = xpc_dictionary_get_string(message, "sensor").flatMap { FanSensor(rawValue: String(cString: $0)) }
            error = follow(curve, sensor: sensor ?? .default, for: peer)
        case "release":
            stop(for: peer)
        default:
            error = "Unknown request."
        }
        if let reply = xpc_dictionary_create_reply(message) {
            if let error { xpc_dictionary_set_string(reply, "error", error) }
            xpc_connection_send_message(peer, reply)
        }
    }

    @discardableResult
    private func tick() -> String? {
        guard var governor else { return nil }
        let level = governor.tick(temperature: thermals.temperature(sensor))
        self.governor = governor
        guard let level else { if holding { release() }; return nil }
        do {
            if !holding {
                FileManager.default.createFile(atPath: holdingMarker, contents: nil)
                holding = true
            }
            // Rewritten every tick: macOS takes a fan back after sleep.
            for fan in 0..<thermals.fanCount { try thermals.run(fan: fan, level: level) }
            return nil
        } catch {
            log.error("fan write failed: \(String(describing: error), privacy: .public)")
            release()
            return "Couldn't set the fan speed (\(error))."
        }
    }

    private func release() {
        thermals.release()
        try? FileManager.default.removeItem(atPath: holdingMarker)
        holding = false
    }
}

let thermals: Thermals
do { thermals = try Thermals() } catch {
    log.fault("no SMC: \(String(describing: error), privacy: .public)")
    exit(1)
}
guard let team = FanHelper.signingTeam() else {
    log.fault("helper isn't signed by a team; refusing connections")
    exit(1)
}
let controller = Controller(thermals: thermals)
let requirement = FanHelper.requirement(identifier: FanHelper.appIdentifier, team: team)

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { MainActor.assumeIsolated { () -> Void in controller.terminate() } }
terminate.resume()

/// XPC objects are thread-safe; this carries them onto the main actor, where everything runs.
struct XPCObject: @unchecked Sendable { let object: xpc_object_t }

let listener = xpc_connection_create_mach_service(FanHelper.machService, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
    // Messages from anything else never arrive; the connection just errors.
    guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
        xpc_connection_cancel(peer)
        return
    }
    let connection = XPCObject(object: peer)
    xpc_connection_set_target_queue(peer, .main)
    xpc_connection_set_event_handler(peer) { message in
        let message = XPCObject(object: message)
        MainActor.assumeIsolated { controller.handle(message.object, from: connection.object) }
    }
    xpc_connection_activate(peer)
}
xpc_connection_activate(listener)
dispatchMain()
