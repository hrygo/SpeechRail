import XCTest

@MainActor
private final class RecordingRegistrationClient: ControlAgentRegistrationClient {
    var status: ControlAgentStatusKind
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: ControlAgentStatusKind) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}

@MainActor
final class ControlAgentRegistrationTests: XCTestCase {
    func testApprovalRequiredDoesNotRegisterAndPointsToLoginItems() throws {
        let client = RecordingRegistrationClient(status: .requiresApproval)
        let registration = ControlAgentRegistration(client: client)

        XCTAssertEqual(registration.statusSnapshot.action, .openLoginItems)
        XCTAssertFalse(registration.statusSnapshot.allowsMutation)
        XCTAssertThrowsError(try registration.ensureRegisteredForCurrentBundle()) { error in
            XCTAssertEqual(
                error as? ControlAgentRegistrationError,
                .notEnabled(.requiresApproval)
            )
        }
        XCTAssertEqual(client.registerCount, 0)
        XCTAssertEqual(client.unregisterCount, 0)
    }

    func testNotRegisteredRequiresAnExplicitRegisterAction() throws {
        let client = RecordingRegistrationClient(status: .notRegistered)
        let registration = ControlAgentRegistration(client: client)

        XCTAssertEqual(registration.statusSnapshot.action, .register)
        XCTAssertThrowsError(try registration.ensureRegisteredForCurrentBundle())
        XCTAssertEqual(client.registerCount, 0)

        try registration.register()

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertTrue(registration.statusSnapshot.allowsMutation)
    }

    func testMissingOrUnknownAgentFailsClosed() {
        for kind in [ControlAgentStatusKind.notFound, .unknown] {
            let snapshot = ControlAgentStatusSnapshot(kind: kind)

            XCTAssertFalse(snapshot.allowsMutation)
            XCTAssertEqual(snapshot.action, kind == .notFound ? .installAgent : .unavailable)
        }
    }

    func testExplicitReregisterIsTheOnlyOperationThatUnregisters() throws {
        let client = RecordingRegistrationClient(status: .enabled)
        let registration = ControlAgentRegistration(client: client)

        try registration.reregister()

        XCTAssertEqual(client.unregisterCount, 1)
        XCTAssertEqual(client.registerCount, 1)
    }
}
