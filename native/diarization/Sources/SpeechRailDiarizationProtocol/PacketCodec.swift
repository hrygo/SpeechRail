import Foundation
import CoreFoundation

public enum PacketCodecError: Error, Equatable {
    case invalidPacket
    case packetTooLarge
}

public enum DiarizationPacketCodec {
    public static let protocolVersion = 1
    public static let maxHeaderBytes = 64 * 1024
    public static let maxPayloadBytes = 4 * 1024 * 1024

    public static func nonnegativeInteger(_ value: Any?, maximum: Int = 9_007_199_254_740_991) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.doubleValue >= 0, number.doubleValue <= Double(maximum) else {
            throw PacketCodecError.invalidPacket
        }
        return number.intValue
    }

    public static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw PacketCodecError.invalidPacket
        }
        return number.boolValue
    }

    public static func encode(header: [String: Any], payload: Data = Data()) throws -> Data {
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        guard headerData.count <= maxHeaderBytes, payload.count <= maxPayloadBytes else {
            throw PacketCodecError.packetTooLarge
        }
        var headerSize = UInt32(headerData.count).bigEndian
        var payloadSize = UInt32(payload.count).bigEndian
        var packet = Data()
        withUnsafeBytes(of: &headerSize) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadSize) { packet.append(contentsOf: $0) }
        packet.append(headerData)
        packet.append(payload)
        return packet
    }

    public static func sizes(prefix: Data) throws -> (header: Int, payload: Int) {
        guard prefix.count == 8 else { throw PacketCodecError.invalidPacket }
        let values = prefix.withUnsafeBytes { raw in
            (
                Int(UInt32(bigEndian: raw.load(fromByteOffset: 0, as: UInt32.self))),
                Int(UInt32(bigEndian: raw.load(fromByteOffset: 4, as: UInt32.self)) )
            )
        }
        guard values.0 <= maxHeaderBytes, values.1 <= maxPayloadBytes else {
            throw PacketCodecError.packetTooLarge
        }
        return (values.0, values.1)
    }

    public static func decode(_ packet: Data) throws -> (header: [String: Any], payload: Data) {
        guard packet.count >= 8 else { throw PacketCodecError.invalidPacket }
        let prefix = packet.prefix(8)
        let sizes = try sizes(prefix: Data(prefix))
        guard packet.count == 8 + sizes.header + sizes.payload else {
            throw PacketCodecError.invalidPacket
        }
        let headerStart = 8
        let headerEnd = headerStart + sizes.header
        let headerData = packet[headerStart..<headerEnd]
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw PacketCodecError.invalidPacket
        }
        return (header, Data(packet[headerEnd...]))
    }
}
