import Foundation
import SpeechRailDiarizationProtocol

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("self-test failed: \(message)\n".utf8))
        exit(1)
    }
}

do {
    let payload = Data([0x01, 0x00, 0x02, 0x00])
    let encoded = try DiarizationPacketCodec.encode(
        header: ["protocol_version": DiarizationPacketCodec.protocolVersion, "operation": "append"],
        payload: payload
    )
    let decoded = try DiarizationPacketCodec.decode(encoded)
    require(decoded.header["protocol_version"] as? Int == DiarizationPacketCodec.protocolVersion, "version")
    require(decoded.header["operation"] as? String == "append", "operation")
    require(decoded.payload == payload, "binary payload")

    var rejected = false
    do {
        _ = try DiarizationPacketCodec.decode(Data([0x00]))
    } catch {
        rejected = true
    }
    require(rejected, "truncated packet rejection")
} catch {
    FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
    exit(1)
}
