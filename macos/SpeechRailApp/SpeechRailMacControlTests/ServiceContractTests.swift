import XCTest
@testable import SpeechRailControlKit

final class ServiceContractTests: XCTestCase {
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
            "descriptors": [],
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
}
