import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class SettingsKeyDraftPolicyTests: XCTestCase {
    func testBlankDraftUsesStoredKeyAndDoesNotPersist() {
        let connection = LLMConnectionResult.connected(milliseconds: 12, model: "test-model")

        XCTAssertEqual(
            LLMKeyDraftPolicy.candidateKey(draft: "  \n", storedKey: "stored-key"),
            "stored-key"
        )
        XCTAssertFalse(LLMKeyDraftPolicy.shouldPersist(draft: "  \n", connection: connection))
    }

    func testNonBlankDraftIsTheCandidateButPersistsOnlyAfterConnection() {
        let draft = "  new-key  "
        let connected = LLMConnectionResult.connected(milliseconds: 12, model: "test-model")
        let failed = LLMConnectionResult.unreachable("bad key")

        XCTAssertEqual(
            LLMKeyDraftPolicy.candidateKey(draft: draft, storedKey: "stored-key"),
            "new-key"
        )
        XCTAssertFalse(LLMKeyDraftPolicy.shouldPersist(draft: draft, connection: failed))
        XCTAssertTrue(LLMKeyDraftPolicy.shouldPersist(draft: draft, connection: connected))
    }
}
