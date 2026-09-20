import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class SettingsKeyDraftPolicyTests: XCTestCase {
    func testBlankDraftUsesStoredKeyAndOnlyOffersCheck() {
        let connection = LLMConnectionResult.connected(milliseconds: 12, model: "test-model")

        XCTAssertEqual(
            LLMKeyDraftPolicy.candidateKey(draft: "  \n", storedKey: "stored-key"),
            "stored-key"
        )
        XCTAssertEqual(LLMKeyDraftAction.check, LLMKeyDraftPolicy.action(for: "  \n"))
        XCTAssertFalse(
            LLMKeyDraftPolicy.shouldPersist(
                draft: "  \n",
                connection: connection,
                saveRequested: true
            )
        )
    }

    func testNonBlankDraftIsTheCandidateButPersistsOnlyAfterExplicitConnectedSave() {
        let draft = "  new-key  "
        let connected = LLMConnectionResult.connected(milliseconds: 12, model: "test-model")
        let failed = LLMConnectionResult.unreachable("bad key")

        XCTAssertEqual(
            LLMKeyDraftPolicy.candidateKey(draft: draft, storedKey: "stored-key"),
            "new-key"
        )
        XCTAssertEqual(LLMKeyDraftAction.checkAndSave, LLMKeyDraftPolicy.action(for: draft))
        XCTAssertFalse(
            LLMKeyDraftPolicy.shouldPersist(
                draft: draft,
                connection: failed,
                saveRequested: true
            )
        )
        XCTAssertFalse(
            LLMKeyDraftPolicy.shouldPersist(
                draft: draft,
                connection: connected,
                saveRequested: false
            )
        )
        XCTAssertTrue(
            LLMKeyDraftPolicy.shouldPersist(
                draft: draft,
                connection: connected,
                saveRequested: true
            )
        )
    }
}
