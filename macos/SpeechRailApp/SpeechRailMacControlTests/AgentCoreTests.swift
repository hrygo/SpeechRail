import Foundation
import SpeechRailControlAgentCore
import SpeechRailControlKit
import XCTest

private actor BlockingRunner: ManagedCommandRunner {
    private var continuation: CheckedContinuation<ManagedCommandResult, Never>?

    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() {
        continuation?.resume(
            returning: ManagedCommandResult(
                exitCode: 0,
                response: ControlResponse(
                    requestID: UUID(),
                    command: .profileApply,
                    status: .committed
                )
            )
        )
        continuation = nil
    }
}

private struct RuntimeMissingRunner: ManagedCommandRunner {
    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        throw ManagedCommandError.runtimeMissing
    }
}

private struct FailureEnvelopeRunner: ManagedCommandRunner {
    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        ManagedCommandResult(
            exitCode: 1,
            response: ControlResponse(
                requestID: UUID(),
                command: command.controlCommand,
                status: .failed,
                errorCode: .commandFailed,
                message: "profile preparation failed"
            ),
            message: "managed command failed"
        )
    }
}

final class AgentCoreTests: XCTestCase {
    func testManagedRuntimeLocatorUsesOnlyTheCurrentVenvPython() {
        let locator = ManagedRuntimeLocator(
            appHome: URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        )
        XCTAssertEqual(
            locator.pythonExecutable.path,
            "/tmp/SpeechRail Test Home/runtime/current/.venv/bin/python"
        )
    }

    func testMissingRuntimeIsReportedWithoutRunningAProcess() async {
        let store = AgentOperationStore(runner: RuntimeMissingRunner())
        let request = ControlRequest(command: .status)

        let response = await store.handle(request)

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, .managedRuntimeMissing)
    }

    func testMutationsAreSerializedWhileProfileApplyIsRunning() async {
        let runner = BlockingRunner()
        let store = AgentOperationStore(runner: runner)
        let apply = ControlRequest(
            command: .profileApply,
            profile: .light,
            confirmation: true
        )

        let accepted = await store.handle(apply)
        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertNotNil(accepted.operation?.operationID)

        let start = ControlRequest(command: .start, confirmation: true)
        let rejected = await store.handle(start)
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertEqual(rejected.errorCode, .operationInProgress)

        await runner.complete()
    }

    func testProfileApplyFailurePreservesMessageInOperationStatus() async throws {
        let store = AgentOperationStore(runner: FailureEnvelopeRunner())
        let apply = ControlRequest(
            command: .profileApply,
            profile: .balanced,
            confirmation: true
        )

        let accepted = await store.handle(apply)
        guard let operationID = accepted.operation?.operationID else {
            XCTFail("profile apply did not return an operation ID")
            return
        }

        var status: ControlResponse?
        for _ in 0..<20 {
            let response = await store.handle(
                ControlRequest(command: .operationStatus, operationID: operationID)
            )
            status = response
            if response.status == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(status?.status, .failed)
        XCTAssertEqual(status?.errorCode, .commandFailed)
        XCTAssertEqual(status?.message, "profile preparation failed")
        XCTAssertEqual(status?.operation?.message, "profile preparation failed")
    }

    func testProcessRunnerPreservesFailureEnvelopeForNonZeroExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root
            .appendingPathComponent("runtime/current/.venv/bin", isDirectory: true)
            .appendingPathComponent("python")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            "#!/bin/sh\nprintf '%s' '{\"schema_version\":1,\"command\":\"profile.apply\",\"status\":\"failed\",\"error_code\":\"command_failed\",\"message\":\"profile preparation failed\"}'\nexit 1\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let result = try await ProcessManagedCommandRunner(
            locator: ManagedRuntimeLocator(appHome: root)
        ).run(.profileApply(.quality))

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.response?.status, .failed)
        XCTAssertEqual(result.response?.errorCode, .commandFailed)
        XCTAssertEqual(result.response?.message, "profile preparation failed")
        XCTAssertEqual(result.message, "profile preparation failed")
    }

    func testProcessRunnerRedactsStderrWhenMachineOutputIsInvalid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root
            .appendingPathComponent("runtime/current/.venv/bin", isDirectory: true)
            .appendingPathComponent("python")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            "#!/bin/sh\nprintf '%s' 'not json'\nprintf '%s\\n' 'failed at /Users/hrygo/private/models api_key=super-secret' >&2\nexit 1\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let result = try await ProcessManagedCommandRunner(
            locator: ManagedRuntimeLocator(appHome: root)
        ).run(.profileApply(.quality))

        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(message.contains("failed at"))
        XCTAssertTrue(message.contains("[path]"))
        XCTAssertTrue(message.contains("api_key=[redacted]"))
        XCTAssertFalse(message.contains("/Users/hrygo/private/models"))
        XCTAssertFalse(message.contains("super-secret"))
    }

    func testPeerPolicyFailsClosedForMissingTeamIdentifier() {
        let policy = XPCPeerPolicy(teamIdentifier: "", appIdentifier: "com.speechrail.desktop")
        XCTAssertFalse(policy.isConfigured)
    }

    func testDevelopmentPeerPolicyPinsOnlyTheLocalBundleIdentifier() {
        let policy = XPCPeerPolicy(developmentAppIdentifier: "com.speechrail.desktop")
        XCTAssertTrue(policy.isConfigured)
        XCTAssertEqual(policy.requirement, "identifier \"com.speechrail.desktop\"")
    }

    func testPeerPolicyRejectsRequirementInjectionCharacters() {
        XCTAssertFalse(
            XPCPeerPolicy(
                teamIdentifier: "TEAM\" or anchor apple generic",
                appIdentifier: "com.speechrail.desktop"
            ).isConfigured
        )
        XCTAssertFalse(
            XPCPeerPolicy(
                developmentAppIdentifier: "com.speechrail.desktop\" or anchor apple generic"
            ).isConfigured
        )
    }

    func testPeerPolicyPinsTeamAndBundleIdentifier() {
        let policy = XPCPeerPolicy(
            teamIdentifier: "TEAM123",
            appIdentifier: "com.speechrail.desktop"
        )
        XCTAssertEqual(
            policy.requirement,
            "anchor apple generic and certificate leaf[subject.OU] = \"TEAM123\" and identifier \"com.speechrail.desktop\""
        )
    }
}
