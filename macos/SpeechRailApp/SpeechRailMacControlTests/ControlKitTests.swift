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
        XCTAssertThrowsError(try ControlRequest(command: .modelPrepare).validate()) { error in
            XCTAssertEqual(error as? ControlProtocolError, .confirmationRequired)
        }
        XCTAssertThrowsError(
            try ControlRequest(command: .modelPrepare, confirmation: true).validate()
        ) { error in
            XCTAssertEqual(error as? ControlProtocolError, .profileRequired)
        }
    }

    func testModelPrepareRequestRoundTripsProgressAndCatalog() throws {
        let request = ControlRequest(
            command: .modelPrepare,
            profile: .quality,
            confirmation: true
        )
        let response = ControlResponse(
            requestID: request.requestID,
            command: .modelPrepare,
            status: .running,
            modelCatalog: ModelCatalogSnapshot(artifacts: [], profiles: []),
            operation: OperationSnapshot(
                operationID: "model_123",
                command: .modelPrepare,
                state: .running,
                phase: "download",
                progress: OperationProgressSnapshot(
                    artifactKey: "tts-1.7b-base-q8",
                    file: "model.safetensors",
                    completedBytes: 10,
                    expectedBytes: 20
                )
            )
        )

        let decoded = try ControlWireCodec.decode(
            ControlResponse.self,
            from: ControlWireCodec.encode(response)
        )

        XCTAssertEqual(decoded.command, .modelPrepare)
        XCTAssertEqual(decoded.operation?.progress?.completedBytes, 10)
        XCTAssertEqual(decoded.modelCatalog?.profiles, [])
    }

    func testRecoveryFieldsRoundTripWithoutChangingSchemaVersion() throws {
        let operation = OperationSnapshot(
            operationID: "model_recovery_123",
            command: .modelPrepare,
            profile: .quality,
            state: .interrupted,
            phase: "download",
            progress: OperationProgressSnapshot(
                artifactKey: "fake-asr",
                file: "weights.bin",
                completedBytes: 64,
                expectedBytes: 128
            ),
            message: "previous preparation was interrupted"
        )
        let modelStatus = ModelStatusSnapshot(
            artifacts: [],
            disk: ModelDiskSnapshot(modelBytes: 64, freeBytes: 1024),
            activeOperation: operation
        )

        let response = ControlResponse(
            requestID: UUID(),
            command: .modelStatus,
            status: .ok,
            modelStatus: modelStatus
        )
        let decoded = try ControlWireCodec.decode(
            ControlResponse.self,
            from: ControlWireCodec.encode(response)
        )

        XCTAssertEqual(decoded.schemaVersion, ControlConstants.schemaVersion)
        XCTAssertEqual(decoded.modelStatus?.activeOperation, operation)
        XCTAssertEqual(decoded.modelStatus?.activeOperation?.profile, .quality)
        XCTAssertEqual(decoded.modelStatus?.activeOperation?.state, .interrupted)
    }

    func testLegacyModelStatusWithoutActiveOperationDecodesAsNoRecovery() throws {
        let data = Data(
            #"{"artifacts":[],"diarization":[],"disk":{"model_bytes":0,"free_bytes":1024}}"#.utf8
        )

        let decoded = try ControlWireCodec.decode(ModelStatusSnapshot.self, from: data)

        XCTAssertNil(decoded.activeOperation)
    }

    func testRuntimeMonitoringChartDescriptorDescribesTimeAndActiveRequests() {
        let points = [
            RuntimeMonitoringChartPoint(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                activeRequests: 1
            ),
            RuntimeMonitoringChartPoint(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_005),
                activeRequests: 3
            ),
        ]

        let chart = RuntimeMonitoringChartDescriptor(points: points).makeChartDescriptor()

        XCTAssertEqual(chart.title, "最近运行监控趋势")
        XCTAssertTrue(chart.summary?.contains("活跃请求") == true)
        XCTAssertEqual(chart.xAxis.title, "时间")
        XCTAssertEqual(chart.yAxis?.title, "活跃请求")
        XCTAssertEqual(chart.series.count, 1)
        XCTAssertEqual(chart.series.first?.dataPoints.count, 2)
    }

    func testRuntimeMonitoringChartDescriptorRequiresTwoSamples() {
        XCTAssertFalse(
            RuntimeMonitoringChartDescriptor.isSufficient(
                [RuntimeMonitoringChartPoint(capturedAt: Date(), activeRequests: 1)]
            )
        )
        XCTAssertTrue(
            RuntimeMonitoringChartDescriptor.isSufficient([
                RuntimeMonitoringChartPoint(capturedAt: Date(), activeRequests: 1),
                RuntimeMonitoringChartPoint(capturedAt: Date().addingTimeInterval(5), activeRequests: 2),
            ])
        )
    }

    func testProfileSummaryAcceptsLegacyPayloadWithoutDiarization() throws {
        let data = Data(
            #"{"id":"balanced","asr":"asr","tts":"tts","aligner":null,"download_bytes":10}"#
                .utf8
        )

        let decoded = try ControlWireCodec.decode(ProfileSummary.self, from: data)

        XCTAssertEqual(decoded.id, .balanced)
        XCTAssertFalse(decoded.diarization)
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

    func testModelPrepareArgumentsUseTheLockedCommandAndRequireNoShell() {
        let home = URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        let arguments = ManagedCommand.modelPrepare(.quality).arguments(appHome: home)

        XCTAssertEqual(
            arguments,
            [
                "-m", "speechrail", "model", "prepare", "quality", "--yes", "--app-home",
                "/tmp/SpeechRail Test Home", "--json",
            ]
        )
        XCTAssertFalse(arguments.contains("--url"))
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
