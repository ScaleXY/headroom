import Foundation

/// A fan's speed range, in rpm.
public struct FanRange: Equatable, Sendable {
    public var min: Double
    public var max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

/// The fan curve: lowest speed at `minTemp`, full speed at `maxTemp`, a straight line between.
/// Below `minTemp` the fans are macOS's again.
public struct FanCurve: Equatable, Sendable {
    public var minTemp: Double
    public var maxTemp: Double

    public init(minTemp: Double, maxTemp: Double) {
        self.minTemp = minTemp
        self.maxTemp = maxTemp
    }

    public var isValid: Bool { minTemp.isFinite && maxTemp.isFinite && minTemp < maxTemp }

    /// How far along the fan's range to run at this temperature, 0...1.
    public func level(at temperature: Double) -> Double {
        guard isValid else { return 1 }
        return Swift.min(1, Swift.max(0, (temperature - minTemp) / (maxTemp - minTemp)))
    }
}

/// Turns temperature readings into fan levels, one tick at a time. Pure, so it can be tested.
///
/// It takes the fans from macOS once the sensor reaches the min temperature and gives
/// them back a little below it, so they don't flap at the threshold. Speeds go up at once and
/// come down gently: chip sensors swing by tens of degrees in a second under bursty load.
public struct FanGovernor: Sendable {
    public var curve: FanCurve
    /// Degrees below the min temperature before the fans go back to macOS.
    public var releaseMargin: Double = 3
    /// The most the level may drop per tick.
    public var maxFallPerTick: Double = 0.04
    /// The level last asked for; nil while macOS has the fans.
    public private(set) var level: Double?

    public init(curve: FanCurve) { self.curve = curve }

    /// The level to run at for this reading; nil = leave the fans to macOS.
    public mutating func tick(temperature: Double?) -> Double? {
        // No reading: don't guess, run flat out until one comes back.
        guard let temperature else { level = 1; return level }
        if level == nil, temperature < curve.minTemp { return nil }
        if let level, level <= 0, temperature < curve.minTemp - releaseMargin {
            self.level = nil
            return nil
        }
        let want = curve.level(at: temperature)
        level = Swift.max(want, (level ?? want) - maxFallPerTick)
        return level
    }
}

/// What the fan curve follows. Die sensor names vary by chip; their prefixes don't:
/// `Tp` performance cores, `Te` efficiency cores, `Tg` GPU.
public enum FanSensor: String, CaseIterable, Sendable {
    /// Every CPU and GPU die sensor, averaged: tracks the whole chip and moves smoothly.
    case chipAverage
    case cpuAverage
    case gpuAverage
    /// The single hottest die sensor: reacts fastest, but jumps with every burst of load.
    case hottest

    public static let `default` = FanSensor.chipAverage

    public var title: String {
        switch self {
        case .chipAverage: "CPU & GPU average"
        case .cpuAverage: "CPU average"
        case .gpuAverage: "GPU average"
        case .hottest: "Hottest core"
        }
    }

    public var help: String {
        switch self {
        case .chipAverage: "The average of every CPU and GPU core. Follows the whole chip and changes smoothly."
        case .cpuAverage: "The average of the CPU cores. Suits builds, tests and agents running tools."
        case .gpuAverage: "The average of the GPU cores. Suits local models."
        case .hottest: "The single hottest core. Reacts fastest, but jumps around with bursts of load."
        }
    }

    static let cpuPrefixes = ["Tp", "Te"]
    static let gpuPrefixes = ["Tg"]
    static let allPrefixes = cpuPrefixes + gpuPrefixes

    func includes(_ key: SMC.Key) -> Bool {
        let prefixes = switch self {
        case .cpuAverage: Self.cpuPrefixes
        case .gpuAverage: Self.gpuPrefixes
        case .chipAverage, .hottest: Self.allPrefixes
        }
        return prefixes.contains { key.description.hasPrefix($0) }
    }

    /// Combines raw readings into this sensor's temperature, in °C.
    public func temperature(_ readings: [SMC.Key: Double]) -> Double? {
        // Unused sensors read 0; a few report garbage.
        let values = readings.filter { includes($0.key) && $0.value > 5 && $0.value < 130 }.map(\.value)
        guard !values.isEmpty else { return nil }
        return self == .hottest ? values.max() : values.reduce(0, +) / Double(values.count)
    }
}

/// The fans and chip temperatures on this Mac.
public final class Thermals {
    let smc: SMC
    /// Every CPU and GPU die sensor, found once.
    private var sensors: [SMC.Key]?

    public init(smc: SMC) { self.smc = smc }
    public convenience init() throws(SMC.Failure) { self.init(smc: try SMC()) }

    public var fanCount: Int { (try? smc.number("FNum")).flatMap { $0 }.map { Int($0) } ?? 0 }

    public func range(fan: Int) -> FanRange? {
        guard let min = number("F\(fan)Mn"), let max = number("F\(fan)Mx"), max > min else { return nil }
        return FanRange(min: min, max: max)
    }

    /// Current speed in rpm.
    public func speed(fan: Int) -> Double? { number("F\(fan)Ac") }

    public func temperature(_ sensor: FanSensor) -> Double? {
        if sensors == nil {
            sensors = ((try? smc.allKeys()) ?? []).filter { key in
                FanSensor.allPrefixes.contains { key.description.hasPrefix($0) }
                    && (try? smc.info(key))?.type.description == "flt "
            }
        }
        var readings: [SMC.Key: Double] = [:]
        for key in sensors ?? [] where sensor.includes(key) { readings[key] = number(key) }
        return sensor.temperature(readings)
    }

    private func number(_ key: SMC.Key) -> Double? { (try? smc.number(key)) ?? nil }
}

// MARK: Control (root only)

extension Thermals {
    /// Runs a fan at `level` (0...1) of its range, taking it from macOS if needed.
    public func run(fan: Int, level: Double) throws(SMC.Failure) {
        guard let range = range(fan: fan) else { throw .badSize }
        if number("F\(fan)Md") != 1 {
            // Apple Silicon before M4 hides manual mode behind the fan test flag, and thermalmonitord
            // takes a few seconds to let go once it's set: until then the mode write fails with 0x82.
            let unlocking = smc.has("Ftst")
            if unlocking, number("Ftst") != 1 { try smc.setNumber("Ftst", 1) }
            try Self.retrying(for: unlocking ? Self.unlockTimeout : 0) { () throws(SMC.Failure) in
                try smc.setNumber("F\(fan)Md", 1)
            }
        }
        try smc.setNumber("F\(fan)Tg", range.min + (range.max - range.min) * Swift.min(1, Swift.max(0, level)))
    }

    /// How long to keep asking for manual mode after setting `Ftst`.
    static let unlockTimeout: TimeInterval = 6

    /// Runs `body`, retrying while the SMC answers 0x82 (busy: macOS still has the fans) until
    /// `timeout` has passed. Any other failure, or 0x82 past the deadline, is thrown.
    static func retrying(
        for timeout: TimeInterval,
        every interval: TimeInterval = 0.1,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        _ body: () throws(SMC.Failure) -> Void
    ) throws(SMC.Failure) {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            do {
                try body()
                return
            } catch {
                guard error == .result(0x82), now() < deadline else { throw error }
                sleep(interval)
            }
        }
    }

    /// Hands every fan back to macOS.
    public func release() {
        for fan in 0..<fanCount { try? smc.setNumber("F\(fan)Md", 0) }
        if smc.has("Ftst") { try? smc.setNumber("Ftst", 0) }
    }
}
