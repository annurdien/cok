import XCTest
import Logging
import NIOCore
@testable import TunnelCore
@testable import TunnelServer

final class RequestTrackerTests: XCTestCase, @unchecked Sendable {
    var tracker: RequestTracker!
    var logger: Logger!

    override func setUp() async throws {
        logger = Logger(label: "test")
        logger.logLevel = .critical
        tracker = RequestTracker(logger: logger)
    }

    func testTrackAndCompleteRequest() async throws {
        let requestID = UUID()

        let responseTask = Task {
            try await tracker.track(requestID: requestID)
        }

        try await Task.sleep(for: .milliseconds(100))

        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 200,
            headers: [HTTPHeader(name: "content-type", value: "text/plain")],
            body: Data("test".utf8)
        )

        await tracker.complete(requestID: requestID, response: response)

        let result = try await responseTask.value
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.headers.first?.name, "content-type")
    }

    func testPendingRequestCount() async throws {
        let id1 = UUID()
        let id2 = UUID()

        let task1 = Task { try await tracker.track(requestID: id1) }
        let task2 = Task { try await tracker.track(requestID: id2) }

        try await Task.sleep(for: .milliseconds(100))

        let count = await tracker.pendingCount()
        XCTAssertEqual(count, 2)

        let response = HTTPResponseMessage(
            requestID: id1,
            statusCode: 200,
            headers: [],
            body: Data()
        )
        await tracker.complete(requestID: id1, response: response)

        try await Task.sleep(for: .milliseconds(100))

        let newCount = await tracker.pendingCount()
        XCTAssertEqual(newCount, 1)

        task1.cancel()
        task2.cancel()
    }

    func testRequestTimeout() async throws {
        let shortTracker = RequestTracker(timeout: 0.1, logger: logger)
        let requestID = UUID()

        do {
            try await shortTracker.track(requestID: requestID)
            XCTFail("Should have timed out")
        } catch {
            XCTAssertTrue(error is TunnelError)
        }
    }

    func testCancelRequest() async throws {
        let requestID = UUID()

        let task = Task {
            try await tracker.track(requestID: requestID)
        }

        try await Task.sleep(for: .milliseconds(100))

        let error = TunnelError.client(.timeout, context: ErrorContext(component: "test"))
        await tracker.fail(requestID: requestID, error: error)

        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch {
            XCTAssertTrue(error is TunnelError || error is CancellationError)
        }
    }

    func testDuplicateCompletion() async throws {
        let requestID = UUID()

        let task = Task {
            try await tracker.track(requestID: requestID)
        }

        try await Task.sleep(for: .milliseconds(100))

        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 200,
            headers: [],
            body: Data()
        )

        await tracker.complete(requestID: requestID, response: response)
        let result = try await task.value
        XCTAssertEqual(result.statusCode, 200)

        await tracker.complete(requestID: requestID, response: response)

        let count = await tracker.pendingCount()
        XCTAssertEqual(count, 0)
    }
}
