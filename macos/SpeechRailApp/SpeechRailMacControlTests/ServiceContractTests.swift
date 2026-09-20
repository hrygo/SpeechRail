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
        XCTAssertEqual(snapshot.voices[0].availabilityReason.rawValue, "future_reason")
    }

    func testMissingSnapshotIDIsInvalidContract() {
        let data = Data(#"{"schema_version":"effective_capabilities_v1"}"#.utf8)

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
    }
}
