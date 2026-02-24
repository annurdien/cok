import XCTest
@testable import TunnelCore

final class HealthCheckerTests: XCTestCase {

    func testHealthyCheck() async {
        let checker = HealthChecker(version: "0.1.0")
        await checker.register(name: "test") {
            .healthy("All good")
        }

        let report = await checker.runChecks()
        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.checks["test"]?.status, .healthy)
    }

    func testDegradedCheck() async {
        let checker = HealthChecker()
        await checker.register(name: "degraded") {
            .degraded("Slow responses")
        }

        let report = await checker.runChecks()
        XCTAssertEqual(report.status, .degraded)
    }

    func testUnhealthyCheck() async {
        let checker = HealthChecker()
        await checker.register(name: "healthy") { .healthy() }
        await checker.register(name: "unhealthy") { .unhealthy("Database down") }

        let report = await checker.runChecks()
        XCTAssertEqual(report.status, .unhealthy)
    }

    func testLiveness() async {
        let checker = HealthChecker()
        let result = await checker.liveness()
        XCTAssertEqual(result.status, .healthy)
    }

    func testReadiness() async {
        let checker = HealthChecker()
        await checker.register(name: "db") { .healthy() }

        let result = await checker.readiness()
        XCTAssertEqual(result.status, .healthy)
    }
}
