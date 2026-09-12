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

    func testPeerPolicyFailsClosedForMissingTeamIdentifier() {
        let policy = XPCPeerPolicy(teamIdentifier: "", appIdentifier: "com.speechrail.desktop")
        XCTAssertFalse(policy.isConfigured)
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
