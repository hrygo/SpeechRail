import Foundation
import SpeechRailControlAgentCore
import SpeechRailControlKit
import XCTest

final class ControlKitTests: XCTestCase {
    func testRequestAndResponseRoundTripUseSchemaVersionOne() throws {
        let request = ControlRequest(
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            command: .profileApply,
            profile: .balanced,
            confirmation: true
        )
        let response = ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: .accepted,
            operation: OperationSnapshot(
                operationID: "control_123",
                command: .profileApply,
                state: .accepted,
                phase: "accepted",
                message: "profile switch accepted"
            )
        )

        let decodedRequest = try ControlWireCodec.decode(
            ControlRequest.self,
            from: ControlWireCodec.encode(request)
        )
        let decodedResponse = try ControlWireCodec.decode(
            ControlResponse.self,
            from: ControlWireCodec.encode(response)
        )

        XCTAssertEqual(decodedRequest, request)
        XCTAssertEqual(decodedResponse, response)
        XCTAssertEqual(decodedRequest.schemaVersion, 1)
        XCTAssertEqual(decodedResponse.operation?.message, "profile switch accepted")
    }

    func testEveryProfileIsRepresentedByTheStableEnum() {
        XCTAssertEqual(SpeechRailProfile.allCases, [.quality, .balanced, .light])
    }

    func testRequestValidationRejectsMissingConfirmationAndPayload() {
        XCTAssertThrowsError(try ControlRequest(command: .profileApply).validate()) { error in
            XCTAssertEqual(error as? ControlProtocolError, .confirmationRequired)
        }
        XCTAssertThrowsError(
            try ControlRequest(command: .profileApply, confirmation: true).validate()
        ) { error in
            XCTAssertEqual(error as? ControlProtocolError, .profileRequired)
        }
        XCTAssertThrowsError(try ControlRequest(command: .operationStatus).validate()) { error in
            XCTAssertEqual(error as? ControlProtocolError, .operationRequired)
        }
    }

    func testProfileApplyArgumentsAreFixedAndPreserveHomeAsOneArgument() {
        let home = URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        let arguments = ManagedCommand.profileApply(.quality).arguments(appHome: home)

        XCTAssertEqual(
            arguments,
            [
                "-m", "speechrail", "profile", "apply", "quality", "--yes", "--app-home",
                "/tmp/SpeechRail Test Home", "--json",
            ]
        )
        XCTAssertFalse(arguments.joined(separator: " ").contains("sh -c"))
    }

    func testUnavailableXPCServiceTimesOutInsteadOfHanging() async {
        let transport = NSXPCControlTransport(
            machServiceName: "com.speechrail.test.unavailable.\(UUID().uuidString)",
            requestTimeout: 0.1
        )
        let startedAt = Date()

        do {
            _ = try await transport.send(ControlRequest(command: .profileStatus))
            XCTFail("unavailable XPC service should time out")
        } catch let error as XPCControlTransportError {
            switch error {
            case .remote, .timeout:
                break
            default:
                XCTFail("unavailable XPC service returned an unrelated error: \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
