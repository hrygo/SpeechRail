import Foundation
import SpeechRailControlKit

public actor AgentOperationStore {
    private let runner: any ManagedCommandRunner
    private let journal: OperationJournal?
    private var activeMutation: String?
    private var operations: [String: OperationSnapshot] = [:]
    private var journalWarning: String?

    public init(
        runner: any ManagedCommandRunner,
        journal: OperationJournal? = nil
    ) {
        self.runner = runner
        self.journal = journal
        if let journal {
            do {
                if let entry = try journal.load(), entry.operation.command == .modelPrepare {
                    switch entry.operation.state {
                    case .accepted, .running:
                        let interrupted = OperationSnapshot(
                            operationID: entry.operation.operationID,
                            command: entry.operation.command,
                            profile: entry.operation.profile,
                            state: .interrupted,
                            phase: entry.operation.phase ?? "interrupted",
                            progress: entry.operation.progress,
                            errorCode: entry.operation.errorCode,
                            message: "previous model preparation was interrupted; retry is required"
                        )
                        operations[interrupted.operationID] = interrupted
                        try journal.save(interrupted)
                    case .interrupted:
                        operations[entry.operation.operationID] = entry.operation
                    case .committed, .failed, .cancelled:
                        try journal.clear()
                    }
                }
            } catch {
                journalWarning = "previous model preparation state could not be recovered"
                try? journal.clear()
            }
        }
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            try request.validate()
        } catch let error as ControlProtocolError {
            return .failure(for: request, code: error.errorCode, message: "invalid control request")
        } catch {
            return .failure(for: request, code: .invalidRequest, message: "invalid control request")
        }

        switch request.command {
        case .operationStatus:
            return operationStatus(for: request)
        case .operationCancel:
            return cancelOperation(for: request)
        case .profileApply:
            guard let profile = request.profile else {
                return .failure(for: request, code: .invalidRequest, message: "profile is required")
            }
            return await acceptMutation(request, command: .profileApply(profile))
        case .modelPrepare:
            guard let profile = request.profile else {
                return .failure(for: request, code: .invalidRequest, message: "profile is required")
            }
            return await acceptMutation(request, command: .modelPrepare(profile))
        case .status:
            return await execute(request, command: .service(.status))
        case .start:
            return await execute(request, command: .service(.start))
        case .stop:
            return await execute(request, command: .service(.stop))
        case .restart:
            return await execute(request, command: .service(.restart))
        case .preflight:
            return await execute(request, command: .service(.preflight))
        case .profileList:
            return await execute(request, command: .profileList)
        case .profileStatus:
            return await execute(request, command: .profileStatus)
        case .profileRollback:
            return await execute(request, command: .profileRollback)
        case .modelCatalog:
            return await execute(request, command: .modelCatalog)
        case .modelStatus:
            return await execute(request, command: .modelStatus)
        }
    }

    private func execute(_ request: ControlRequest, command: ManagedCommand) async -> ControlResponse {
        if request.command.isMutation {
            guard activeMutation == nil else {
                return .failure(
                    for: request,
                    code: .operationInProgress,
                    message: "another control operation is in progress"
                )
            }
            activeMutation = request.requestID.uuidString
        }
        defer {
            if request.command.isMutation {
                activeMutation = nil
            }
        }

        do {
            let result = try await runner.run(command)
            if let response = result.response {
                let rebound = response.rebound(to: request)
                return request.command == .modelStatus
                    ? modelStatusResponse(from: rebound)
                    : rebound
            }
            let code: ControlErrorCode = result.exitCode == 0 ? .commandFailed : .serviceUnavailable
            return .failure(for: request, code: code, message: result.message ?? "managed command failed")
        } catch let error as ManagedCommandError {
            return .failure(
                for: request,
                code: Self.errorCode(for: error),
                message: Self.message(for: error)
            )
        } catch {
            return .failure(for: request, code: .commandFailed, message: "managed command failed")
        }
    }

    private func acceptMutation(
        _ request: ControlRequest,
        command: ManagedCommand
    ) async -> ControlResponse {
        guard activeMutation == nil else {
            return .failure(
                for: request,
                code: .operationInProgress,
                message: "another control operation is in progress"
            )
        }

        let operationID = "control_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let accepted = OperationSnapshot(
            operationID: operationID,
            command: request.command,
            profile: Self.profile(for: command),
            state: .accepted,
            phase: "accepted"
        )
        operations[operationID] = accepted
        activeMutation = operationID
        persist(accepted)
        let runner = self.runner
        let store = self
        Task {
            do {
                let result: ManagedCommandResult
                if let progressRunner = runner as? any ProgressAwareManagedCommandRunner {
                    result = try await progressRunner.run(command) { progress in
                        Task {
                            await store.updateProgress(
                                operationID: operationID,
                                progress: progress
                            )
                        }
                    }
                } else {
                    result = try await runner.run(command)
                }
                await store.finish(
                    operationID: operationID,
                    command: request.command,
                    result: result
                )
            } catch let error as ManagedCommandError {
                await store.finish(
                    operationID: operationID,
                    command: request.command,
                    result: ManagedCommandResult(
                        exitCode: -1,
                        response: ControlResponse(
                            requestID: request.requestID,
                            command: request.command,
                            status: .failed,
                            errorCode: Self.errorCode(for: error),
                            message: Self.message(for: error)
                        )
                    )
                )
            } catch {
                await store.finish(
                    operationID: operationID,
                    command: request.command,
                    result: ManagedCommandResult(
                        exitCode: -1,
                        response: ControlResponse(
                            requestID: request.requestID,
                            command: request.command,
                            status: .failed,
                            errorCode: .commandFailed,
                            message: "managed command failed"
                        )
                    )
                )
            }
        }

        return ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: .accepted,
            operation: accepted
        )
    }

    private func updateProgress(
        operationID: String,
        progress: OperationProgressSnapshot
    ) {
        guard let current = operations[operationID] else { return }
        let updated = OperationSnapshot(
            operationID: current.operationID,
            command: current.command,
            profile: current.profile,
            state: .running,
            phase: progress.phase ?? current.phase ?? "download",
            progress: progress,
            errorCode: current.errorCode,
            message: current.message
        )
        operations[operationID] = updated
        persist(updated)
    }

    private func finish(
        operationID: String,
        command: ControlCommand,
        result: ManagedCommandResult
    ) {
        let response = result.response
        if operations[operationID]?.state == .cancelled {
            return
        }
        let succeeded = result.exitCode == 0 && response?.status != .failed
        let message = succeeded
            ? nil
            : (response?.message ?? result.message ?? "managed command failed")
        let phase = succeeded
            ? "committed"
            : (response?.operation?.phase ?? response?.status.rawValue ?? "failed")
        let snapshot = OperationSnapshot(
            operationID: operationID,
            command: command,
            profile: operations[operationID]?.profile,
            state: succeeded ? .committed : .failed,
            phase: phase,
            progress: response?.operation?.progress ?? operations[operationID]?.progress,
            errorCode: succeeded ? nil : (response?.errorCode ?? .commandFailed),
            message: message
        )
        operations[operationID] = snapshot
        persist(snapshot)
        clearJournalIfTerminal(snapshot)
        if activeMutation == operationID {
            activeMutation = nil
        }
    }

    private func operationStatus(for request: ControlRequest) -> ControlResponse {
        guard let operationID = request.operationID, let operation = operations[operationID] else {
            return .failure(for: request, code: .invalidRequest, message: "operation is not available")
        }
        let status: ControlResponseStatus = switch operation.state {
        case .accepted: .accepted
        case .running: .running
        case .interrupted: .failed
        case .committed: .committed
        case .failed: .failed
        case .cancelled: .cancelled
        }
        return ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: status,
            errorCode: operation.errorCode,
            message: operation.message,
            operation: operation
        )
    }

    private func cancelOperation(for request: ControlRequest) -> ControlResponse {
        guard let operationID = request.operationID, let operation = operations[operationID] else {
            return .failure(for: request, code: .invalidRequest, message: "operation is not available")
        }
        guard operation.command == .modelPrepare else {
            return .failure(
                for: request,
                code: .unsupported,
                message: "profile operations cannot be cancelled after submission"
            )
        }
        guard operation.state == .accepted || operation.state == .running else {
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: operation.state == .cancelled ? .cancelled : .completed,
                operation: operation
            )
        }
        guard let cancellable = runner as? any CancellableManagedCommandRunner,
              cancellable.cancelCurrentCommand()
        else {
            return .failure(
                for: request,
                code: .unsupported,
                message: "model operation cannot be cancelled"
            )
        }
        let cancelled = OperationSnapshot(
            operationID: operation.operationID,
            command: operation.command,
            profile: operation.profile,
            state: .cancelled,
            phase: "cancelled",
            progress: operation.progress,
            message: "model preparation was cancelled"
        )
        operations[operationID] = cancelled
        persist(cancelled)
        clearJournalIfTerminal(cancelled)
        activeMutation = nil
        return ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: .cancelled,
            message: "model preparation was cancelled",
            operation: cancelled
        )
    }

    nonisolated private static func errorCode(for error: ManagedCommandError) -> ControlErrorCode {
        switch error {
        case .runtimeMissing: .managedRuntimeMissing
        case .launchFailed, .invalidOutput: .commandFailed
        }
    }

    nonisolated private static func message(for error: ManagedCommandError) -> String {
        switch error {
        case .runtimeMissing: "managed runtime is unavailable"
        case .launchFailed: "managed command could not be launched"
        case .invalidOutput: "managed command returned invalid output"
        }
    }

    private func persist(_ operation: OperationSnapshot) {
        guard operation.command == .modelPrepare, let journal else { return }
        do {
            try journal.save(operation)
            journalWarning = nil
        } catch {
            journalWarning = "model operation recovery state could not be saved"
        }
    }

    private func clearJournalIfTerminal(_ operation: OperationSnapshot) {
        guard operation.command == .modelPrepare,
              operation.state == .committed || operation.state == .failed || operation.state == .cancelled,
              let journal
        else { return }
        do {
            try journal.clear()
            journalWarning = nil
        } catch {
            journalWarning = "model operation recovery state could not be cleared"
        }
    }

    private func modelStatusResponse(from response: ControlResponse) -> ControlResponse {
        let activeOperation = activeModelOperation
        let modelStatus = response.modelStatus.map {
            ModelStatusSnapshot(
                artifacts: $0.artifacts,
                diarization: $0.diarization,
                disk: $0.disk,
                activeOperation: activeOperation
            )
        }
        return ControlResponse(
            requestID: response.requestID,
            command: response.command,
            status: response.status,
            errorCode: response.errorCode,
            message: response.message ?? journalWarning,
            service: response.service,
            profiles: response.profiles,
            profile: response.profile,
            checks: response.checks,
            modelCatalog: response.modelCatalog,
            modelStatus: modelStatus,
            operation: response.operation,
            schemaVersion: response.schemaVersion
        )
    }

    private var activeModelOperation: OperationSnapshot? {
        if let activeMutation,
           let operation = operations[activeMutation],
           operation.command == .modelPrepare,
           operation.state == .accepted || operation.state == .running
        {
            return operation
        }
        return operations.values.first {
            $0.command == .modelPrepare && $0.state == .interrupted
        }
    }

    nonisolated private static func profile(for command: ManagedCommand) -> SpeechRailProfile? {
        switch command {
        case let .profileApply(profile), let .modelPrepare(profile): profile
        default: nil
        }
    }
}
