import XCTest

// Async versions retain the existing XCTest recovery assertions and their call-site locations.
// Evaluate actor results before entering XCTest's synchronous autoclosures.
@MainActor
func XCTAssertEqualAsync<T: Equatable>(
    _ first: @autoclosure () async throws -> T, _ second: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let a = try await first()
    let b = try await second()
    XCTAssertEqual(a, b, message(), file: file, line: line)
}

@MainActor
func XCTAssertNotEqualAsync<T: Equatable>(
    _ first: @autoclosure () async throws -> T, _ second: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let a = try await first()
    let b = try await second()
    XCTAssertNotEqual(a, b, message(), file: file, line: line)
}

@MainActor
func XCTAssertTrueAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let value = try await expression()
    XCTAssertTrue(value, message(), file: file, line: line)
}

@MainActor
func XCTAssertFalseAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let value = try await expression()
    XCTAssertFalse(value, message(), file: file, line: line)
}

@MainActor
func XCTAssertNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let value = try await expression()
    XCTAssertNil(value, message(), file: file, line: line)
}

@MainActor
func XCTAssertNotNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let value = try await expression()
    XCTAssertNotNil(value, message(), file: file, line: line)
}

@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (any Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("Expected an error. " + message(), file: file, line: line) }
    catch { errorHandler(error) }
}

@MainActor
func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async {
    do { _ = try await expression() }
    catch { XCTFail("Unexpected error: \(error). " + message(), file: file, line: line) }
}

@MainActor
func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, message(), file: file, line: line)
}
