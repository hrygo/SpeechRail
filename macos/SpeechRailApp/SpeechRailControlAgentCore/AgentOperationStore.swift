import Foundation
import SpeechRailControlKit

public actor AgentOperationStore {
    private let runner: any ManagedCommandRunner
    private var activeMutation: String?
    private var operations: [String: OperationSnapshot] = [:]

    public init(runner: any ManagedCommandRunner) {
        self.runner = runner
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
            return await acceptProfileApply(request)
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
                return response.rebound(to: request)
            }
            let code: ControlErrorCode = result.exitCode == 0 ? .commandFailed : .serviceUnavailable
            return .failure(for: request, code: code, message: result.message ?? "managed command failed")
        } catch let error as ManagedCommandError {
            return .failure(for: request, code: errorCode(for: error), message: message(for: error))
        } catch {
            return .failure(for: request, code: .commandFailed, message: "managed command failed")
        }
    }

    private func acceptProfileApply(_ request: ControlRequest) async -> ControlResponse {
        guard let profile = request.profile else {
            return .failure(for: request, code: .invalidRequest, message: "profile is required")
        }
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
            command: .profileApply,
            state: .accepted,
            phase: "accepted"
        )
        operations[operationID] = accepted
        activeMutation = operationID
        let runner = self.runner
        Task { [weak self] in
            do {
                let result = try await runner.run(.profileApply(profile))
                await self?.finish(operationID: operationID, result: result)
            } catch let error as ManagedCommandError {
                await self?.finish(
                    operationID: operationID,
                    result: ManagedCommandResult(
                        exitCode: -1,
                        response: ControlResponse(
                            requestID: request.requestID,
                            command: .profileApply,
                            status: .failed,
                            errorCode: errorCode(for: error),
                            message: message(for: error)
                        )
                    )
                )
            } catch {
                await self?.finish(
                    operationID: operationID,
                    result: ManagedCommandResult(
                        exitCode: -1,
                        response: ControlResponse(
                            requestID: request.requestID,
                            command: .profileApply,
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

    private func finish(operationID: String, result: ManagedCommandResult) {
        let response = result.response
        let succeeded = result.exitCode == 0 && response?.status != .failed
        let snapshot = OperationSnapshot(
            operationID: operationID,
            command: .profileApply,
            state: succeeded ? .committed : .failed,
            phase: succeeded ? "committed" : "failed",
            errorCode: succeeded ? nil : (response?.errorCode ?? .commandFailed)
        )
        operations[operationID] = snapshot
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
        case .committed: .committed
        case .failed: .failed
        case .cancelled: .cancelled
        }
        return ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: status,
            errorCode: operation.errorCode,
            operation: operation
        )
    }

    private func cancelOperation(for request: ControlRequest) -> ControlResponse {
        guard let operationID = request.operationID, operations[operationID] != nil else {
            return .failure(for: request, code: .invalidRequest, message: "operation is not available")
        }
        return .failure(
            for: request,
            code: .unsupported,
            message: "profile operations cannot be cancelled after submission"
        )
    }

    private func errorCode(for error: ManagedCommandError) -> ControlErrorCode {
        switch error {
        case .runtimeMissing: .managedRuntimeMissing
        case .launchFailed, .invalidOutput: .commandFailed
        }
    }

    private func message(for error: ManagedCommandError) -> String {
        switch error {
        case .runtimeMissing: "managed runtime is unavailable"
        case .launchFailed: "managed command could not be launched"
        case .invalidOutput: "managed command returned invalid output"
        }
    }
}
