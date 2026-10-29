import Foundation
import IOKit

/// A connection to the System Management Controller, which owns the fans and temperature sensors.
/// Anyone can read it; writing (fan speeds) needs root, which is why fan control runs in the helper.
/// Not thread-safe: use one per thread or queue.
public final class SMC {
    /// A four-character SMC key such as `F0Ac` (fan 0, actual speed) as the 32-bit code the SMC uses.
    public struct Key: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringInterpolation {
        public let code: UInt32

        public init(_ name: String) {
            code = name.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        }

        public init(stringLiteral name: String) { self.init(name) }
        public init(stringInterpolation: DefaultStringInterpolation) { self.init(String(stringInterpolation: stringInterpolation)) }
        public init(code: UInt32) { self.code = code }

        public var description: String {
            String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
        }
    }

    /// A key's size and data type (`flt `, `ui8 `, ...).
    public struct KeyInfo: Sendable {
        public let size: Int
        public let type: Key
    }

    public enum Failure: Error, Equatable {
        case unavailable
        case call(kern_return_t)
        /// The SMC's own result code: 0x84 = key not found, 0x85/0x86 = not allowed.
        case result(UInt8)
        case badSize
    }

    private var connection: io_connect_t = 0
    private var infos: [Key: KeyInfo] = [:]

    public init() throws(Failure) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw .unavailable }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard r == kIOReturnSuccess else { throw .call(r) }
    }

    deinit { IOServiceClose(connection) }

    public func info(_ key: Key) throws(Failure) -> KeyInfo {
        if let known = infos[key] { return known }
        var input = Param()
        input.key = key.code
        input.command = Command.info
        let out = try call(&input)
        let info = KeyInfo(size: Int(out.info.size), type: Key(code: out.info.type))
        infos[key] = info
        return info
    }

    public func read(_ key: Key) throws(Failure) -> [UInt8] {
        let info = try info(key)
        guard info.size <= 32 else { throw .badSize }
        var input = Param()
        input.key = key.code
        input.info.size = UInt32(info.size)
        input.command = Command.read
        let out = try call(&input)
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(info.size)) }
    }

    public func write(_ key: Key, _ bytes: [UInt8]) throws(Failure) {
        let info = try info(key)
        guard bytes.count == info.size, bytes.count <= 32 else { throw .badSize }
        var input = Param()
        input.key = key.code
        input.info.size = UInt32(info.size)
        input.command = Command.write
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: bytes) }
        _ = try call(&input)
    }

    public func has(_ key: Key) -> Bool { (try? info(key)) != nil }

    /// Every key the SMC knows, in its own order.
    public func allKeys() throws(Failure) -> [Key] {
        let count = try Self.uint(read("#KEY"))
        return (0..<count).compactMap { index -> Key? in
            var input = Param()
            input.command = Command.keyAtIndex
            input.data32 = UInt32(index)
            return (try? call(&input)).map { Key(code: $0.key) }
        }
    }

    // MARK: Values

    /// Reads a number, whatever its type; nil for types this doesn't decode.
    public func number(_ key: Key) throws(Failure) -> Double? {
        let type = try info(key).type
        return Self.decode(try read(key), type: type)
    }

    /// Writes a number in the key's own type.
    public func setNumber(_ key: Key, _ value: Double) throws(Failure) {
        let type = try info(key).type
        guard let bytes = Self.encode(value, type: type, size: try info(key).size) else { throw .badSize }
        try write(key, bytes)
    }

    static func decode(_ bytes: [UInt8], type: Key) -> Double? {
        switch type.description {
        case "flt " where bytes.count == 4:
            return Double(Float(bitPattern: UInt32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })))
        case "ui8 ", "ui16", "ui32":
            return Double(uint(bytes))
        case "fpe2" where bytes.count == 2:
            return Double(uint(bytes)) / 4
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(uint(bytes)))) / 256
        default:
            return nil
        }
    }

    static func encode(_ value: Double, type: Key, size: Int) -> [UInt8]? {
        switch type.description {
        case "flt " where size == 4:
            return withUnsafeBytes(of: Float(value).bitPattern.littleEndian, Array.init)
        case "ui8 ", "ui16", "ui32":
            let v = UInt64(max(0, value.rounded()))
            return (0..<size).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
        case "fpe2" where size == 2:
            let v = UInt16(clamping: Int(max(0, value * 4).rounded()))
            return [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            return nil
        }
    }

    /// Unsigned integers are big-endian.
    static func uint(_ bytes: [UInt8]) -> Int { bytes.reduce(0) { $0 << 8 | Int($1) } }

    // MARK: Kernel interface

    private enum Command {
        static let read: UInt8 = 5
        static let write: UInt8 = 6
        static let keyAtIndex: UInt8 = 8
        static let info: UInt8 = 9
    }

    /// `SMCKeyData_t` from AppleSMC, padded by hand to its C layout (80 bytes).
    private struct Param {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct Info { var size: UInt32 = 0, type: UInt32 = 0; var attributes: UInt8 = 0; var padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var info = Info()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private func call(_ input: inout Param) throws(Failure) -> Param {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        guard r == kIOReturnSuccess else { throw .call(r) }
        guard output.result == 0 else { throw .result(output.result) }
        return output
    }
}
