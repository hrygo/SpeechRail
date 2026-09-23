import XCTest
import SpeechRailControlKit

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// Issue #88: 模型下载取消链缺少代际守卫。
///
/// 复现完全用注入的 `ClosureControlTransport` 闭包驱动真实 `AppModel` 状态机，
/// 不新增任何 mock 类型：脚本化响应由一个小 actor 提供，伪造诊断客户端只负责
/// 满足 `AppModel.init` 的必填依赖（这些用例根本不走服务 HTTP）。
@MainActor
final class AppModelTests: XCTestCase {

    // MARK: - (i) 过期 cancel→refresh 链不得覆盖更新的终态

    func testStaleCancelChainCannotOverwriteNewerTerminalRefresh() async {
        let statusScript = ModelStatusScript(schedule: .activeThenCommittedThenNil)
        let supersede = CancelSupersession()
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return Self.modelCatalogResponse(for: request)
            case .modelStatus:
                return await statusScript.next(for: request)
            case .operationCancel:
                // 取消请求还在传输层时，界面上又发起了一次更新的模型读取。
                // 这条更新的刷新会 bump 代数——旧取消链必须据此自认过期。
                await supersede.fire()
                return Self.cancellingResponse(for: request)
            case .operationStatus:
                return Self.cancelledOperationResponse(for: request)
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        await supersede.install { await model.refreshModels() }

        // 先让一个 model-prepare 操作处于活动态。
        await model.refreshModels()
        XCTAssertTrue(
            model.hasActiveMutation,
            "前置条件不成立：模型准备操作应当是活动态（operation=\(String(describing: model.operation))）"
        )

        await model.cancelCurrentOperation()

        XCTAssertEqual(
            model.operation?.state,
            .committed,
            "过期的 cancel→refresh 链把更新的终态覆盖回了过期操作（实际 operation=\(String(describing: model.operation))）。issue #88 要求 superseded 的取消链不得再落地状态。"
        )
        XCTAssertEqual(
            model.message,
            "模型准备已完成",
            "过期的 cancel→refresh 链用旧文案覆盖了更新刷新写下的终态消息（实际 message=\(String(describing: model.message))）。"
        )
    }

    // MARK: - (ii) 取消确认缺少 cancelling 相位时不得挂在待定文案上

    func testCancelAcknowledgementWithoutPhaseDoesNotStrandPendingMessage() async {
        // 精确复现修复前的 `UITestControlTransport` 对 `.operationCancel` 的默认响应：
        // status .completed、没有 operation、没有 cancelling 相位。
        let statusScript = ModelStatusScript(schedule: .activeThenNil)
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return Self.modelCatalogResponse(for: request)
            case .modelStatus:
                return await statusScript.next(for: request)
            case .operationCancel:
                return ControlResponse(
                    requestID: request.requestID,
                    command: .operationCancel,
                    status: .completed
                )
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        await model.refreshModels()
        XCTAssertTrue(
            model.hasActiveMutation,
            "前置条件不成立：模型准备操作应当是活动态（operation=\(String(describing: model.operation))）"
        )

        await model.cancelCurrentOperation()

        XCTAssertNil(
            model.message,
            "取消确认没有 cancelling 相位时，界面仍停在「正在停止模型准备…」的悬挂文案上（实际 message=\(String(describing: model.message))）。issue #88 要求取消链刷新一次，让服务状态成为唯一事实来源。"
        )
    }

    // MARK: - (iii) 更旧的模型刷新不得覆盖并发更新的刷新（issue #87）

    func testNewerConcurrentModelRefreshWinsOverOlderInFlightRefresh() async {
        let race = ConcurrentRefreshRace()
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return await race.catalog(for: request)
            case .modelStatus:
                return await race.status(for: request)
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        // 第一次刷新会在 modelStatus 处被拦下；拦截点内再发起一次更新的刷新，
        // 并让更新的刷新先返回，从而确定性地制造「旧读取后到」的竞争。
        await race.install { await model.refreshModels() }
        await model.refreshModels()

        XCTAssertEqual(
            model.modelStatus?.disk.modelBytes,
            ConcurrentRefreshRace.freshMarker,
            "更旧的并发刷新用过期结果覆盖了更新的刷新（实际 modelBytes=\(String(describing: model.modelStatus?.disk.modelBytes))）。issue #87 要求 generation 守卫让最新一次刷新胜出。"
        )
    }

    // MARK: - (iv) 过期取消链写下的旧文案不得挺过更新的刷新（issue #87）

    func testSupersededCancelMessageDoesNotSurviveNewerModelRefresh() async {
        let statusScript = ModelStatusScript(schedule: .activeThenNil)
        let supersede = CancelSupersession()
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return Self.modelCatalogResponse(for: request)
            case .modelStatus:
                return await statusScript.next(for: request)
            case .operationCancel:
                // 取消请求还在传输层时，界面又发起并完成了一次更新的模型刷新；
                // 随后取消请求以失败收场——这条过期链不得再写入旧文案。
                await supersede.fire()
                throw CancelTransportFailure()
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        await supersede.install { await model.refreshModels() }
        await model.refreshModels()
        XCTAssertTrue(
            model.hasActiveMutation,
            "前置条件不成立：模型准备操作应当是活动态（operation=\(String(describing: model.operation))）"
        )

        await model.cancelCurrentOperation()

        XCTAssertNil(
            model.message,
            "过期取消链在更新的刷新之后写下的旧文案仍然存活（实际 message=\(String(describing: model.message))）。issue #87 要求 message 有 generation token：过期链的写入必须被丢弃。"
        )
    }

    // MARK: - Helpers

    private func makeModel(transport: any SpeechRailControlTransport) -> AppModel {
        AppModel(transport: transport, apiClient: UnavailableDiagnosticsClient())
    }

    nonisolated private static func modelCatalogResponse(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .modelCatalog,
            status: .ok,
            modelCatalog: ModelCatalogSnapshot(artifacts: [], profiles: [])
        )
    }

    nonisolated private static func cancellingResponse(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .operationCancel,
            status: .running,
            message: "stopping model preparation",
            operation: OperationSnapshot(
                operationID: request.operationID ?? "op-1",
                command: .modelPrepare,
                state: .running,
                phase: "cancelling",
                message: "stopping model preparation"
            )
        )
    }

    nonisolated private static func cancelledOperationResponse(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .operationStatus,
            status: .failed,
            errorCode: .cancelled,
            operation: OperationSnapshot(
                operationID: "op-1",
                command: .modelPrepare,
                state: .cancelled,
                phase: "cancelled",
                errorCode: .cancelled,
                message: "model preparation was cancelled"
            )
        )
    }
}

/// `AppModel.init` 必填的诊断客户端。这些用例只跑控制平面状态机，
/// 从不触发服务 HTTP，因此读取一律失败即可。
private struct UnavailableDiagnosticsClient: ServiceDiagnosticsClient {
    var port: Int? { nil }

    func fetchHealthSnapshot() async throws -> HealthSnapshot {
        throw ServiceAPIClientError.requestFailed
    }

    func fetchMetrics() async throws -> RuntimeMetricsSnapshot {
        throw ServiceAPIClientError.requestFailed
    }
}

/// 按调用次序给出 `modelStatus` 响应的脚本。用 actor 隔离，保证并行测试之间
/// 没有共享可变状态。
private actor ModelStatusScript {
    enum Schedule {
        /// 第一次返回活动操作，其余次返回空活动操作（用于取消确认用例）。
        case activeThenNil
        /// 第一次活动；第二次终态 committed；之后为空（用于代际守卫用例）。
        case activeThenCommittedThenNil
    }

    private let schedule: Schedule
    private var calls = 0

    init(schedule: Schedule) {
        self.schedule = schedule
    }

    func next(for request: ControlRequest) -> ControlResponse {
        calls += 1
        switch (schedule, calls) {
        case (.activeThenNil, 1), (.activeThenCommittedThenNil, 1):
            return ControlResponse(
                requestID: request.requestID,
                command: .modelStatus,
                status: .ok,
                modelStatus: snapshot(activeOperation: activeOperation())
            )
        case (.activeThenCommittedThenNil, 2):
            return ControlResponse(
                requestID: request.requestID,
                command: .modelStatus,
                status: .ok,
                message: "模型准备已完成",
                modelStatus: snapshot(activeOperation: committedOperation())
            )
        default:
            return ControlResponse(
                requestID: request.requestID,
                command: .modelStatus,
                status: .ok,
                modelStatus: snapshot(activeOperation: nil)
            )
        }
    }

    private func snapshot(activeOperation: OperationSnapshot?) -> ModelStatusSnapshot {
        ModelStatusSnapshot(
            artifacts: [],
            disk: ModelDiskSnapshot(modelBytes: 0, freeBytes: 0),
            activeOperation: activeOperation
        )
    }

    private func activeOperation() -> OperationSnapshot {
        OperationSnapshot(
            operationID: "op-1",
            command: .modelPrepare,
            state: .running,
            phase: "download"
        )
    }

    private func committedOperation() -> OperationSnapshot {
        OperationSnapshot(
            operationID: "op-1",
            command: .modelPrepare,
            state: .committed,
            phase: "committed"
        )
    }
}

/// 让测试在取消请求「传输中」触发一次更新的刷新，从而确定性地制造代际竞争，
/// 不依赖 500ms 轮询时序。
private actor CancelSupersession {
    private var refresh: (@Sendable () async -> Void)?

    func install(_ action: @escaping @Sendable () async -> Void) {
        refresh = action
    }

    func fire() async {
        guard let refresh else { return }
        await refresh()
    }
}

/// 取消请求的传输层失败：用于让过期的取消链走进 catch 分支并尝试写入旧文案。
private struct CancelTransportFailure: Error {}

/// 制造两次并发模型刷新的确定性竞争：第一次 `modelStatus` 被拦下时触发一次更新的
/// 刷新并等待它完成，再放行旧的（过期的）响应。
private actor ConcurrentRefreshRace {
    static let staleMarker: Int64 = 111
    static let freshMarker: Int64 = 222

    private var statusCalls = 0
    private var newerRefresh: (@Sendable () async -> Void)?

    func install(_ action: @escaping @Sendable () async -> Void) {
        newerRefresh = action
    }

    func catalog(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .modelCatalog,
            status: .ok,
            modelCatalog: ModelCatalogSnapshot(artifacts: [], profiles: [])
        )
    }

    func status(for request: ControlRequest) async -> ControlResponse {
        statusCalls += 1
        if statusCalls == 1 {
            if let newerRefresh { await newerRefresh() }
            return diskResponse(for: request, bytes: Self.staleMarker)
        }
        return diskResponse(for: request, bytes: Self.freshMarker)
    }

    private func diskResponse(for request: ControlRequest, bytes: Int64) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .modelStatus,
            status: .ok,
            modelStatus: ModelStatusSnapshot(
                artifacts: [],
                disk: ModelDiskSnapshot(modelBytes: bytes, freeBytes: 0),
                activeOperation: nil
            )
        )
    }
}