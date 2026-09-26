import XCTest
#if SWIFT_PACKAGE
import SpeechRailAppSupport
#endif
@testable import SpeechRailControlKit

final class ServiceContractTests: XCTestCase {
    func testCapabilityPresentationSeparatesCheckingFromUnavailable() {
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: nil,
                discoveryState: .loading,
                supportedByProfile: true
            ),
            .checking
        )
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: nil,
                discoveryState: .unauthorized,
                supportedByProfile: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: nil,
                discoveryState: .failed,
                supportedByProfile: true
            ),
            .unavailable
        )
    }

    func testLoadedCapabilitySnapshotDoesNotLookLikeAReadFailureWhenUndeclared() {
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: nil,
                discoveryState: .loaded,
                supportedByProfile: true
            ),
            .undeclared
        )
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: nil,
                discoveryState: .loaded,
                supportedByProfile: false
            ),
            .unsupported
        )
    }

    func testCapabilityDiscoveryCanRetryAfterRecoverableStates() {
        XCTAssertTrue(CapabilityDiscoveryState.idle.shouldRetryOnRefresh)
        XCTAssertTrue(CapabilityDiscoveryState.unauthorized.shouldRetryOnRefresh)
        XCTAssertTrue(CapabilityDiscoveryState.notReady.shouldRetryOnRefresh)
        XCTAssertTrue(CapabilityDiscoveryState.invalidContract.shouldRetryOnRefresh)
        XCTAssertTrue(CapabilityDiscoveryState.failed.shouldRetryOnRefresh)

        XCTAssertFalse(CapabilityDiscoveryState.loading.shouldRetryOnRefresh)
        XCTAssertFalse(CapabilityDiscoveryState.loaded.shouldRetryOnRefresh)
        XCTAssertFalse(CapabilityDiscoveryState.notSupported.shouldRetryOnRefresh)
    }

    func testRowActionSymbolsUseExplicitPlaybackAndActionNames() {
        XCTAssertEqual(SpeechRailDesignTokens.Icon.Symbol.play.rawValue, "play.fill")
        XCTAssertEqual(SpeechRailDesignTokens.Icon.Symbol.stop.rawValue, "stop.fill")
        XCTAssertEqual(SpeechRailDesignTokens.Icon.Symbol.edit.rawValue, "pencil")
        XCTAssertEqual(SpeechRailDesignTokens.Icon.Symbol.export.rawValue, "square.and.arrow.down")
        XCTAssertEqual(SpeechRailDesignTokens.Icon.Symbol.more.rawValue, "ellipsis")
    }

    func testCapabilityPresentationKeepsDeclaredAndProfileVerdicts() {
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: true,
                discoveryState: .loaded,
                supportedByProfile: false
            ),
            .ready
        )
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: false,
                discoveryState: .loaded,
                supportedByProfile: true
            ),
            .notReady
        )
        XCTAssertEqual(
            ServiceCapabilityPresentation.resolve(
                declared: false,
                discoveryState: .loaded,
                supportedByProfile: false
            ),
            .unsupported
        )
    }

    func testEffectiveSnapshotKeepsAtomicIdentityAndUnknownAvailabilityReason() throws {
        let data = Data("""
        {
          "schema_version": "effective_capabilities_v1",
          "service_instance_epoch": "epoch-1",
          "catalog_revision": "catalog-7",
          "snapshot_id": "snap-9",
          "profile": "quality",
          "models": {},
          "voices": [{
            "id": "voice_demo",
            "name": "Demo",
            "mode": "base",
            "available": false,
            "availability_reason": "future_reason",
            "variant": null,
            "voice_revision": null,
            "voice_identity_assurance": "legacy",
            "model": {
              "assurance": "unknown",
              "runtime_revision": null
            },
            "descriptors": {
              "voice_mode": "instruction",
              "locales": [],
              "style_tags": [],
              "pitch_band": "unknown",
              "timbre_family": "unknown",
              "baseline_pace": "unknown",
              "source_type": "instruction_profile",
              "metadata_method": "declared_only"
            },
            "operations": {}
          }],
          "operations": {},
          "guarantees": {}
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(EffectiveCapabilitySnapshot.self, from: data)

        XCTAssertEqual(snapshot.schemaVersion, "effective_capabilities_v1")
        XCTAssertEqual(snapshot.snapshotID, "snap-9")
        XCTAssertEqual(snapshot.voices[0].aliases, [])
        XCTAssertEqual(snapshot.voices[0].availabilityReason.rawValue, "future_reason")
    }

    func testMissingSnapshotIDIsInvalidContract() {
        let data = Data(
            """
            {
                "schema_version": "effective_capabilities_v1",
                "service_instance_epoch": "epoch-1",
                "catalog_revision": "catalog-1",
                "profile": "quality",
                "models": {},
                "voices": [],
                "operations": {},
                "guarantees": {}
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(EffectiveCapabilitySnapshot.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? ServiceContractDecodingError,
                .missingRequiredField("snapshot_id")
            )
        }
    }

    func testErrorPreservesStatusAndRequestID() {
        let error = ServiceAPIClientError.http(
            statusCode: 409,
            code: "voice_revision_mismatch",
            message: "stale revision",
            requestID: "req-1",
            retryable: false
        )

        XCTAssertEqual(error.statusCode, 409)
        XCTAssertEqual(error.requestID, "req-1")
        XCTAssertFalse(error.isRetryable)
    }

    func testCapabilityStoreRetainsSnapshotAfterNotModified() {
        let snapshot = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "catalog-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: [:],
            voices: [],
            operations: [:],
            guarantees: [:]
        )
        var store = CapabilitySnapshotStore.loaded(snapshot: snapshot, etag: "\"snap-1\"")
        let token = store.beginRefresh()
        store.apply(
            .notModified(
                metadata: ServiceResponseMetadata(
                    statusCode: 304,
                    headers: ["ETag": "\"snap-1\""],
                    etag: "\"snap-1\""
                )
            ),
            requestToken: token
        )

        XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")
        XCTAssertEqual(store.state, .loaded)
    }

    func testCapabilityStoreRetainsSnapshotWhileRefreshIsLoading() {
        let snapshot = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "catalog-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: [:],
            voices: [],
            operations: [:],
            guarantees: [:]
        )
        var store = CapabilitySnapshotStore.loaded(snapshot: snapshot, etag: "\"snap-1\"")
        _ = store.beginRefresh()

        XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")
        XCTAssertEqual(store.state, .loading)
    }

    func testUnauthorizedDoesNotBecomeLegacySuccess() {
        let snapshot = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "catalog-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: [:],
            voices: [],
            operations: [:],
            guarantees: [:]
        )
        var store = CapabilitySnapshotStore.loaded(snapshot: snapshot, etag: "\"snap-1\"")
        let token = store.beginRefresh()

        store.markUnauthorized(
            .http(
                statusCode: 401,
                code: "invalid_api_key",
                message: "redacted",
                requestID: "req-7",
                retryable: false
            ),
            requestToken: token
        )

        XCTAssertEqual(store.state, .unauthorized)
        XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")
    }

    func testCapabilityStoreIgnoresStaleGeneration() {
        let first = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "catalog-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: [:],
            voices: [],
            operations: [:],
            guarantees: [:]
        )
        let second = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "catalog-2",
            snapshotID: "snap-2",
            profile: "quality",
            models: [:],
            voices: [],
            operations: [:],
            guarantees: [:]
        )
        var store = CapabilitySnapshotStore.loaded(snapshot: first, etag: "\"snap-1\"")
        let staleToken = store.beginRefresh()
        let currentToken = store.beginRefresh()

        store.apply(
            ServiceConditionalResponse(
                value: second,
                metadata: ServiceResponseMetadata(statusCode: 200, etag: "\"snap-2\"")
            ),
            requestToken: staleToken
        )
        XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")

        store.apply(
            ServiceConditionalResponse(
                value: second,
                metadata: ServiceResponseMetadata(statusCode: 200, etag: "\"snap-2\"")
            ),
            requestToken: currentToken
        )
        XCTAssertEqual(store.snapshot?.snapshotID, "snap-2")
    }

    func testErrorClassifierSeparatesConflictAndNotReady() {
        XCTAssertEqual(
            ServiceErrorClassifier.category(
                for: .http(
                    statusCode: 409,
                    code: "voice_revision_mismatch",
                    message: "redacted",
                    requestID: "req-1",
                    retryable: false
                )
            ),
            .conflict
        )
        XCTAssertEqual(
            ServiceErrorClassifier.category(
                for: .http(
                    statusCode: 503,
                    code: "backend_not_ready",
                    message: "redacted",
                    requestID: "req-2",
                    retryable: true
                )
            ),
            .notReady
        )
        XCTAssertEqual(
            ServiceErrorClassifier.category(
                for: .http(
                    statusCode: 409,
                    code: "voice_revoked",
                    message: "redacted",
                    requestID: "req-3",
                    retryable: false
                )
            ),
            .voiceRevoked
        )
    }

    func testVoiceRevisionDecodesLegacyMutationAndRevisionListShapes() throws {
        let mutation = try JSONDecoder().decode(
            VoiceRevisionMutation.self,
            from: Data(#"{"id":"voice_demo","voice_revision":"vr_0123456789abcdef0123456789abcdef","mode":"clone","revoked":false}"#.utf8)
        )
        XCTAssertEqual(mutation.id, "voice_demo")
        XCTAssertEqual(mutation.revision, "vr_0123456789abcdef0123456789abcdef")

        let revision = try JSONDecoder().decode(
            VoiceRevision.self,
            from: Data(#"{"revision":"vr_0123456789abcdef0123456789abcdef","current":true,"created_at":1.5,"revoked":false}"#.utf8)
        )
        XCTAssertEqual(revision.id, revision.revision)
        XCTAssertEqual(revision.active, true)
        XCTAssertEqual(revision.createdAt, 1.5)
    }

    func testVoicePatchEncodesOnlySuppliedExpectedRevision() throws {
        let data = try JSONEncoder().encode(
            VoicePatch(
                name: "Updated",
                instruction: nil,
                seed: nil,
                expectedRevision: "vr_0123456789abcdef0123456789abcdef"
            )
        )

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, "Updated")
        XCTAssertEqual(
            object?["expected_revision"] as? String,
            "vr_0123456789abcdef0123456789abcdef"
        )
        XCTAssertNil(object?["instruction"])
        XCTAssertNil(object?["seed"])
    }

    func testPronunciationSetUpdateUsesContractEntryArrayAndNullExpectedRevision() throws {
        let data = try JSONEncoder().encode(
            PronunciationSetUpdate(
                id: "zh_demo",
                entries: [
                    PronunciationEntry(
                        id: "sr",
                        surface: "SpeechRail",
                        spoken: "Speech Rail"
                    ),
                ]
            )
        )

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["id"])
        XCTAssertTrue(object?.keys.contains("expected_revision") == true)
        XCTAssertEqual((object?["entries"] as? [[String: Any]])?.first?["spoken"] as? String, "Speech Rail")
    }

    func testAudioResponseAcceptsNonWavAndCarriesReceiptHeaders() throws {
        let response = try ServiceResponseDecoder.decodeAudio(
            Data([0x01, 0x02]),
            statusCode: 200,
            headers: [
                "Content-Type": "audio/mpeg",
                "SpeechRail-Receipt-Id": "rr_0123456789abcdef0123456789abcdef",
                "SpeechRail-Timing-Id": "tm_0123456789abcdef0123456789abcdef",
            ]
        )

        XCTAssertEqual(response.contentType, "audio/mpeg")
        XCTAssertEqual(response.receiptID, "rr_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(response.timingID, "tm_0123456789abcdef0123456789abcdef")
    }

    func testSpeechRequestEncodesObjectVoiceAndResponseFormat() throws {
        let request = SpeechRequest(
            input: "hello",
            voice: .id("voice_demo"),
            model: "tts-1.7b-base",
            responseFormat: "mp3",
            language: "en",
            speed: 1.0
        )

        let body = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual((object?["voice"] as? [String: String])?["id"], "voice_demo")
        XCTAssertEqual(object?["response_format"] as? String, "mp3")
    }

    func testJobDecodingKeepsRequiredNullFieldsAndOptionalMetadata() throws {
        let job = try JSONDecoder().decode(
            Job.self,
            from: Data(#"{"id":"job_0123456789abcdef0123456789abcdef","kind":"speech","state":"queued","error_code":null,"result_ref":null,"params":{"purpose":"interactive"}}"#.utf8)
        )

        XCTAssertEqual(job.id, "job_0123456789abcdef0123456789abcdef")
        XCTAssertNil(job.resultReference)
        XCTAssertEqual(job.params?["purpose"], JSONValue(.string("interactive")))
    }

    func testReceiptMissingRequiredFieldIsInvalidContract() throws {
        let data = Data(#"{"receipt_id":"rr_0123456789abcdef0123456789abcdef","request_id":"req-1","status":"completed","voice":{},"model":{},"audio":{},"created_at":1,"completed_at":2}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(RenderReceipt.self, from: data)) { error in
            XCTAssertEqual(
                error as? ServiceContractDecodingError,
                .missingRequiredField("error_code")
            )
        }
    }

    func testRequestBuilderAddsBearerAndConditionalHeaders() throws {
        let request = try ServiceRequestBuilder(
            baseURL: URL(string: "http://127.0.0.1:8201")!,
            apiKey: "secret"
        ).make(
            path: "/v1/speechrail/capabilities",
            method: "GET",
            query: [],
            headers: ["If-None-Match": "\"snap-1\""],
            body: nil
        )

        XCTAssertEqual(request.url?.path, "/v1/speechrail/capabilities")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"snap-1\"")
    }

    func testManagedCredentialTakesPrecedenceOverAmbientEnvironment() {
        XCTAssertEqual(
            ServiceCredentialPolicy.preferredKey(
                environmentKey: "stale-environment-key",
                managedKey: "managed-service-key"
            ),
            "managed-service-key"
        )
        XCTAssertEqual(
            ServiceCredentialPolicy.preferredKey(
                environmentKey: "environment-key",
                managedKey: nil
            ),
            "environment-key"
        )
        XCTAssertNil(
            ServiceCredentialPolicy.preferredKey(
                environmentKey: "",
                managedKey: ""
            )
        )
    }

    func test304WithoutCachedValueThrowsCacheMiss() {
        XCTAssertThrowsError(
            try ServiceResponseDecoder.decode(
                Data(),
                statusCode: 304,
                headers: ["ETag": "\"snap-2\""],
                cachedValue: nil as EffectiveCapabilitySnapshot?
            )
        ) { error in
            XCTAssertEqual(error as? ServiceAPIClientError, .notModifiedWithoutCache)
        }
    }

    func testCapabilityRevisionSelectorMatchesVoiceIDAndAlias() {
        let snapshot = makeRevisionSnapshot(
            voice: SafeVoiceEntry(
                id: "voice-1",
                name: "Serena",
                aliases: ["serena"],
                mode: "design",
                available: true,
                availabilityReason: .available,
                voiceRevision: "vr_001",
                voiceIdentityAssurance: .contentAddressed,
                model: ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    catalogRevision: "model-cat-1"
                ),
                descriptors: Self.testDescriptor,
                operations: [
                    "http_speech": JSONValue(.string("supported")),
                    "realtime_speech": JSONValue(.string("supported")),
                ]
            )
        )

        XCTAssertEqual(
            SpeechRailCapabilityRevisionSelector.voiceRevision(
                for: "voice-1",
                in: snapshot,
                operation: "realtime_speech"
            ),
            "vr_001"
        )
        XCTAssertEqual(
            SpeechRailCapabilityRevisionSelector.voiceRevision(
                for: "serena",
                in: snapshot,
                operation: "http_speech"
            ),
            "vr_001"
        )
    }

    func testCapabilityRevisionSelectorRejectsUnavailableOrUnsupportedVoices() {
        let unavailable = makeRevisionSnapshot(
            voice: SafeVoiceEntry(
                id: "voice-unavailable",
                name: "Unavailable",
                mode: "design",
                available: false,
                availabilityReason: .backendNotReady,
                voiceRevision: "vr_unavailable",
                voiceIdentityAssurance: .contentAddressed,
                model: ConfiguredModelIdentity(assurance: .configuredCatalog),
                descriptors: Self.testDescriptor,
                operations: ["realtime_speech": JSONValue(.string("supported"))]
            )
        )
        let unsupported = makeRevisionSnapshot(
            voice: SafeVoiceEntry(
                id: "voice-unsupported",
                name: "Unsupported",
                mode: "legacy",
                available: true,
                availabilityReason: .available,
                voiceRevision: "vr_unsupported",
                voiceIdentityAssurance: .contentAddressed,
                model: ConfiguredModelIdentity(assurance: .configuredCatalog),
                descriptors: Self.testDescriptor,
                operations: [:]
            )
        )

        XCTAssertNil(
            SpeechRailCapabilityRevisionSelector.voiceRevision(
                for: "voice-unavailable",
                in: unavailable,
                operation: "realtime_speech"
            )
        )
        XCTAssertNil(
            SpeechRailCapabilityRevisionSelector.voiceRevision(
                for: "voice-unsupported",
                in: unsupported,
                operation: "realtime_speech"
            )
        )
        XCTAssertNil(
            SpeechRailCapabilityRevisionSelector.voiceRevision(
                for: "missing",
                in: unsupported,
                operation: "realtime_speech"
            )
        )
    }

    func testCapabilityRevisionSelectorBuildsCreatorRequestOptions() {
        let snapshot = makeRevisionSnapshot(
            voice: SafeVoiceEntry(
                id: "voice-1",
                name: "Serena",
                mode: "design",
                available: true,
                availabilityReason: .available,
                voiceRevision: "vr_001",
                voiceIdentityAssurance: .contentAddressed,
                model: ConfiguredModelIdentity(assurance: .configuredCatalog),
                descriptors: Self.testDescriptor,
                operations: ["http_speech": JSONValue(.string("supported"))]
            )
        )

        let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "voice-1",
            fallbackVoiceRevision: "vr_detail",
            in: snapshot
        )

        XCTAssertEqual(options.expectedVoiceRevision, "vr_001")
        XCTAssertEqual(options.expectedModelRevision, "model-cat-1")
        XCTAssertEqual(options.headers["SpeechRail-Expected-Voice-Revision"], "vr_001")
        XCTAssertEqual(options.headers["SpeechRail-Expected-Model-Revision"], "model-cat-1")

        let withoutSnapshot = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "voice-1",
            fallbackVoiceRevision: "vr_detail",
            in: nil
        )
        XCTAssertNil(withoutSnapshot.expectedVoiceRevision)
        XCTAssertNil(withoutSnapshot.expectedModelRevision)
    }

    /// 真实服务载荷里 `descriptors` 是**单个对象**（`GET /v1/speechrail/voices` 与能力快照
    /// 的 `voices[]` 都是这个形状）。这条按真实形状解码，防止 App 侧再退回「数组」假设。
    func testSafeVoiceListDecodesSingleObjectDescriptors() throws {
        let decoded: ServiceConditionalResponse<SafeVoiceList> = try ServiceResponseDecoder.decode(
            Data(Self.safeVoiceListJSON(descriptors: Self.objectDescriptorsJSON).utf8),
            statusCode: 200,
            headers: ["ETag": "\"snap-1\""]
        )

        let voice = try XCTUnwrap(decoded.value?.data.first)
        XCTAssertEqual(voice.descriptors.voiceMode, "instruction")
        XCTAssertEqual(voice.descriptors.sourceType, "instruction_profile")
        XCTAssertEqual(voice.descriptors.metadataMethod, "declared_only")
        XCTAssertEqual(decoded.metadata.etag, "\"snap-1\"")
    }

    /// 契约不符必须是**契约**问题。数组形状过去被归成 `.invalidResponse`（连接类别），
    /// 界面上显示的是「读不到服务」，真实原因（服务返回的东西 App 不认识）被掩盖。
    func testArrayDescriptorsIsClassifiedAsContractNotConnectionError() {
        let data = Data(Self.safeVoiceListJSON(descriptors: "[]").utf8)

        do {
            let decoded: ServiceConditionalResponse<SafeVoiceList> = try ServiceResponseDecoder.decode(
                data,
                statusCode: 200,
                headers: [:]
            )
            XCTFail("数组形状的 descriptors 必须解码失败，实际解出 \(decoded)")
        } catch {
            XCTAssertEqual(Self.category(of: error), .invalidContract)
            // 诊断只保留编码路径与错误类别，不带载荷内容（隐私约束）。
            let described = String(describing: error)
            XCTAssertTrue(described.contains("descriptors"), described)
            XCTAssertFalse(described.contains("instruction_profile"), described)
        }
    }

    func testVoiceDesignCandidateDecodesThePublishedLifecycleProjection() throws {
        let data = Data(
            """
            {
              "id": "vd_0123456789abcdef01234567",
              "target_voice_id": "voice_design_demo",
              "name": "夜航主持",
              "language": "zh",
              "state": "publishable",
              "revision": "vr_0123456789abcdef0123456789abcdef",
              "created_at": 1,
              "updated_at": 2,
              "confirmed_at": 2,
              "published_at": null,
              "published_voice_revision": null,
              "error_code": null,
              "source_model": {
                "artifact": "tts-1.7b-design-bf16",
                "revision": "0123456789abcdef0123456789abcdef01234567"
              },
              "reference": {
                "audio_sha256": "\(String(repeating: "a", count: 64))",
                "text_sha256": "\(String(repeating: "b", count: 64))",
                "transcript_sha256": "\(String(repeating: "c", count: 64))",
                "duration_seconds": 3.2,
                "quality": null
              },
              "validations": [{
                "validation_id": "vv_0123456789abcdef01234567",
                "candidate_revision": "vr_0123456789abcdef0123456789abcdef",
                "status": "pass",
                "machine_status": "pass",
                "identity_status": "pass",
                "naturalness_status": "pass",
                "failure_codes": [],
                "capability_key": "reference.render",
                "model_artifact": "tts-1.7b-base-bf16",
                "model_catalog_revision": "0123456789abcdef0123456789abcdef01234567",
                "transcript_match": 0.99,
                "created_at": 3,
                "updated_at": 3
              }],
              "publishable": true
            }
            """.utf8
        )

        let candidate = try JSONDecoder().decode(VoiceDesignCandidate.self, from: data)

        XCTAssertEqual(candidate.id, "vd_0123456789abcdef01234567")
        XCTAssertEqual(candidate.targetVoiceID, "voice_design_demo")
        XCTAssertEqual(candidate.state, "publishable")
        XCTAssertTrue(candidate.publishable)
        XCTAssertEqual(candidate.latestValidation?.validationID, "vv_0123456789abcdef01234567")
        XCTAssertEqual(candidate.latestValidation?.identityStatus, .pass)
        XCTAssertEqual(candidate.latestValidation?.naturalnessStatus, .pass)
        XCTAssertEqual(candidate.latestValidation?.machineStatus, "pass")
    }

    /// 契约把 `pitch_band` / `timbre_family` / `baseline_pace` 固定为 `unknown`、
    /// `metadata_method` 固定为 `declared_only`：这些是声明式元数据，不是实测推断。
    private static let testDescriptor = SafeVoiceDescriptor(
        voiceMode: "instruction",
        locales: [],
        styleTags: [],
        pitchBand: "unknown",
        timbreFamily: "unknown",
        baselinePace: "unknown",
        sourceType: "instruction_profile",
        metadataMethod: "declared_only"
    )

    private static let objectDescriptorsJSON =
        #"{"voice_mode":"instruction","locales":[],"style_tags":[],"pitch_band":"unknown","timbre_family":"unknown","baseline_pace":"unknown","source_type":"instruction_profile","metadata_method":"declared_only"}"#

    private static func safeVoiceListJSON(descriptors: String) -> String {
        """
        {
          "object": "list",
          "snapshot_id": "snap-1",
          "catalog_revision": "catalog-7",
          "data": [{
            "id": "voice_demo",
            "name": "Demo",
            "mode": "instruction",
            "available": true,
            "availability_reason": "available",
            "variant": "voice_design",
            "voice_revision": null,
            "voice_identity_assurance": "legacy",
            "model": {"assurance": "configured_catalog", "catalog_revision": "catalog-7"},
            "descriptors": \(descriptors),
            "operations": {}
          }]
        }
        """
    }

    /// 与生产侧 `AppModel.applyDiscoveryFailure` 同一套归类：契约解码错误不能落进连接类别。
    private static func category(of error: any Error) -> ServiceErrorCategory {
        if let error = error as? ServiceAPIClientError {
            return ServiceErrorClassifier.category(for: error)
        }
        if error is ServiceContractDecodingError {
            return .invalidContract
        }
        return .connection
    }

    private func makeRevisionSnapshot(voice: SafeVoiceEntry) -> EffectiveCapabilitySnapshot {
        EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "catalog-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: [
                "tts": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    catalogRevision: "model-cat-1"
                )
            ],
            voices: [voice],
            operations: [:],
            guarantees: [:]
        )
    }
}
