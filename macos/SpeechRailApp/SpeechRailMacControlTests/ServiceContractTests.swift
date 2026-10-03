import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif
@testable import SpeechRailControlKit

final class ServiceContractTests: XCTestCase {
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
            speed: 1.0
        )

        let body = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual((object?["voice"] as? [String: String])?["id"], "voice_demo")
        XCTAssertEqual(object?["response_format"] as? String, "mp3")
    }

    func testSpeechRequestBodyCarriesNoSpeechrailExtension() throws {
        let request = SpeechRequest(
            input: "hello",
            voice: .name("ryan"),
            model: "speechrail/qwen3-tts",
            responseFormat: "wav",
            speed: 1.0
        )

        let body = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        // The server rejects `language` in this body, so the client must not
        // be able to encode it even by accident.
        XCTAssertNil(object?["language"])
        XCTAssertEqual(
            Set(object?.keys.map { String($0) } ?? []),
            ["model", "input", "voice", "response_format", "speed"]
        )
    }

    func testPlainOptionsSendNoSpeechrailExtensionHeaders() {
        let headers = SpeechRailRequestOptions().headers

        XCTAssertNil(headers["SpeechRail-Language"])
        XCTAssertNil(headers["SpeechRail-Validation-Policy"])
        XCTAssertTrue(headers.isEmpty)
    }

    func testLanguageAndPolicyTravelAsSpeechrailHeaders() {
        let options = SpeechRailRequestOptions(
            expectedVoiceRevision: "vr_0123456789abcdef0123456789abcdef",
            languageOverride: "en",
            validationPolicy: "require_output_pass"
        )

        let headers = options.headers

        XCTAssertEqual(headers["SpeechRail-Language"], "en")
        XCTAssertEqual(headers["SpeechRail-Validation-Policy"], "require_output_pass")
        XCTAssertEqual(headers["SpeechRail-Expected-Voice-Revision"], "vr_0123456789abcdef0123456789abcdef")
    }

    func testWithLanguageOverrideKeepsEveryOtherOption() {
        let original = SpeechRailRequestOptions(
            expectedVoiceRevision: "vr_0123456789abcdef0123456789abcdef",
            expectedModelRevision: String(repeating: "a", count: 40),
            pronunciationSet: "story@pr_0123456789abcdef0123456789abcdef",
            receiptMode: "integrity",
            timingMode: "chunk",
            purpose: "interactive",
            latencyBudgetMs: 1_500,
            validationPolicy: "require_output_pass"
        )

        let updated = original.with(languageOverride: "ja")

        XCTAssertEqual(updated.languageOverride, "ja")
        XCTAssertEqual(updated.headers["SpeechRail-Language"], "ja")
        XCTAssertEqual(updated.headers["SpeechRail-Validation-Policy"], "require_output_pass")
        // The render path rebuilds options; a derived copy must not drop fields.
        for (key, value) in original.headers where key != "SpeechRail-Language" {
            XCTAssertEqual(updated.headers[key], value, key)
        }
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

    private func decodeReceipt(_ json: String) throws -> RenderReceipt {
        try JSONDecoder().decode(RenderReceipt.self, from: Data(json.utf8))
    }

    private let partialRecipeJSON = """
    {
      "schema_version": "render_recipe_v1",
      "state": "partial",
      "missing_fields": ["model.engine_revision", "parameters.seed_policy"],
      "digest": null,
      "content": {
        "raw_text_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "acoustic_text_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "normalization_revision": "tts_norm_v1",
        "planner_revision": "tts_bounded_v1",
        "pronunciation_revision": "unused"
      },
      "voice": {"id": "narrator", "revision": "vr_x", "mode": "custom"},
      "model": {
        "role": "tts",
        "artifact": "tts-artifact",
        "artifact_revision": "cat-1",
        "engine_revision": null
      },
      "parameters": {
        "effective_speed": 1.0,
        "effective_language": "zh",
        "seed_policy": null,
        "output_format": "wav",
        "sample_rate": 24000,
        "channels": 1
      }
    }
    """

    func testReceiptProjectsTheRecipeIntoTypedFacts() throws {
        let receipt = try decodeReceipt("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-1",
          "status": "completed",
          "voice": {"id": "narrator", "revision": "vr_x"},
          "model": {},
          "audio": {"pcm_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
          "plan": {"plan_id": "plan_0123456789abcdef0123456789abcdef", "plan_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
          "recipe": \(partialRecipeJSON),
          "error_code": null,
          "created_at": 1,
          "completed_at": 2
        }
        """)

        let recipe = try XCTUnwrap(receipt.recipe)
        XCTAssertEqual(recipe.schemaVersion, "render_recipe_v1")
        XCTAssertEqual(recipe.state, .partial)
        XCTAssertEqual(
            recipe.missingFields,
            ["model.engine_revision", "parameters.seed_policy"]
        )
        XCTAssertNil(recipe.digest)
        XCTAssertEqual(recipe.voiceID, "narrator")
        XCTAssertEqual(recipe.voiceRevision, "vr_x")
        XCTAssertEqual(recipe.modelArtifact, "tts-artifact")
        XCTAssertNil(recipe.engineRevision, "没观察到就保持未知，不借用制品版本")
        XCTAssertEqual(recipe.effectiveSpeed, 1.0)
        XCTAssertEqual(recipe.sampleRate, 24_000)
        XCTAssertEqual(recipe.channels, 1)
        XCTAssertEqual(recipe.pronunciationRevision, "unused")
        XCTAssertEqual(receipt.planSHA256?.count, 64)
        XCTAssertEqual(receipt.pcmSHA256?.first, "c")
    }

    func testReceiptWithoutARecipeStaysUnknownRatherThanEmpty() throws {
        let receipt = try decodeReceipt("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-1",
          "status": "completed",
          "voice": {},
          "model": {},
          "audio": {},
          "recipe": null,
          "error_code": null,
          "created_at": 1,
          "completed_at": 2
        }
        """)

        XCTAssertNil(receipt.recipe)
        XCTAssertEqual(
            ServiceAPIClient.provenance(for: receipt),
            RenderProvenance(state: .partial, reason: "recipe_missing")
        )
    }

    func testRecipeRoundTripsThroughItsOwnEncoding() throws {
        let recipe = try JSONDecoder().decode(
            RenderRecipeSnapshot.self,
            from: Data(partialRecipeJSON.utf8)
        )

        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(RenderRecipeSnapshot.self, from: encoded)

        XCTAssertEqual(decoded, recipe, "保存进作品的配方必须能原样读回来")
    }

    func testProvenanceOnlyClaimsVerifiedForAFullRecipe() throws {
        let verified = try decodeReceipt("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-1",
          "status": "completed",
          "voice": {},
          "model": {},
          "audio": {},
          "recipe": {
            "schema_version": "render_recipe_v1",
            "state": "complete",
            "missing_fields": [],
            "digest": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
          },
          "error_code": null,
          "created_at": 1,
          "completed_at": 2
        }
        """)
        let partial = try decodeReceipt("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-1",
          "status": "completed",
          "voice": {},
          "model": {},
          "audio": {},
          "recipe": \(partialRecipeJSON),
          "error_code": null,
          "created_at": 1,
          "completed_at": 2
        }
        """)
        let stillPending = try decodeReceipt("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-1",
          "status": "pending",
          "voice": {},
          "model": {},
          "audio": {},
          "recipe": null,
          "error_code": null,
          "created_at": 1,
          "completed_at": null
        }
        """)

        XCTAssertEqual(ServiceAPIClient.provenance(for: verified).state, .verified)
        XCTAssertEqual(
            ServiceAPIClient.provenance(for: partial),
            RenderProvenance(
                state: .partial,
                reason: "recipe_incomplete_model.engine_revision,parameters.seed_policy"
            )
        )
        XCTAssertEqual(
            ServiceAPIClient.provenance(for: stillPending),
            RenderProvenance(state: .partial, reason: "receipt_status_pending")
        )
    }

    func testProvenanceDoesNotTakeTheServersSelfAssessmentAtFaceValue() throws {
        /// A payload that claims `complete` while still listing missing facts is
        /// a contract violation, not a verified render. `state` and `digest` are
        /// the server grading its own work; `missing_fields` is decoded
        /// separately, so it is the one signal that can contradict them.
        let contradictsItself = try decodeReceipt("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-1",
          "status": "completed",
          "voice": {},
          "model": {},
          "audio": {},
          "recipe": {
            "schema_version": "render_recipe_v1",
            "state": "complete",
            "missing_fields": ["model.engine_revision"],
            "digest": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
          },
          "error_code": null,
          "created_at": 1,
          "completed_at": 2
        }
        """)

        XCTAssertEqual(
            ServiceAPIClient.provenance(for: contradictsItself),
            RenderProvenance(
                state: .partial,
                reason: "recipe_incomplete_model.engine_revision"
            ),
            "配方自述完整却仍列着缺失事实时，不得显示为追溯完整"
        )
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
                model: ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "tts-base",
                    catalogRevision: "model-cat-1"
                ),
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
                model: ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "tts-base",
                    catalogRevision: "model-cat-1"
                ),
                descriptors: Self.testDescriptor,
                operations: ["http_speech": JSONValue(.string("supported"))]
            )
        )

        let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "voice-1",
            in: snapshot
        )

        XCTAssertEqual(options?.expectedVoiceRevision, "vr_001")
        XCTAssertEqual(options?.expectedModelRevision, "model-cat-1")
        XCTAssertEqual(options?.headers["SpeechRail-Expected-Voice-Revision"], "vr_001")
        XCTAssertEqual(options?.headers["SpeechRail-Expected-Model-Revision"], "model-cat-1")

        let withoutSnapshot = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "voice-1",
            in: nil
        )
        XCTAssertNil(withoutSnapshot)
    }

    func testCreatorRequestOptionsPinTheModelBoundToTheSelectedVoice() {
        let voice = SafeVoiceEntry(
            id: "clone-voice",
            name: "Clone",
            mode: "clone",
            available: true,
            availabilityReason: .available,
            voiceRevision: "vr_clone",
            voiceIdentityAssurance: .contentAddressed,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                catalogRevision: "clone-model-revision"
            ),
            descriptors: Self.testDescriptor,
            operations: ["http_speech": JSONValue(.string("supported"))]
        )
        var snapshot = makeRevisionSnapshot(voice: voice)
        snapshot = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: snapshot.serviceInstanceEpoch,
            catalogRevision: snapshot.catalogRevision,
            snapshotID: snapshot.snapshotID,
            profile: snapshot.profile,
            models: [
                "tts": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    catalogRevision: "custom-voice-model-revision"
                ),
                "tts_clone": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    catalogRevision: "clone-model-revision"
                ),
            ],
            voices: snapshot.voices,
            operations: snapshot.operations,
            guarantees: snapshot.guarantees
        )

        let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "clone-voice",
            in: snapshot
        )

        XCTAssertEqual(options?.expectedVoiceRevision, "vr_clone")
        XCTAssertEqual(options?.expectedModelRevision, "clone-model-revision")
    }

    /// 系统音色没有 voice_revision（legacy），但普通合成不需要它：只带模型版本即可。
    func testCreatorRequestOptionsAllowSystemVoiceWithoutVoiceRevision() {
        let voice = SafeVoiceEntry(
            id: "eric",
            name: "System",
            mode: "system",
            available: true,
            availabilityReason: .available,
            voiceRevision: nil,
            voiceIdentityAssurance: .legacy,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                catalogRevision: "model-cat-1"
            ),
            descriptors: Self.testDescriptor,
            operations: ["http_speech": JSONValue(.string("supported"))]
        )
        let snapshot = makeRevisionSnapshot(voice: voice)

        let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "eric",
            in: snapshot
        )

        XCTAssertNil(options?.expectedVoiceRevision)
        XCTAssertEqual(options?.expectedModelRevision, "model-cat-1")
    }

    func testCreatorRequestOptionsDoNotBorrowRevisionFromRichVoiceFallback() {
        let voice = SafeVoiceEntry(
            id: "legacy-voice",
            name: "Legacy",
            mode: "clone",
            available: true,
            availabilityReason: .available,
            voiceRevision: nil,
            voiceIdentityAssurance: .legacy,
            model: ConfiguredModelIdentity(assurance: .configuredCatalog),
            descriptors: Self.testDescriptor,
            operations: ["http_speech": JSONValue(.string("supported"))]
        )
        let snapshot = makeRevisionSnapshot(voice: voice)

        let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: "legacy-voice",
            in: snapshot
        )

        XCTAssertNil(options)
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
        XCTAssertEqual(candidate.knownState, .publishable)
        XCTAssertTrue(candidate.publishable)
        XCTAssertEqual(candidate.latestValidation?.validationID, "vv_0123456789abcdef01234567")
        XCTAssertEqual(candidate.latestValidation?.identityStatus, .pass)
        XCTAssertEqual(candidate.latestValidation?.naturalnessStatus, .pass)
        XCTAssertEqual(candidate.latestValidation?.machineStatus, "pass")
        XCTAssertEqual(candidate.latestValidation?.modelArtifact, "tts-1.7b-base-bf16")
        XCTAssertEqual(
            candidate.latestValidation?.modelCatalogRevision,
            "0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertEqual(candidate.latestValidation?.createdAt, 3)
        XCTAssertEqual(candidate.latestValidation?.updatedAt, 3)
    }

    #if SWIFT_PACKAGE
    func testVoiceUpdateUsesOnlyTheCurrentCASRouteAndRevision() async throws {
        let client = makeHTTPClient(
            statusCode: 200,
            body: Data(
                #"{"id":"voice_demo","voice_revision":"vr_next","mode":"custom_voice","revoked":false}"#.utf8
            )
        )

        _ = try await client.updateVoice(
            id: "voice_demo",
            name: "Updated",
            instruction: nil,
            seed: nil,
            expectedRevision: "vr_current"
        )

        let request = try XCTUnwrap(ServiceAPIURLProtocolStub.state.recordedRequests().first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/v1/speechrail/voices/voice_demo")
        let body = try XCTUnwrap(
            ServiceAPIURLProtocolStub.state.recordedBodies().first ?? nil
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["expected_revision"] as? String, "vr_current")
        XCTAssertNil(object["expectedRevision"])
        XCTAssertEqual(ServiceAPIURLProtocolStub.state.recordedRequests().count, 1)
    }

    func testVoiceQuality404DoesNotFallBackToTheLegacyRoute() async throws {
        let client = makeHTTPClient(
            statusCode: 404,
            body: Data(
                #"{"error":{"code":"not_found","message":"missing","request_id":"req-test","retryable":false}}"#.utf8
            )
        )

        do {
            _ = try await client.runVoiceQuality(id: "voice_demo")
            XCTFail("A current-route 404 must remain visible")
        } catch let error as ServiceAPIClientError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.code, "not_found")
        }

        let requests = ServiceAPIURLProtocolStub.state.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].url?.path,
            "/v1/speechrail/voices/voice_demo/quality-runs"
        )
    }

    func testCloneIdempotencyStatusUsesTheStableKeyHeader() async throws {
        let client = makeHTTPClient(
            statusCode: 200,
            body: Data(#"{"state":"completed","result_id":"voice_demo"}"#.utf8)
        )

        let status = try await client.fetchCloneIdempotencyStatus(
            idempotencyKey: "stable-key"
        )

        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(status.resultID, "voice_demo")
        let request = try XCTUnwrap(ServiceAPIURLProtocolStub.state.recordedRequests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.path,
            "/v1/speechrail/voices/clone/idempotency"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "stable-key"
        )
    }

    func testCurrentCandidateAndPronunciationListSurfacesUseContractRoutes() async throws {
        let candidate = VoiceDesignCandidate(
            id: "vd_0123456789abcdef01234567",
            targetVoiceID: "voice_design_demo",
            name: "Demo",
            state: "confirmed",
            revision: "vr_0123456789abcdef0123456789abcdef01234567",
            publishedVoiceRevision: nil,
            reference: VoiceDesignReference(
                audioSHA256: String(repeating: "a", count: 64),
                textSHA256: String(repeating: "b", count: 64),
                transcriptSHA256: String(repeating: "c", count: 64),
                durationSeconds: 3
            ),
            validations: [],
            publishable: false
        )
        let candidateJSON = String(
            decoding: try JSONEncoder().encode(candidate),
            as: UTF8.self
        )
        let client = makeHTTPClient(
            statusCode: 200,
            body: Data(#"{"object":"list","data":[]}"#.utf8)
        )

        let listedCandidates = try await client.fetchVoiceDesignCandidates()
        XCTAssertTrue(listedCandidates.isEmpty)
        ServiceAPIURLProtocolStub.state.setResponse(
            statusCode: 200,
            body: Data(#"{"candidate":\#(candidateJSON)}"#.utf8)
        )
        let fetchedCandidate = try await client.fetchVoiceDesignCandidate(id: candidate.id)
        XCTAssertEqual(fetchedCandidate.id, candidate.id)
        _ = try await client.cancelVoiceDesignCandidate(id: candidate.id)
        ServiceAPIURLProtocolStub.state.setResponse(
            statusCode: 200,
            body: Data(
                """
                {"object":"list","data":[{"id":"zh_demo","revision":"pr_\(String(repeating: "d", count: 32))","revoked":false,"entry_count":2}]}
                """.utf8
            )
        )
        let summaries = try await client.fetchPronunciationSetSummaries()
        XCTAssertEqual(summaries.map(\.id), ["zh_demo"])
        XCTAssertEqual(summaries.first?.entryCount, 2)

        let requests = ServiceAPIURLProtocolStub.state.recordedRequests()
        XCTAssertEqual(
            requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            [
                "GET /v1/voice-designs",
                "GET /v1/voice-designs/\(candidate.id)",
                "POST /v1/voice-designs/\(candidate.id)/cancel",
                "GET /v1/speechrail/pronunciation-sets",
            ]
        )
    }

    func testVoiceDesignAudioRoutesCarryTheExactCandidateRevision() async throws {
        var wav = Data("RIFF".utf8)
        wav.append(contentsOf: [0, 0, 0, 0])
        wav.append(Data("WAVE".utf8))
        let client = makeHTTPClient(statusCode: 200, body: wav)
        let candidateID = "vd_0123456789abcdef01234567"
        let validationID = "vv_0123456789abcdef01234567"
        let expectedRevision = "vr_0123456789abcdef0123456789abcdef"

        let referenceAudio = try await client.fetchVoiceDesignReferenceAudio(
            id: candidateID,
            expectedRevision: expectedRevision
        )
        XCTAssertEqual(referenceAudio, wav)

        ServiceAPIURLProtocolStub.state.setResponse(statusCode: 200, body: wav)
        let validationAudio = try await client.fetchVoiceDesignValidationAudio(
            id: candidateID,
            validationID: validationID,
            expectedRevision: expectedRevision
        )
        XCTAssertEqual(validationAudio, wav)

        let requests = ServiceAPIURLProtocolStub.state.recordedRequests()
        XCTAssertEqual(
            requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            [
                "GET /v1/voice-designs/\(candidateID)/audio",
                "GET /v1/voice-designs/\(candidateID)/validations/"
                    + "\(validationID)/audio",
            ]
        )
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "SpeechRail-Expected-Candidate-Revision") },
            [expectedRevision, expectedRevision]
        )
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: HTTPHeaderNames.accept) },
            ["audio/wav", "audio/wav"]
        )
    }

    /// C1: the namespaced quality-runs route returns an envelope, not a bare report.
    /// Decoding it as `VoiceQualityReportSnapshotV2` fails on the missing top-level
    /// `status`, which is exactly the mismatch this DTO now models.
    func testQualityRunEnvelopeDecodesLegacyReportAndPersistedFlag() throws {
        let json = """
        {
          "legacy_report": {
            "policy_version": "voice_quality_v1",
            "status": "pass",
            "run_id": "vq_0123456789abcdef0123456789abcdef",
            "tested_at": "2026-09-28T00:00:00Z",
            "failure_codes": []
          },
          "evidence": {"schema": "voice_quality_evidence_v1"},
          "validation_persisted": true
        }
        """

        let decoded = try JSONDecoder().decode(VoiceQualityRunResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.legacyReport.status, .pass)
        XCTAssertEqual(decoded.legacyReport.runID, "vq_0123456789abcdef0123456789abcdef")
        XCTAssertTrue(decoded.validationPersisted)
        XCTAssertTrue(decoded.isRecordedOutputPass)
    }

    /// A `pass` report whose evidence never reached storage is a real observation,
    /// but it must not be promoted to "已验收": the next strict render still rejects.
    func testQualityRunEnvelopeWithPersistedFalseIsNotARecordedPass() throws {
        let json = """
        {
          "legacy_report": {"status": "pass", "failure_codes": []},
          "evidence": null,
          "validation_persisted": false
        }
        """

        let decoded = try JSONDecoder().decode(VoiceQualityRunResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.legacyReport.status, .pass)
        XCTAssertFalse(decoded.validationPersisted)
        XCTAssertFalse(decoded.isRecordedOutputPass)
        XCTAssertNil(decoded.evidence)
    }

    /// A missing `legacy_report` must fail to decode: an envelope without a report
    /// is a contract violation, not an empty successful check.
    func testQualityRunEnvelopeWithoutLegacyReportFailsToDecode() {
        let json = #"{"validation_persisted": true}"#

        XCTAssertThrowsError(
            try JSONDecoder().decode(VoiceQualityRunResponse.self, from: Data(json.utf8))
        )
    }

    /// `SafeVoiceEntry` must expose the service's production-readiness fact.
    /// A missing field is "unknown", never a silent `true`.
    func testSafeVoiceEntryDecodesProductionReadinessAndDefaultsToUnknown() throws {
        let withReadiness = try JSONDecoder().decode(
            SafeVoiceEntry.self,
            from: Data(Self.safeVoiceEntryJSON(productionReady: "false", reason: "\"output_validation_scope_missing\"").utf8)
        )
        XCTAssertEqual(withReadiness.productionReady, false)
        XCTAssertEqual(withReadiness.productionReadyReason, "output_validation_scope_missing")

        let withoutReadiness = try JSONDecoder().decode(
            SafeVoiceEntry.self,
            from: Data(Self.safeVoiceEntryJSON(productionReady: nil, reason: nil).utf8)
        )
        XCTAssertNil(withoutReadiness.productionReady)
        XCTAssertNil(withoutReadiness.productionReadyReason)
    }

    func testWithValidationPolicyKeepsEveryOtherOption() {
        let original = SpeechRailRequestOptions(
            expectedVoiceRevision: "vr_0123456789abcdef0123456789abcdef",
            expectedModelRevision: String(repeating: "a", count: 40),
            pronunciationSet: "story@pr_0123456789abcdef0123456789abcdef",
            receiptMode: "integrity",
            timingMode: "chunk",
            purpose: "interactive",
            latencyBudgetMs: 1_500,
            languageOverride: "ja",
            validationPolicy: "require_output_pass"
        )

        let updated = original.withValidationPolicy("allow_unverified")

        XCTAssertEqual(updated.validationPolicy, "allow_unverified")
        XCTAssertEqual(updated.headers["SpeechRail-Validation-Policy"], "allow_unverified")
        for (key, value) in original.headers where key != "SpeechRail-Validation-Policy" {
            XCTAssertEqual(updated.headers[key], value, key)
        }
    }

    /// F1: formal production must always carry the strict policy, even when the
    /// caller forgot it. Audition keeps the permissive default.
    func testRenderPinsStrictPolicyAndAuditionStaysUnverified() async throws {
        let client = makeHTTPClient(
            statusCode: 200,
            body: Data([0x52, 0x49, 0x46, 0x46])
        )
        ServiceAPIURLProtocolStub.state.setContentType("audio/wav")
        let options = SpeechRailRequestOptions(
            expectedVoiceRevision: "vr_0123456789abcdef0123456789abcdef",
            expectedModelRevision: String(repeating: "a", count: 40),
            validationPolicy: nil
        )

        _ = try await client.createSpeechRender(
            text: "正式制作",
            voiceID: "voice_demo",
            speed: 1.0,
            options: options
        )
        let renderRequest = try XCTUnwrap(
            ServiceAPIURLProtocolStub.state.recordedRequests().first
        )
        XCTAssertEqual(
            renderRequest.value(forHTTPHeaderField: "SpeechRail-Validation-Policy"),
            "require_output_pass"
        )
        // The render path must not drop the other options while pinning strict.
        XCTAssertEqual(
            renderRequest.value(forHTTPHeaderField: "SpeechRail-Expected-Voice-Revision"),
            "vr_0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(
            renderRequest.value(forHTTPHeaderField: "SpeechRail-Receipt-Mode"),
            "integrity"
        )

        _ = try await client.createSpeech(
            text: "试听一下",
            voiceID: "voice_demo",
            speed: 1.0,
            options: options
        )
        let auditionRequest = try XCTUnwrap(
            ServiceAPIURLProtocolStub.state.recordedRequests().dropFirst().first
        )
        XCTAssertEqual(
            auditionRequest.value(forHTTPHeaderField: "SpeechRail-Validation-Policy"),
            "allow_unverified"
        )
    }

    /// 验收②：回执拿不到时，音频优先保留，追溯状态照实说明，且一个身份都不伪造。
    func testMissingReceiptKeepsTheFullAudioAndNeverInventsAnIdentity() async throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00])
        let client = makeHTTPClient(statusCode: 200, body: audio)
        ServiceAPIURLProtocolStub.state.setRoute(
            pathContains: "/v1/audio/speech",
            statusCode: 200,
            body: audio,
            contentType: "audio/wav",
            headers: ["SpeechRail-Receipt-Id": "rr_0123456789abcdef0123456789abcdef"]
        )
        ServiceAPIURLProtocolStub.state.setRoute(
            pathContains: "/receipts/",
            statusCode: 404,
            body: Data(#"{"error":{"code":"not_found"}}"#.utf8)
        )

        let render = try await client.createSpeechRender(
            text: "回执缺失也要保住音频",
            voiceID: "voice_demo",
            speed: 1.0,
            options: SpeechRailRequestOptions()
        )

        XCTAssertEqual(render.audioData, audio, "回执不可用不构成丢音频的理由")
        XCTAssertEqual(render.provenance.state, .unavailable)
        XCTAssertEqual(render.provenance.reason, "receipt_unavailable")
        XCTAssertNil(render.planID, "没有回执就没有计划身份，不生成随机值顶替")
        XCTAssertNil(render.planSHA256)
        XCTAssertNil(render.pcmSHA256)
        XCTAssertNil(render.recipe)
    }

    /// 回执还没终态时同样不丢音频，只是把"还没写完"如实说出来。
    func testPendingReceiptKeepsTheAudioAndNamesTheUnfinishedState() async throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x10, 0x00, 0x00])
        let client = makeHTTPClient(statusCode: 200, body: audio)
        ServiceAPIURLProtocolStub.state.setRoute(
            pathContains: "/v1/audio/speech",
            statusCode: 200,
            body: audio,
            contentType: "audio/wav",
            headers: ["SpeechRail-Receipt-Id": "rr_0123456789abcdef0123456789abcdef"]
        )
        ServiceAPIURLProtocolStub.state.setRoute(
            pathContains: "/receipts/",
            statusCode: 200,
            body: Data("""
            {
              "receipt_id": "rr_0123456789abcdef0123456789abcdef",
              "request_id": "req-1",
              "status": "pending",
              "voice": {},
              "model": {},
              "audio": {},
              "recipe": null,
              "error_code": null,
              "created_at": 1,
              "completed_at": null
            }
            """.utf8)
        )

        let render = try await client.createSpeechRender(
            text: "回执还没终态",
            voiceID: "voice_demo",
            speed: 1.0,
            options: SpeechRailRequestOptions()
        )

        XCTAssertEqual(render.audioData, audio)
        XCTAssertEqual(render.provenance.state, .partial)
        XCTAssertEqual(render.provenance.reason, "receipt_status_pending")
        XCTAssertNil(render.recipe, "还没有配方就不是没有配方，是还没写完")
    }

    /// 回执终态但配方不齐：音频与已观察到的事实都保留，digest 不签发。
    func testCompletedReceiptWithAPartialRecipeKeepsTheAudioAndWithholdsTheDigest() async throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x28, 0x00, 0x00, 0x00])
        let client = makeHTTPClient(statusCode: 200, body: audio)
        ServiceAPIURLProtocolStub.state.setRoute(
            pathContains: "/v1/audio/speech",
            statusCode: 200,
            body: audio,
            contentType: "audio/wav",
            headers: ["SpeechRail-Receipt-Id": "rr_0123456789abcdef0123456789abcdef"]
        )
        ServiceAPIURLProtocolStub.state.setRoute(
            pathContains: "/receipts/",
            statusCode: 200,
            body: Data("""
            {
              "receipt_id": "rr_0123456789abcdef0123456789abcdef",
              "request_id": "req-1",
              "status": "completed",
              "voice": {"id": "narrator", "revision": "vr_x"},
              "model": {},
              "audio": {},
              "recipe": \(partialRecipeJSON),
              "error_code": null,
              "created_at": 1,
              "completed_at": 2
            }
            """.utf8)
        )

        let render = try await client.createSpeechRender(
            text: "配方不齐也要保住音频",
            voiceID: "narrator",
            speed: 1.0,
            options: SpeechRailRequestOptions()
        )

        XCTAssertEqual(render.audioData, audio)
        XCTAssertEqual(render.provenance.state, .partial)
        XCTAssertEqual(render.voiceRevision, "vr_x")
        let recipe = try XCTUnwrap(render.recipe)
        XCTAssertEqual(recipe.state, .partial)
        XCTAssertNil(recipe.digest, "事实不齐时不签发可复用的摘要")
        XCTAssertEqual(
            recipe.missingFields,
            ["model.engine_revision", "parameters.seed_policy"]
        )
    }

    private static func safeVoiceEntryJSON(
        productionReady: String?,
        reason: String?
    ) -> String {
        let readyField = productionReady.map { "\"production_ready\": \($0)," } ?? ""
        let reasonField = reason.map { "\"production_ready_reason\": \($0)," } ?? ""
        return """
        {
          "id": "voice_demo",
          "name": "Demo",
          "mode": "clone",
          "available": true,
          "availability_reason": "available",
          "variant": "custom_voice",
          "voice_revision": "vr_0123456789abcdef0123456789abcdef",
          "voice_identity_assurance": "content_addressed",
          "model": {"assurance": "configured_catalog", "catalog_revision": "catalog-7"},
          "descriptors": \(objectDescriptorsJSON),
          "operations": {},
          \(readyField)
          \(reasonField)
          "snapshot_id": "snap-1"
        }
        """
    }

    private func makeHTTPClient(statusCode: Int, body: Data) -> ServiceAPIClient {
        ServiceAPIURLProtocolStub.state.reset(statusCode: statusCode, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceAPIURLProtocolStub.self]
        return ServiceAPIClient(
            baseURL: URL(string: "https://speechrail.test")!,
            session: URLSession(configuration: configuration),
            apiKey: "test-key"
        )
    }
    #endif

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

#if SWIFT_PACKAGE
private final class ServiceAPIURLProtocolState: @unchecked Sendable {
    struct Reply {
        let statusCode: Int
        let body: Data
        let contentType: String
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var statusCode = 200
    private var body = Data()
    private var contentType = "application/json"
    /// Path-keyed replies checked before the default one. A render asks for
    /// audio and then for its receipt, so a single canned response cannot
    /// express "audio arrived, the receipt did not".
    private var routes: [(pathContains: String, reply: Reply)] = []
    private var recorded: [URLRequest] = []
    private var recordedBodyData: [Data?] = []

    func reset(statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.statusCode = statusCode
        self.body = body
        self.contentType = "application/json"
        routes = []
        recorded = []
        recordedBodyData = []
    }

    func setRoute(
        pathContains path: String,
        statusCode: Int,
        body: Data,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        routes.append(
            (
                path,
                Reply(
                    statusCode: statusCode,
                    body: body,
                    contentType: contentType,
                    headers: headers
                )
            )
        )
    }

    /// Audio routes assert on the request headers, not the decoded body, so they
    /// only need a plausible audio content type on the stubbed response.
    func setContentType(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        contentType = value
    }

    func responseContentType() -> String {
        lock.lock()
        defer { lock.unlock() }
        return contentType
    }

    func setResponse(statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.statusCode = statusCode
        self.body = body
    }

    func record(_ request: URLRequest, bodyData: Data?) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        recordedBodyData.append(bodyData)
        let path = request.url?.path ?? ""
        if let route = routes.first(where: { path.contains($0.pathContains) }) {
            return route.reply
        }
        return Reply(
            statusCode: statusCode,
            body: body,
            contentType: contentType,
            headers: [:]
        )
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func recordedBodies() -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBodyData
    }
}

private final class ServiceAPIURLProtocolStub: URLProtocol {
    static let state = ServiceAPIURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let client
        else {
            return
        }
        let requestBody = Self.bodyData(from: request)
        let reply = Self.state.record(request, bodyData: requestBody)
        var headerFields = reply.headers
        headerFields["Content-Type"] = reply.contentType
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: reply.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
#endif
