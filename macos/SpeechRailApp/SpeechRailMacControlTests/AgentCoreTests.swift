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

private struct ModelStatusRunner: ManagedCommandRunner {
    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        ManagedCommandResult(
            exitCode: 0,
            response: ControlResponse(
                requestID: UUID(),
                command: command.controlCommand,
                status: .ok,
                modelStatus: ModelStatusSnapshot(
                    artifacts: [],
                    disk: ModelDiskSnapshot(modelBytes: 0, freeBytes: 1024)
                )
            )
        )
    }
}

private actor BlockingModelPreparationRunner: ManagedCommandRunner {
    private var continuation: CheckedContinuation<ManagedCommandResult, Never>?

    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        if case .modelPrepare = command {
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return try await ModelStatusRunner().run(command)
    }

    func complete() {
        continuation?.resume(
            returning: ManagedCommandResult(
                exitCode: 0,
                response: ControlResponse(
                    requestID: UUID(),
                    command: .modelPrepare,
                    status: .committed
                )
            )
        )
        continuation = nil
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [OperationProgressSnapshot] = []

    func append(_ snapshot: OperationProgressSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    var first: OperationProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.first
    }
}

final class AgentCoreTests: XCTestCase {
    func testOperationJournalPersistsRedactedMetadataAndUpdatedAt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-journal-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OperationJournal(
            fileURL: root.appendingPathComponent("control/active-operation.json")
        )
        let operation = OperationSnapshot(
            operationID: "control_safe_123",
            command: .modelPrepare,
            profile: .balanced,
            state: .running,
            phase: "download",
            progress: OperationProgressSnapshot(
                artifactKey: "fake-asr",
                file: "/Users/private/models/weights.bin",
                completedBytes: 32,
                expectedBytes: 64
            ),
            message: "failed at /Users/private/models token=super-secret"
        )
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try journal.save(operation, updatedAt: updatedAt)

        let raw = try String(contentsOf: journal.fileURL, encoding: .utf8)
        let loaded = try XCTUnwrap(journal.load())
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)

        XCTAssertTrue(raw.contains("updated_at"))
        XCTAssertFalse(raw.contains("/Users/private/models"))
        XCTAssertFalse(raw.contains("super-secret"))
        XCTAssertEqual(loaded.updatedAt, updatedAt)
        XCTAssertFalse(loaded.operation.progress?.file?.contains("/") ?? false)
        XCTAssertFalse(loaded.operation.message?.contains("super-secret") ?? false)

        try journal.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testAgentStartupMarksActiveJournalAsInterruptedAndExposesItInModelStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-recovery-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OperationJournal(appHome: root)
        let operation = OperationSnapshot(
            operationID: "control_recover_123",
            command: .modelPrepare,
            profile: .quality,
            state: .running,
            phase: "download",
            progress: OperationProgressSnapshot(
                artifactKey: "fake-asr",
                completedBytes: 16,
                expectedBytes: 64
            )
        )
        try journal.save(operation)

        let store = AgentOperationStore(runner: ModelStatusRunner(), journal: journal)
        let status = await store.handle(ControlRequest(command: .modelStatus))
        let recovered = try XCTUnwrap(status.modelStatus?.activeOperation)

        XCTAssertEqual(recovered.operationID, operation.operationID)
        XCTAssertEqual(recovered.profile, .quality)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.progress?.completedBytes, 16)
        let operationStatus = await store.handle(
            ControlRequest(command: .operationStatus, operationID: operation.operationID)
        )
        XCTAssertEqual(
            operationStatus.operation?.state,
            .interrupted
        )
        let serviceStatus = await store.handle(ControlRequest(command: .status))
        XCTAssertEqual(
            serviceStatus.errorCode,
            nil
        )
    }

    func testModelStatusPrefersNewPreparationOverAnInterruptedRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OperationJournal(appHome: root)
        try journal.save(
            OperationSnapshot(
                operationID: "control_old_123",
                command: .modelPrepare,
                profile: .quality,
                state: .interrupted,
                phase: "download"
            )
        )
        let runner = BlockingModelPreparationRunner()
        let store = AgentOperationStore(runner: runner, journal: journal)
        let request = ControlRequest(
            command: .modelPrepare,
            profile: .light,
            confirmation: true
        )

        let accepted = await store.handle(request)
        let status = await store.handle(ControlRequest(command: .modelStatus))

        XCTAssertEqual(status.modelStatus?.activeOperation?.operationID, accepted.operation?.operationID)
        XCTAssertEqual(status.modelStatus?.activeOperation?.profile, .light)

        await runner.complete()
    }

    func testTerminalOperationClearsActiveJournal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-terminal-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OperationJournal(appHome: root)
        let store = AgentOperationStore(runner: ModelStatusRunner(), journal: journal)
        let request = ControlRequest(
            command: .modelPrepare,
            profile: .light,
            confirmation: true
        )

        let accepted = await store.handle(request)
        let operationID = try XCTUnwrap(accepted.operation?.operationID)

        for _ in 0..<20 {
            if !FileManager.default.fileExists(atPath: journal.fileURL.path) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        let operation = await store.handle(
            ControlRequest(command: .operationStatus, operationID: operationID)
        ).operation
        XCTAssertEqual(operation?.state, .committed)
    }

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

    func testProcessRunnerForwardsModelPreparationProgress() async throws {
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
            """
            #!/bin/sh
            printf '%s\\n' '{"schema_version":1,"event":"progress","command":"model.prepare","phase":"download","artifact":"fake-asr","file":"fixture.bin","bytes":64,"expected_bytes":128}'
            printf '%s\\n' '{"schema_version":1,"event":"result","command":"model.prepare","status":"committed","prepared_id":"prepared_fixture"}'
            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let recorder = ProgressRecorder()
        let result = try await ProcessManagedCommandRunner(
            locator: ManagedRuntimeLocator(appHome: root)
        ).run(.modelPrepare(.quality)) { snapshot in
            recorder.append(snapshot)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.response?.status, .committed)
        XCTAssertEqual(recorder.first?.phase, "download")
        XCTAssertEqual(recorder.first?.completedBytes, 64)
        XCTAssertEqual(recorder.first?.expectedBytes, 128)
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
