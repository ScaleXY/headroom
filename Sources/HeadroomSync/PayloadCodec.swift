import Foundation

/// Payload bytes as stored in a record: one format byte, then LZFSE-compressed JSON.
public enum PayloadCodec {
    /// Format byte for LZFSE-compressed JSON.
    static let lzfseJSON: UInt8 = 1

    public enum Failure: Error, Equatable {
        case empty
        case unknownFormat(UInt8)
        case corrupt
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let json = try e.encode(value)
        let packed = try (json as NSData).compressed(using: .lzfse) as Data
        return Data([lzfseJSON]) + packed
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let format = data.first else { throw Failure.empty }
        guard format == lzfseJSON else { throw Failure.unknownFormat(format) }
        guard let json = try? (Data(data.dropFirst()) as NSData).decompressed(using: .lzfse) as Data else { throw Failure.corrupt }
        return try JSONDecoder().decode(T.self, from: json)
    }
}
