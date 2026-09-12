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
                phase: "accepted"
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
                "profile", "apply", "quality", "--yes", "--app-home",
                "/tmp/SpeechRail Test Home", "--json",
            ]
        )
        XCTAssertFalse(arguments.joined(separator: " ").contains("sh -c"))
    }
}
