import Foundation
import SpeechRailControlAgentCore
import SpeechRailControlKit
#if SWIFT_PACKAGE
import SpeechRailAppSupport
#endif
import XCTest

final class ControlKitTests: XCTestCase {
    func testRequestAndResponseRoundTripUseSchemaVersionOne() throws {
        let request = ControlRequest(
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            command: .profileApply,
            selection: .quick(.quality),
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
        XCTAssertEqual(SpeechRailProfile.allCases, [.fast, .quality, .reference])
    }

    func testUnknownProfileDecodesForFactsButCannotBeSelectedOrSent() throws {
        let health = try JSONDecoder().decode(
            HealthSnapshot.self,
            from: Data(#"{"profile":"future_tier/quality"}"#.utf8)
        )
        let summary = try JSONDecoder().decode(
            ProfileSummary.self,
            from: Data(
                #"{"id":"future_tier","asr":"asr","tts":"tts","download_bytes":10}"#.utf8
            )
        )
        XCTAssertEqual(health.profile, "future_tier/quality")
        XCTAssertNil(health.selection, "one unknown side means no resolvable spec pair")
        XCTAssertEqual(summary.id, .unrecognized("future_tier"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                ProfileSummary.self,
                from: JSONEncoder().encode(summary)
            ).id,
            .unrecognized("future_tier")
        )
        XCTAssertFalse(summary.id.isSelectable)

        for command in [ControlCommand.profileApply, .modelPrepare] {
            XCTAssertThrowsError(
                try ControlRequest(
                    command: command,
                    selection: SpecSelection(
                        asrSpec: .unrecognized("future_tier"),
                        ttsSpec: .quality
                    ),
                    confirmation: true
                ).validate()
            ) { error in
                XCTAssertEqual(error as? ControlProtocolError, .profileUnsupported)
                XCTAssertEqual(
                    (error as? ControlProtocolError)?.errorCode,
                    .invalidRequest
                )
            }
        }
    }

    func testSelectableProfilesComeOnlyFromTheConnectedServiceCatalog() {
        let publishedCatalog = ModelCatalogSnapshot(
            artifacts: [],
            profiles: [
                ProfileSummary(id: .quality, asr: "asr", tts: "tts", downloadBytes: 10),
                ProfileSummary(id: .fast, asr: "asr", tts: "tts", downloadBytes: 10),
                ProfileSummary(
                    id: .unrecognized("future_tier"),
                    asr: "asr",
                    tts: "tts",
                    downloadBytes: 10
                ),
            ]
        )
        let referenceCatalog = ModelCatalogSnapshot(
            artifacts: [],
            profiles: [
                ProfileSummary(id: .fast, asr: "asr", tts: "tts", downloadBytes: 10),
                ProfileSummary(id: .quality, asr: "asr", tts: "tts", downloadBytes: 10),
                ProfileSummary(id: .reference, asr: "asr", tts: "tts", downloadBytes: 10),
            ]
        )

        XCTAssertEqual(publishedCatalog.selectableProfiles, [.fast, .quality])
        XCTAssertEqual(referenceCatalog.selectableProfiles, [.fast, .quality, .reference])
    }

    func testRemainingDownloadUpperBoundRequiresCompleteStatusAndMatchingTotals() {
        func artifact(_ key: String, sizeBytes: Int64) -> ModelArtifactSnapshot {
            ModelArtifactSnapshot(
                key: key,
                modelID: key,
                family: "qwen",
                variant: "base",
                revision: "revision",
                provider: "modelscope",
                repository: "repo",
                quantization: ModelQuantizationSnapshot(format: "none"),
                sizeBytes: sizeBytes,
                fileCount: 1,
                requiredBy: [.reference]
            )
        }

        func status(
            _ key: String,
            state: ModelArtifactState,
            integrity: ModelIntegrityState
        ) -> ModelArtifactStatusSnapshot {
            ModelArtifactStatusSnapshot(
                key: key,
                state: state,
                integrity: integrity,
                verifiedFileCount: state == .verified ? 1 : 0,
                totalFileCount: 1
            )
        }

        let catalog = ModelCatalogSnapshot(
            artifacts: [
                artifact("asr", sizeBytes: 100),
                artifact("design", sizeBytes: 200),
                artifact("base", sizeBytes: 300),
            ],
            profiles: [
                ProfileSummary(
                    id: .reference,
                    asr: "asr",
                    tts: "design",
                    ttsClone: "base",
                    downloadBytes: 600
                ),
            ]
        )
        let disk = ModelDiskSnapshot(modelBytes: 100, freeBytes: 1_000)
        let partialStatuses = ModelStatusSnapshot(
            artifacts: [
                status("asr", state: .verified, integrity: .verified),
                status("design", state: .notDownloaded, integrity: .notChecked),
            ],
            disk: disk
        )
        XCTAssertNil(catalog.remainingDownloadUpperBound(for: .reference, statuses: partialStatuses))

        let completeStatuses = ModelStatusSnapshot(
            artifacts: [
                status("asr", state: .verified, integrity: .verified),
                status("design", state: .notDownloaded, integrity: .notChecked),
                status("base", state: .verified, integrity: .mismatch),
            ],
            disk: disk
        )
        XCTAssertEqual(
            catalog.remainingDownloadUpperBound(for: .reference, statuses: completeStatuses),
            500
        )

        let verifiedStatuses = ModelStatusSnapshot(
            artifacts: [
                status("asr", state: .verified, integrity: .verified),
                status("design", state: .verified, integrity: .verified),
                status("base", state: .verified, integrity: .verified),
            ],
            disk: disk
        )
        XCTAssertEqual(
            catalog.remainingDownloadUpperBound(for: .reference, statuses: verifiedStatuses),
            0
        )
        XCTAssertNil(catalog.remainingDownloadUpperBound(for: .reference, statuses: nil))
    }

    func testRemainingDownloadUpperBoundIncludesCoreMLDiarizationBundle() {
        func artifact(_ key: String, sizeBytes: Int64) -> ModelArtifactSnapshot {
            ModelArtifactSnapshot(
                key: key,
                modelID: key,
                family: "qwen",
                variant: "base",
                revision: "revision",
                provider: "modelscope",
                repository: "repo",
                quantization: ModelQuantizationSnapshot(format: "none"),
                sizeBytes: sizeBytes,
                fileCount: 1,
                requiredBy: [.reference]
            )
        }

        func status(
            _ key: String,
            state: ModelArtifactState,
            integrity: ModelIntegrityState
        ) -> ModelArtifactStatusSnapshot {
            ModelArtifactStatusSnapshot(
                key: key,
                state: state,
                integrity: integrity,
                verifiedFileCount: state == .verified ? 1 : 0,
                totalFileCount: 1
            )
        }

        let catalog = ModelCatalogSnapshot(
            artifacts: [
                artifact("asr", sizeBytes: 100),
                artifact("design", sizeBytes: 200),
                artifact("base", sizeBytes: 300),
            ],
            profiles: [
                ProfileSummary(
                    id: .reference,
                    asr: "asr",
                    tts: "design",
                    ttsClone: "base",
                    diarization: true,
                    downloadBytes: 900
                ),
            ]
        )
        let disk = ModelDiskSnapshot(modelBytes: 0, freeBytes: 1_000)
        let verifiedModelStatuses = [
            status("asr", state: .verified, integrity: .verified),
            status("design", state: .verified, integrity: .verified),
            status("base", state: .verified, integrity: .verified),
        ]
        let missingCoreMLStatus = ModelStatusSnapshot(
            artifacts: verifiedModelStatuses,
            disk: disk
        )
        XCTAssertNil(catalog.remainingDownloadUpperBound(for: .reference, statuses: missingCoreMLStatus))

        let pendingCoreMLStatus = ModelStatusSnapshot(
            artifacts: verifiedModelStatuses,
            diarization: [status("diarization-coreml", state: .notDownloaded, integrity: .notChecked)],
            disk: disk
        )
        XCTAssertEqual(
            catalog.remainingDownloadUpperBound(for: .reference, statuses: pendingCoreMLStatus),
            300
        )

        let verifiedCoreMLStatus = ModelStatusSnapshot(
            artifacts: verifiedModelStatuses,
            diarization: [status("diarization-coreml", state: .verified, integrity: .verified)],
            disk: disk
        )
        XCTAssertEqual(
            catalog.remainingDownloadUpperBound(for: .reference, statuses: verifiedCoreMLStatus),
            0
        )
    }

    /// 混合组合的下载量只能从两个规格各自的制品并集推导——目录没有第三份「组合摘要」。
    func testArtifactsForSelectionUnionsAsrAndTtsSpecsInCatalogOrder() {
        func artifact(_ key: String, sizeBytes: Int64, requiredBy: [SpeechRailProfile]) -> ModelArtifactSnapshot {
            ModelArtifactSnapshot(
                key: key,
                modelID: key,
                family: "qwen",
                variant: "base",
                revision: "revision",
                provider: "modelscope",
                repository: "repo",
                quantization: ModelQuantizationSnapshot(format: "none"),
                sizeBytes: sizeBytes,
                fileCount: 1,
                requiredBy: requiredBy
            )
        }

        let catalog = ModelCatalogSnapshot(
            artifacts: [
                artifact("asr", sizeBytes: 100, requiredBy: [.fast, .quality]),
                artifact("tts", sizeBytes: 200, requiredBy: [.quality, .reference]),
                artifact("clone", sizeBytes: 300, requiredBy: [.reference]),
            ],
            profiles: []
        )

        XCTAssertEqual(
            catalog.artifacts(for: .quick(.quality)).map(\.key),
            ["asr", "tts"]
        )
        // 并集按目录顺序返回，不受 asr/tts 提交顺序影响。
        XCTAssertEqual(
            catalog.artifacts(for: SpecSelection(asrSpec: .quality, ttsSpec: .reference)).map(\.key),
            ["asr", "tts", "clone"]
        )
        XCTAssertEqual(
            catalog.artifacts(for: SpecSelection(asrSpec: .reference, ttsSpec: .quality)).map(\.key),
            ["asr", "tts", "clone"]
        )
    }

    func testRemainingDownloadUpperBoundForQuickSelectionMatchesProfileMath() {
        func artifact(_ key: String, sizeBytes: Int64, requiredBy: [SpeechRailProfile]) -> ModelArtifactSnapshot {
            ModelArtifactSnapshot(
                key: key,
                modelID: key,
                family: "qwen",
                variant: "base",
                revision: "revision",
                provider: "modelscope",
                repository: "repo",
                quantization: ModelQuantizationSnapshot(format: "none"),
                sizeBytes: sizeBytes,
                fileCount: 1,
                requiredBy: requiredBy
            )
        }

        func status(_ key: String, verified: Bool) -> ModelArtifactStatusSnapshot {
            ModelArtifactStatusSnapshot(
                key: key,
                state: verified ? .verified : .notDownloaded,
                integrity: verified ? .verified : .notChecked,
                verifiedFileCount: verified ? 1 : 0,
                totalFileCount: 1
            )
        }

        let catalog = ModelCatalogSnapshot(
            artifacts: [
                artifact("asr", sizeBytes: 100, requiredBy: [.quality]),
                artifact("tts", sizeBytes: 200, requiredBy: [.quality]),
            ],
            profiles: [
                ProfileSummary(id: .quality, asr: "asr", tts: "tts", downloadBytes: 300),
            ]
        )
        let statuses = ModelStatusSnapshot(
            artifacts: [
                status("asr", verified: true),
                status("tts", verified: false),
            ],
            disk: ModelDiskSnapshot(modelBytes: 0, freeBytes: 1_000)
        )

        // 快捷组合没有混合项，必须复用整档摘要的算法。
        XCTAssertEqual(
            catalog.remainingDownloadUpperBound(for: .quick(.quality), statuses: statuses),
            catalog.remainingDownloadUpperBound(for: .quality, statuses: statuses)
        )
        XCTAssertEqual(
            catalog.remainingDownloadUpperBound(for: .quick(.quality), statuses: statuses),
            200
        )
    }

    func testRemainingDownloadUpperBoundForMixedSelectionUnionsArtifacts() {
        func artifact(_ key: String, sizeBytes: Int64, requiredBy: [SpeechRailProfile]) -> ModelArtifactSnapshot {
            ModelArtifactSnapshot(
                key: key,
                modelID: key,
                family: "qwen",
                variant: "base",
                revision: "revision",
                provider: "modelscope",
                repository: "repo",
                quantization: ModelQuantizationSnapshot(format: "none"),
                sizeBytes: sizeBytes,
                fileCount: 1,
                requiredBy: requiredBy
            )
        }

        func status(_ key: String, verified: Bool) -> ModelArtifactStatusSnapshot {
            ModelArtifactStatusSnapshot(
                key: key,
                state: verified ? .verified : .notDownloaded,
                integrity: verified ? .verified : .notChecked,
                verifiedFileCount: verified ? 1 : 0,
                totalFileCount: 1
            )
        }

        let catalog = ModelCatalogSnapshot(
            artifacts: [
                artifact("asr", sizeBytes: 100, requiredBy: [.quality]),
                artifact("tts", sizeBytes: 200, requiredBy: [.quality, .reference]),
                artifact("clone", sizeBytes: 300, requiredBy: [.reference]),
            ],
            profiles: []
        )
        let mixed = SpecSelection(asrSpec: .quality, ttsSpec: .reference)
        let disk = ModelDiskSnapshot(modelBytes: 0, freeBytes: 10_000)

        // 缺失任一制品状态时保持未知，不猜一个偏小的下载量。
        let partial = ModelStatusSnapshot(
            artifacts: [
                status("asr", verified: true),
                status("tts", verified: false),
            ],
            disk: disk
        )
        XCTAssertNil(catalog.remainingDownloadUpperBound(for: mixed, statuses: partial))
        XCTAssertNil(catalog.remainingDownloadUpperBound(for: mixed, statuses: nil))

        // 完整状态：未校验的制品按全量计入上界。
        let complete = ModelStatusSnapshot(
            artifacts: [
                status("asr", verified: true),
                status("tts", verified: false),
                status("clone", verified: true),
            ],
            disk: disk
        )
        XCTAssertEqual(catalog.remainingDownloadUpperBound(for: mixed, statuses: complete), 200)

        // 混合组合里两个规格都没有制品时，不返回一个「0 字节」的假结论。
        XCTAssertNil(
            catalog.remainingDownloadUpperBound(
                for: SpecSelection(asrSpec: .fast, ttsSpec: .unrecognized("future")),
                statuses: complete
            )
        )
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
            selection: .quick(.quality),
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

    func testModelStatusPrefersDedicatedDiarizationInspectionForOverlappingArtifact() {
        let generic = ModelArtifactStatusSnapshot(
            key: "aligner-bf16",
            state: .notDownloaded,
            integrity: .notChecked,
            verifiedFileCount: 0,
            totalFileCount: 10
        )
        let dedicated = ModelArtifactStatusSnapshot(
            key: "aligner-bf16",
            state: .verified,
            integrity: .verified,
            verifiedFileCount: 10,
            totalFileCount: 10
        )
        let snapshot = ModelStatusSnapshot(
            artifacts: [generic],
            diarization: [dedicated],
            disk: ModelDiskSnapshot(modelBytes: 0, freeBytes: 1)
        )

        XCTAssertEqual(snapshot.status(for: "aligner-bf16"), dedicated)
        XCTAssertEqual(snapshot.status(for: "unknown"), nil)
    }

    func testRecoveryFieldsRoundTripWithoutChangingSchemaVersion() throws {
        let operation = OperationSnapshot(
            operationID: "model_recovery_123",
            command: .modelPrepare,
            selection: .quick(.quality),
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
        XCTAssertEqual(decoded.modelStatus?.activeOperation?.selection, .quick(.quality))
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
                activeRequests: 1,
                realtimeActiveRequests: 1,
                batchActiveRequests: 0
            ),
            RuntimeMonitoringChartPoint(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_005),
                activeRequests: 3,
                realtimeActiveRequests: 2,
                batchActiveRequests: 1
            ),
        ]

        let chart = RuntimeMonitoringChartDescriptor(points: points).makeChartDescriptor()

        XCTAssertEqual(chart.title, "同时处理的请求数趋势")
        XCTAssertTrue(chart.summary?.contains("同时处理") == true)
        XCTAssertEqual(chart.xAxis.title, "时间")
        XCTAssertEqual(chart.yAxis?.title, "同时处理")
        // 并发图与 Figma `lineChart` 一致地画两条序列：合计值不足以描述这张图。
        XCTAssertEqual(chart.series.map(\.name), ["实时语音会话", "单次请求"])
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

    /// 图上的耗时折线在无障碍侧也按毫秒报：序列名里的单位与 `y` 必须是同一个口径，
    /// 否则 VoiceOver 读到的数与它说的单位对不上（2026-09-17）。
    func testRuntimeMonitoringChartDescriptorReportsLatencyInMilliseconds() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let chart = RuntimeMonitoringChartDescriptor(
            points: [
                RuntimeMonitoringChartPoint(capturedAt: start, activeRequests: 1),
                RuntimeMonitoringChartPoint(
                    capturedAt: start.addingTimeInterval(5),
                    activeRequests: 2
                ),
            ],
            latency: [
                RuntimeLatencySample(capturedAt: start, asrSeconds: 0.42, ttsSeconds: nil),
                RuntimeLatencySample(
                    capturedAt: start.addingTimeInterval(5),
                    asrSeconds: nil,
                    ttsSeconds: 1.5
                ),
            ]
        ).makeChartDescriptor()

        let names = chart.series.map(\.name)
        XCTAssertTrue(names.contains("语音识别耗时（毫秒）"))
        XCTAssertTrue(names.contains("语音合成耗时（毫秒）"))
        XCTAssertEqual(chart.yAxis?.title, "同时处理（左轴）／耗时（毫秒，右轴）")

        let asrPoint = try XCTUnwrap(
            chart.series.first { $0.name == "语音识别耗时（毫秒）" }?.dataPoints.first
        )
        // `AXDataPointValue.number` 是 `NS_REFINED_FOR_SWIFT`，Swift 侧的名字带前缀。
        XCTAssertEqual(try XCTUnwrap(asrPoint.yValue?.__number), 420, accuracy: 0.001)
    }

    func testRuntimeMetricsSamplerIncludesPublishedSignalsAndAdjacentRates() {
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = RuntimeMetricsSnapshot(
            counters: [
                "speechrail_http_requests_total": 10,
                "speechrail_governor_queue_rejections_total": 1,
            ],
            gauges: ["speechrail_realtime_active_sessions": 2],
            histograms: [
                "speechrail_tts_ttfa_seconds": [
                    "": RuntimeHistogramSummary(count: 2, sum: 0.6, average: 0.3),
                ],
            ]
        )
        let firstSample = RuntimeMetricsSampler.makeSample(
            from: first,
            capturedAt: firstDate
        )

        // 第一个采样点只有累计量：窗口值要等第二个点才能算，不能拿 lifetime
        // 均值冒充实时值。
        XCTAssertNil(firstSample.ttsTTFASeconds)
        XCTAssertEqual(firstSample.ttsTTFA, RuntimeHistogramTotals(sum: 0.6, count: 2))
        XCTAssertEqual(firstSample.activeRealtimeSessions, 2)
        XCTAssertNil(firstSample.requestRatePerSecond)

        let second = RuntimeMetricsSnapshot(
            counters: [
                "speechrail_http_requests_total": 20,
                "speechrail_governor_queue_rejections_total": 3,
            ],
            gauges: ["speechrail_realtime_active_sessions": 4],
            histograms: [
                "speechrail_tts_ttfa_seconds": [
                    "": RuntimeHistogramSummary(count: 4, sum: 1.8, average: 0.45),
                ],
            ]
        )
        let secondSample = RuntimeMetricsSampler.makeSample(
            from: second,
            capturedAt: firstDate.addingTimeInterval(5),
            previous: firstSample
        )

        XCTAssertEqual(secondSample.activeRealtimeSessions, 4)
        XCTAssertEqual(secondSample.requestRatePerSecond, 2.0)
        XCTAssertEqual(secondSample.queueRejectionRatePerSecond, 0.4)
        // increase(sum)/increase(count) = (1.8-0.6)/(4-2)
        XCTAssertEqual(secondSample.ttsTTFASeconds ?? 0, 0.6, accuracy: 0.000_1)
    }

    func testRuntimeMonitoringWindowUsesIncreaseNotLifetimeAverage() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [0, 5, 10].map { offset -> RuntimeMetricsSample in
            let totals = RuntimeHistogramTotals(
                sum: 1.0 * Double(offset / 5 + 1),
                count: Double(offset / 5 + 1)
            )
            return RuntimeMetricsSample(
                capturedAt: start.addingTimeInterval(Double(offset)),
                activeRequests: 1,
                pendingRequests: 0,
                requestCount: 10 + Double(offset),
                requestErrors: offset == 10 ? 2 : 0,
                queueRejections: 0,
                asrLatencySeconds: nil,
                ttsLatencySeconds: nil,
                asrDuration: totals
            )
        }

        let window = RuntimeMonitoringWindow(samples: samples)

        XCTAssertEqual(window.windowSeconds ?? 0, 10, accuracy: 0.000_1)
        XCTAssertEqual(window.requestRate ?? 0, 1.0, accuracy: 0.000_1)
        // 窗内只有最后一个点带来了两个错误。
        XCTAssertEqual(window.errorRate ?? 0, 0.2, accuracy: 0.000_1)
        XCTAssertEqual(window.errorRatio ?? 0, 2.0 / 10.0, accuracy: 0.000_1)
        // increase(sum)/increase(count) = (3-1)/(3-1)，不是最后一点的累计均值。
        XCTAssertEqual(window.asrLatencySeconds ?? 0, 1.0, accuracy: 0.000_1)
        XCTAssertNil(window.ttsLatencySeconds)
    }

    func testRuntimeMonitoringWindowReportsNoDataInsteadOfZero() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let onlySample = RuntimeMetricsSample(
            capturedAt: start,
            activeRequests: 0,
            pendingRequests: 0,
            requestCount: 10,
            queueRejections: 0,
            asrLatencySeconds: nil,
            ttsLatencySeconds: nil
        )

        // 一个样本说明还没有窗口，不能把 0 当成「没有错误」。
        XCTAssertNil(RuntimeMonitoringWindow(samples: [onlySample]).errorRatio)
        XCTAssertNil(RuntimeMonitoringWindow(samples: []).requestRate)
    }

    /// `/metrics` 的 TTS 时延直方图带 `voice_class` 标签，界面按类别各算一条
    /// 窗口均值；合并口径仍然要和 Prometheus 聚合一致。
    func testTTSLatencyIsSplitByVoiceClassAndStillAggregates() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func snapshot(system: (Double, Double), custom: (Double, Double)) -> RuntimeMetricsSnapshot {
            RuntimeMetricsSnapshot(
                histograms: [
                    "speechrail_tts_inference_duration_seconds": [
                        "{voice_class=\"custom\"}": RuntimeHistogramSummary(
                            count: Int(custom.1),
                            sum: custom.0,
                            average: custom.0 / custom.1
                        ),
                        "{voice_class=\"system\"}": RuntimeHistogramSummary(
                            count: Int(system.1),
                            sum: system.0,
                            average: system.0 / system.1
                        ),
                    ],
                ]
            )
        }

        let first = RuntimeMetricsSampler.makeSample(
            from: snapshot(system: (0.8, 2), custom: (0.9, 1)),
            capturedAt: start
        )
        let second = RuntimeMetricsSampler.makeSample(
            from: snapshot(system: (1.6, 4), custom: (1.9, 2)),
            capturedAt: start.addingTimeInterval(5),
            previous: first
        )

        let window = RuntimeMonitoringWindow(samples: [first, second])
        let rows = window.ttsLatencyByVoiceClass

        XCTAssertEqual(rows.count, 2)
        // 排序保证界面行序稳定：custom 在 system 之前。
        XCTAssertEqual(rows.first?.voiceClass, "custom")
        XCTAssertEqual(rows.first?.seconds ?? 0, 1.0, accuracy: 0.000_1)
        XCTAssertEqual(rows.first?.count ?? 0, 1, accuracy: 0.000_1)
        XCTAssertEqual(rows.last?.voiceClass, "system")
        XCTAssertEqual(rows.last?.seconds ?? 0, 0.4, accuracy: 0.000_1)
        XCTAssertEqual(rows.last?.count ?? 0, 2, accuracy: 0.000_1)
        // 合并口径 = increase(sum) / increase(count) = (3.5-1.7)/(6-3)。
        XCTAssertEqual(window.ttsLatencySeconds ?? 0, 0.6, accuracy: 0.000_1)
    }

    func testTTSLatencyByVoiceClassIsEmptyInsteadOfZeroWithoutSamples() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let onlySample = RuntimeMetricsSampler.makeSample(
            from: RuntimeMetricsSnapshot(),
            capturedAt: start
        )

        XCTAssertTrue(RuntimeMonitoringWindow(samples: [onlySample]).ttsLatencyByVoiceClass.isEmpty)
        XCTAssertTrue(RuntimeMonitoringWindow(samples: []).ttsLatencyByVoiceClass.isEmpty)
    }

    func testLabelValueReadsOnlyTheRequestedLabel() {
        XCTAssertEqual(
            RuntimeMetricsSampler.labelValue(
                "speechrail_x{voice_class=\"system\",le=\"1.0\"}",
                label: "voice_class"
            ),
            "system"
        )
        XCTAssertNil(
            RuntimeMetricsSampler.labelValue("{le=\"1.0\"}", label: "voice_class")
        )
    }

    /// 用户口径的用量只数语音接口：App 自己每 5 秒的轮询（`/health`、`/metrics`、
    /// `/v1/models`、`/v1/voices`）不能算成「请求」——本机实测它们占累计请求的 97.6%，
    /// 混进来这个数字就既不跟用户的行为走，也不反映工作量（REDESIGN-SPEC §7.6）。
    func testUsageTotalsCountOnlySpeechEndpointsAndTakeWindowIncrease() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func counters(tts: Double, previews: Double, asr: Double, health: Double) -> [String: Double] {
            [
                "speechrail_http_requests_total{endpoint=\"/health\",method=\"GET\",status=\"200\"}": health,
                "speechrail_http_requests_total{endpoint=\"/v1/audio/speech\",method=\"POST\",status=\"200\"}": tts,
                "speechrail_http_requests_total{endpoint=\"/v1/voices/previews\",method=\"POST\",status=\"200\"}": previews,
                "speechrail_http_requests_total{endpoint=\"/v1/audio/transcriptions\",method=\"POST\",status=\"200\"}": asr,
            ]
        }
        let first = RuntimeMetricsSampler.makeSample(
            from: RuntimeMetricsSnapshot(
                counters: counters(tts: 2, previews: 1, asr: 1, health: 400).merging([
                    "speechrail_tts_generated_audio_seconds_total{voice_class=\"system\"}": 4.0,
                    "speechrail_tts_generated_audio_seconds_total{voice_class=\"custom\"}": 2.0,
                    "speechrail_asr_processed_audio_seconds_total": 8.0,
                    "speechrail_realtime_sessions_total": 1.0,
                ]) { current, _ in current }
            ),
            capturedAt: start
        )
        let second = RuntimeMetricsSampler.makeSample(
            from: RuntimeMetricsSnapshot(
                counters: counters(tts: 3, previews: 1, asr: 1, health: 412).merging([
                    "speechrail_tts_generated_audio_seconds_total{voice_class=\"system\"}": 10.0,
                    "speechrail_tts_generated_audio_seconds_total{voice_class=\"custom\"}": 3.5,
                    "speechrail_asr_processed_audio_seconds_total": 8.0,
                    "speechrail_realtime_sessions_total": 2.0,
                ]) { current, _ in current }
            ),
            capturedAt: start.addingTimeInterval(5),
            previous: first
        )

        // 第一个点只有累计量，窗口增量要等第二个点。
        // 试听走同一条 record_tts，所以它算「合成」的一次。
        XCTAssertEqual(first.usage.ttsRequests, 3)
        XCTAssertEqual(first.usage.asrRequests, 1)
        XCTAssertTrue(RuntimeMonitoringWindow(samples: [first]).usageIncrease.isEmpty)

        let window = RuntimeMonitoringWindow(samples: [first, second])
        XCTAssertEqual(window.usageIncrease.ttsRequests, 1)
        // 窗内没有识别请求：是 0 次，不是「没有数据」。
        XCTAssertEqual(window.usageIncrease.asrRequests, 0)
        XCTAssertEqual(window.usageIncrease.ttsAudioSeconds ?? 0, 7.5, accuracy: 0.000_1)
        XCTAssertEqual(window.usageIncrease.asrAudioSeconds, 0)
        XCTAssertEqual(window.usageIncrease.realtimeSessions, 1)
        // 12 次轮询发生在同一个窗口里，但它们不进 usage。
        XCTAssertEqual(window.requestIncrease, 13)
    }

    /// 服务重启会让计数器回退。那是无数据，不是 0——首屏不能把「刚重启」讲成
    /// 「这段时间什么都没做」。
    func testUsageIncreaseReportsNoDataWhenCountersRollBack() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(tts: Double, at offset: TimeInterval) -> RuntimeMetricsSample {
            RuntimeMetricsSampler.makeSample(
                from: RuntimeMetricsSnapshot(
                    counters: [
                        "speechrail_http_requests_total{endpoint=\"/v1/audio/speech\",status=\"200\"}": tts,
                    ]
                ),
                capturedAt: start.addingTimeInterval(offset)
            )
        }
        let window = RuntimeMonitoringWindow(
            samples: [sample(tts: 9, at: 0), sample(tts: 0, at: 5)]
        )

        XCTAssertNil(window.usageIncrease.ttsRequests)
        // 5xx 与它是两条序列：这期间没有失败过（序列不存在），所以是 0 次。
        XCTAssertEqual(window.errorIncrease, 0)
    }

    /// 没有失败过时，`status="5xx"` 的序列根本不存在——那是 0 次，不是「读不到」；
    /// 中途才出现 5xx（first 缺、last 有）也按 0 起步算增量。
    func testErrorIncreaseTreatsMissingFiveHundredSeriesAsZero() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(errors: Double?, at offset: TimeInterval) -> RuntimeMetricsSample {
            RuntimeMetricsSample(
                capturedAt: start.addingTimeInterval(offset),
                activeRequests: 0,
                pendingRequests: 0,
                requestCount: 10 + offset,
                requestErrors: errors,
                queueRejections: nil,
                asrLatencySeconds: nil,
                ttsLatencySeconds: nil
            )
        }

        let noFailures = RuntimeMonitoringWindow(
            samples: [sample(errors: nil, at: 0), sample(errors: nil, at: 5)]
        )
        XCTAssertEqual(noFailures.errorIncrease, 0)
        XCTAssertEqual(noFailures.queueRejectionIncrease, 0)

        let appeared = RuntimeMonitoringWindow(
            samples: [sample(errors: nil, at: 0), sample(errors: 2, at: 5)]
        )
        XCTAssertEqual(appeared.errorIncrease, 2)

        // 单点窗口仍然是「还没有窗口」，不是 0。
        XCTAssertNil(RuntimeMonitoringWindow(samples: [sample(errors: nil, at: 0)]).errorIncrease)
    }

    /// 指标原文是排障时要用的，所以只在展示层翻译，认不出的名字原样保留。
    func testHistogramPresentationTranslatesKnownMetricsAndKeepsUnknownNames() {
        XCTAssertEqual(
            RuntimeHistogramPresentation.title(forMetric: "speechrail_tts_inference_duration_seconds"),
            "语音合成耗时"
        )
        XCTAssertEqual(
            RuntimeHistogramPresentation.unit(forMetric: "speechrail_tts_inference_duration_seconds"),
            "ms"
        )
        // 接口响应时间也是耗时，同样按毫秒读。
        XCTAssertEqual(
            RuntimeHistogramPresentation.unit(forMetric: "speechrail_http_request_duration_seconds"),
            "ms"
        )
        // 倍率是比值，没有单位。
        XCTAssertEqual(RuntimeHistogramPresentation.unit(forMetric: "speechrail_asr_rtf"), "")
        XCTAssertEqual(
            RuntimeHistogramPresentation.labelSummary("{voice_class=\"system\"}"),
            "系统音色"
        )
        XCTAssertEqual(
            RuntimeHistogramPresentation.labelSummary("{endpoint=\"/health\",method=\"GET\"}"),
            "/health"
        )
        XCTAssertEqual(
            RuntimeHistogramPresentation.title(forMetric: "speechrail_unknown_seconds"),
            "speechrail_unknown_seconds"
        )
        XCTAssertEqual(
            RuntimeHistogramPresentation.formattedAverage(0.4126, unit: "ms"),
            "413 ms"
        )
    }

    /// 耗时按毫秒报（2026-09-17 用户指令「时间单位改 ms」）：入参是秒域的原始值，
    /// 1 ms 及以上取整、毫秒以下保留两位，绝不把真实的亚毫秒耗时写成 `0 ms`。
    func testLatencyPresentationReportsMilliseconds() {
        XCTAssertEqual(RuntimeLatencyPresentation.text(seconds: 0.4126), "413 ms")
        XCTAssertEqual(RuntimeLatencyPresentation.text(seconds: 0.001), "1 ms")
        XCTAssertEqual(RuntimeLatencyPresentation.text(seconds: 0.0004), "0.40 ms")
        XCTAssertEqual(RuntimeLatencyPresentation.text(seconds: 0), "0 ms")
        XCTAssertEqual(
            RuntimeLatencyPresentation.milliseconds(fromSeconds: 0.064),
            64,
            accuracy: 0.000_001
        )
        XCTAssertEqual(RuntimeLatencyPresentation.unit, "ms")
        // 无障碍口径说「毫秒」：VoiceOver 把 `ms` 逐字母念出来不是中文页面的读法。
        XCTAssertEqual(RuntimeLatencyPresentation.spokenUnit, "毫秒")
        XCTAssertEqual(RuntimeLatencyPresentation.spokenText(seconds: 0.064), "64 毫秒")
        XCTAssertEqual(RuntimeHistogramPresentation.spokenAverage(0.064, unit: "ms"), "64 毫秒")
        // 倍率是比值：没有单位，两种口径都给同一个数。
        XCTAssertEqual(RuntimeHistogramPresentation.spokenAverage(2.5, unit: ""), "2.500")
    }

    func testProfileSummaryAcceptsPayloadWithoutDiarization() throws {
        let data = Data(
            #"{"id":"quality","asr":"asr","tts":"tts","aligner":null,"download_bytes":10}"#
                .utf8
        )

        let decoded = try ControlWireCodec.decode(ProfileSummary.self, from: data)

        XCTAssertEqual(decoded.id, .quality)
        XCTAssertFalse(decoded.diarization)
    }

    func testProfileApplyArgumentsAreFixedAndPreserveHomeAsOneArgument() {
        let home = URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        let arguments = ManagedCommand.profileApply(.quick(.quality)).arguments(appHome: home)

        XCTAssertEqual(
            arguments,
            [
                "-m", "speechrail", "profile", "apply", "--asr-spec", "quality",
                "--tts-spec", "quality", "--yes", "--app-home", "/tmp/SpeechRail Test Home",
                "--json",
            ]
        )
        XCTAssertFalse(arguments.joined(separator: " ").contains("sh -c"))
    }

    func testModelPrepareArgumentsUseTheLockedCommandAndRequireNoShell() {
        let home = URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        let arguments = ManagedCommand.modelPrepare(.quick(.quality)).arguments(appHome: home)

        XCTAssertEqual(
            arguments,
            [
                "-m", "speechrail", "model", "prepare", "--asr-spec", "quality",
                "--tts-spec", "quality", "--yes", "--app-home", "/tmp/SpeechRail Test Home",
                "--json",
            ]
        )
        XCTAssertFalse(arguments.contains("--url"))
    }

    /// 管理界面允许 ASR / TTS 分别选档；混合组合必须把两项各自原样转发，
    /// 不能被折叠成其中一项的「快捷档位」。
    func testProfileApplyArgumentsForwardMixedAsrAndTtsSpecs() {
        let home = URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        let arguments = ManagedCommand
            .profileApply(SpecSelection(asrSpec: .quality, ttsSpec: .fast))
            .arguments(appHome: home)

        XCTAssertEqual(
            arguments,
            [
                "-m", "speechrail", "profile", "apply", "--asr-spec", "quality",
                "--tts-spec", "fast", "--yes", "--app-home", "/tmp/SpeechRail Test Home",
                "--json",
            ]
        )
    }

    func testModelPrepareArgumentsForwardMixedAsrAndTtsSpecs() {
        let home = URL(fileURLWithPath: "/tmp/SpeechRail Test Home", isDirectory: true)
        let arguments = ManagedCommand
            .modelPrepare(SpecSelection(asrSpec: .fast, ttsSpec: .reference))
            .arguments(appHome: home)

        XCTAssertEqual(
            arguments,
            [
                "-m", "speechrail", "model", "prepare", "--asr-spec", "fast",
                "--tts-spec", "reference", "--yes", "--app-home", "/tmp/SpeechRail Test Home",
                "--json",
            ]
        )
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

/// 服务落盘历史（`state/metrics-rollup`）的读取与聚合。
///
/// 这些用例直接写临时目录里的 `*.jsonl`，因为要验证的正是「文件读过来之后口径对不对」：
/// 加权平均按样本量、空档与重启如实计数、坏行被跳过而不是被当成 0。
final class MetricsHistoryTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    func testLoaderAggregatesIncrementsAndWeightedLatency() throws {
        let rows = [
            rollupRow(
                start: "2026-09-16T10:00:00.000Z",
                end: "2026-09-16T10:01:00.000Z",
                pid: 100,
                tts: 1,
                asr: 0,
                ttsAudio: 3.5,
                asrAudio: 0,
                ttsLatency: (count: 1, averageMilliseconds: 1_000, p95Milliseconds: 1_200),
                footprint: 6_000_000_000,
                activePeak: 1
            ),
            rollupRow(
                start: "2026-09-16T10:01:00.000Z",
                end: "2026-09-16T10:02:00.000Z",
                pid: 100,
                tts: 0,
                asr: 2,
                ttsAudio: 0,
                asrAudio: 8,
                asrLatency: (count: 9, averageMilliseconds: 2_000, p95Milliseconds: 2_400),
                footprint: 5_000_000_000,
                activePeak: 2
            ),
        ]
        try write(rows.joined(separator: "\n"), named: "2026-09-16.jsonl")

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T10:30:00Z"))
        let history = MetricsHistoryLoader.load(
            directory: workspace,
            now: now,
            windowSeconds: 3_600
        )

        XCTAssertTrue(history.directoryExists)
        XCTAssertEqual(history.recordCount, 2)
        XCTAssertEqual(history.skippedLines, 0)
        XCTAssertEqual(history.totals.ttsRequests, 1)
        XCTAssertEqual(history.totals.asrRequests, 2)
        XCTAssertEqual(history.totals.ttsAudioSeconds, 3.5, accuracy: 0.000_1)
        XCTAssertEqual(history.totals.asrAudioSeconds, 8, accuracy: 0.000_1)
        // 只有一行有时延样本时按样本量加权：(2000×9)/9 = 2000ms。
        XCTAssertEqual(history.totals.asrSeconds ?? 0, 2.0, accuracy: 0.000_1)
        XCTAssertEqual(history.totals.ttsSeconds ?? 0, 1.0, accuracy: 0.000_1)
        // p95 取跨度内最大值，而不是把两个 p95 平均。
        XCTAssertEqual(history.totals.asrP95Seconds ?? 0, 2.4, accuracy: 0.000_1)
        // 内存峰值取完整读数里的最大，缩容不会被记成峰值。
        XCTAssertEqual(history.totals.memoryPeakBytes ?? 0, 6_000_000_000)
        XCTAssertEqual(history.totals.activePeak, 2)
        XCTAssertEqual(history.coveredSeconds, 120, accuracy: 0.000_1)
        XCTAssertEqual(history.serviceVersions, ["2.6.5"])
        // 1 小时跨度下每 60 秒一个桶，两行各成一个点。
        XCTAssertEqual(history.bucketSeconds, 60)
        XCTAssertEqual(history.points.count, 2)
        XCTAssertEqual(history.points.first?.ttsRequests, 1)
        XCTAssertEqual(history.points.last?.asrRequests, 2)
    }

    func testLoaderWeightsLatencyByObservationsInsteadOfAveragingAverages() throws {
        let rows = [
            rollupRow(
                start: "2026-09-16T11:00:00.000Z",
                end: "2026-09-16T11:01:00.000Z",
                pid: 100,
                tts: 1,
                asr: 1,
                asrLatency: (count: 1, averageMilliseconds: 1_000, p95Milliseconds: 1_000)
            ),
            rollupRow(
                start: "2026-09-16T11:01:00.000Z",
                end: "2026-09-16T11:02:00.000Z",
                pid: 100,
                tts: 1,
                asr: 9,
                asrLatency: (count: 9, averageMilliseconds: 2_000, p95Milliseconds: 2_000)
            ),
        ]
        try write(rows.joined(separator: "\n"), named: "2026-09-16.jsonl")

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T11:30:00Z"))
        let history = MetricsHistoryLoader.load(
            directory: workspace,
            now: now,
            windowSeconds: 3_600
        )

        // (1000×1 + 2000×9) / 10 = 1900ms；把两个区间均值直接平均会得到 1500ms 的错值。
        XCTAssertEqual(history.totals.asrSeconds ?? 0, 1.9, accuracy: 0.000_1)
    }

    func testLoaderCountsRestartsGapsAndSkipsUnreadableLines() throws {
        let rows = [
            rollupRow(
                start: "2026-09-16T12:00:00.000Z",
                end: "2026-09-16T12:01:00.000Z",
                pid: 100
            ),
            // 同一进程里的空档：上一行结束到这一行开始差了 10 分钟。
            rollupRow(
                start: "2026-09-16T12:11:00.000Z",
                end: "2026-09-16T12:12:00.000Z",
                pid: 100
            ),
            // 换进程：这是服务重启，不是空档。
            rollupRow(
                start: "2026-09-16T12:12:00.000Z",
                end: "2026-09-16T12:13:00.000Z",
                pid: 200
            ),
            "{\"schema_version\":1,\"kind\":\"metrics_rollup\"",
            "",
        ]
        try write(rows.joined(separator: "\n"), named: "2026-09-16.jsonl")

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T12:30:00Z"))
        let history = MetricsHistoryLoader.load(
            directory: workspace,
            now: now,
            windowSeconds: 3_600
        )

        XCTAssertEqual(history.recordCount, 3)
        XCTAssertEqual(history.skippedLines, 1)
        XCTAssertEqual(history.gaps, 1)
        XCTAssertEqual(history.restarts, 1)
    }

    func testLoaderReportsMissingDirectoryInsteadOfZeroData() throws {
        let missing = workspace.appendingPathComponent("not-created", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        let history = MetricsHistoryLoader.load(
            directory: missing,
            now: now,
            windowSeconds: 86_400
        )

        XCTAssertFalse(history.directoryExists)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.directoryPath, missing.path)
        XCTAssertNil(history.totals.asrSeconds)
    }

    func testLoaderIgnoresRecordsOutsideTheWindow() throws {
        let rows = [
            rollupRow(
                start: "2026-09-15T10:00:00.000Z",
                end: "2026-09-15T10:01:00.000Z",
                pid: 100,
                tts: 5
            ),
            rollupRow(
                start: "2026-09-16T10:00:00.000Z",
                end: "2026-09-16T10:01:00.000Z",
                pid: 100,
                tts: 1
            ),
        ]
        // 前一天的文件里只有一条记录，用来验证「窗口外的行不会被算进来」。
        try write(rows[0], named: "2026-09-15.jsonl")
        try write(rows[1], named: "2026-09-16.jsonl")

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T10:30:00Z"))
        let history = MetricsHistoryLoader.load(
            directory: workspace,
            now: now,
            windowSeconds: 3_600
        )

        XCTAssertEqual(history.recordCount, 1)
        XCTAssertEqual(history.totals.ttsRequests, 1)
    }

    func testBucketSecondsLadderKeepsAboutSixtyPoints() {
        XCTAssertEqual(MetricsHistoryLoader.bucketSeconds(forWindowSeconds: 3_600), 60)
        XCTAssertEqual(MetricsHistoryLoader.bucketSeconds(forWindowSeconds: 86_400), 1_800)
        XCTAssertEqual(MetricsHistoryLoader.bucketSeconds(forWindowSeconds: 604_800), 10_800)
        XCTAssertEqual(MetricsHistoryLoader.bucketSeconds(forWindowSeconds: 2_592_000), 43_200)
        for window in [3_600.0, 86_400, 604_800, 2_592_000] {
            let buckets = window / MetricsHistoryLoader.bucketSeconds(forWindowSeconds: window)
            XCTAssertLessThanOrEqual(buckets, 60)
            XCTAssertGreaterThan(buckets, 20)
        }
    }

    func testObservabilityLocationHonoursServiceConfiguredDirectories() throws {
        let appHome = workspace.appendingPathComponent("app-home", isDirectory: true)
        let configDirectory = appHome.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        // 服务端设置文件里的覆盖值必须被 App 认出来，否则 App 会去看一个不存在的目录。
        let envFile = """
        # SpeechRail settings
        SPEECHRAIL_METRICS_ROLLUP_DIR="~/SpeechRailTest/rollup"
        SPEECHRAIL_LOG_DIR=/tmp/speechrail-test-logs
        """
        try envFile.write(to: configDirectory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let location = ObservabilityLocation.resolve(environment: ["SPEECHRAIL_APP_HOME": appHome.path])

        XCTAssertEqual(location.appHome, appHome)
        XCTAssertEqual(
            location.historyDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("SpeechRailTest/rollup").path
        )
        XCTAssertEqual(location.logDirectory.path, "/tmp/speechrail-test-logs")
    }

    func testObservabilityLocationFallsBackToServiceDefaults() {
        let appHome = workspace.appendingPathComponent("default-home", isDirectory: true)

        let location = ObservabilityLocation.resolve(
            environment: ["SPEECHRAIL_APP_HOME": appHome.path]
        )

        XCTAssertEqual(
            location.historyDirectory.path,
            appHome.appendingPathComponent("state/metrics-rollup").path
        )
        XCTAssertEqual(
            location.logDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/SpeechRail").path
        )
    }

    // MARK: - 夹具

    private func write(_ contents: String, named name: String) throws {
        try contents.write(
            to: workspace.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func rollupRow(
        start: String,
        end: String,
        pid: Int,
        tts: Double = 0,
        asr: Double = 0,
        ttsAudio: Double = 0,
        asrAudio: Double = 0,
        ttsLatency: (count: Double, averageMilliseconds: Double, p95Milliseconds: Double)? = nil,
        asrLatency: (count: Double, averageMilliseconds: Double, p95Milliseconds: Double)? = nil,
        footprint: Double? = nil,
        activePeak: Double = 0
    ) -> String {
        let memory = footprint.map {
            "{\"physical_footprint_bytes\":\(Int($0)),\"footprint_complete\":true,\"footprint_process_count\":4}"
        } ?? "{\"physical_footprint_bytes\":null,\"footprint_complete\":false,\"footprint_process_count\":5}"
        return """
        {"schema_version":1,"kind":"metrics_rollup","service_version":"2.6.5","profile":"quality",\
        "pid":\(pid),"interval_start":"\(start)","interval_end":"\(end)","interval_seconds":60.0,\
        "requests":{"http_total":10,"speech_total":3,"tts":\(tts),"asr":\(asr),"failed":0,"client_errors":0},\
        "audio_seconds":{"tts":\(ttsAudio),"asr":\(asrAudio)},\
        "latency_ms":{"tts":\(latencyEntry(ttsLatency)),"asr":\(latencyEntry(asrLatency))},\
        "capacity":{"queue_rejections":0,"active":0,"pending":0,"active_peak":\(activePeak),"pending_peak":0,"total_capacity":4},\
        "memory":\(memory),"workers":{"states":{"asr":"warm"},"evictions":0}}
        """
    }

    private func latencyEntry(
        _ entry: (count: Double, averageMilliseconds: Double, p95Milliseconds: Double)?
    ) -> String {
        guard let entry else { return "null" }
        return """
        {"count":\(entry.count),"avg":\(entry.averageMilliseconds),"p50":\(entry.averageMilliseconds),\
        "p95":\(entry.p95Milliseconds)}
        """
    }
}
