import XCTest
@testable import TunnelCore

final class MetricsCollectorTests: XCTestCase {

    func testIncrementCounter() async {
        let collector = MetricsCollector()
        await collector.increment("requests_total")
        await collector.increment("requests_total")
        await collector.increment("requests_total", by: 5)

        let count = await collector.counter("requests_total")
        XCTAssertEqual(count, 7)
    }

    func testCounterWithLabels() async {
        let collector = MetricsCollector()
        await collector.increment("requests_total", labels: ["method": "GET"])
        await collector.increment("requests_total", labels: ["method": "POST"])
        await collector.increment("requests_total", labels: ["method": "GET"])

        let getCount = await collector.counter("requests_total", labels: ["method": "GET"])
        let postCount = await collector.counter("requests_total", labels: ["method": "POST"])

        XCTAssertEqual(getCount, 2)
        XCTAssertEqual(postCount, 1)
    }

    func testGauge() async {
        let collector = MetricsCollector()
        await collector.gauge("connections", value: 10)

        var value = await collector.gaugeValue("connections")
        XCTAssertEqual(value, 10)

        await collector.gauge("connections", value: 5)
        value = await collector.gaugeValue("connections")
        XCTAssertEqual(value, 5)
    }

    func testHistogram() async {
        let collector = MetricsCollector()
        for i in 1...10 {
            await collector.histogram("response_time", value: Double(i) * 0.1)
        }

        let stats = await collector.histogramStats("response_time")
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.count, 10)
        XCTAssertEqual(stats!.min, 0.1, accuracy: 0.001)
        XCTAssertEqual(stats!.max, 1.0, accuracy: 0.001)
        XCTAssertEqual(stats!.mean, 0.55, accuracy: 0.001)
    }

    func testRecordDuration() async {
        let collector = MetricsCollector()
        let start = Date().addingTimeInterval(-0.1)
        await collector.recordDuration("request_duration", start: start)

        let stats = await collector.histogramStats("request_duration")
        XCTAssertNotNil(stats)
        XCTAssertGreaterThan(stats?.mean ?? 0, 0.05)
    }

    func testAllMetrics() async {
        let collector = MetricsCollector()
        await collector.increment("counter1")
        await collector.gauge("gauge1", value: 42)
        await collector.histogram("hist1", value: 1.0)

        let all = await collector.allMetrics()
        XCTAssertEqual(all.counters.count, 1)
        XCTAssertEqual(all.gauges.count, 1)
        XCTAssertEqual(all.histograms.count, 1)
    }

    func testReset() async {
        let collector = MetricsCollector()
        await collector.increment("test")
        await collector.reset()

        let count = await collector.counter("test")
        XCTAssertEqual(count, 0)
    }
}

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

final class RequestTracerTests: XCTestCase {

    func testStartAndEndSpan() async {
        let tracer = RequestTracer()
        let context = await tracer.startSpan(operationName: "test-op")

        var activeCount = await tracer.activeSpanCount()
        XCTAssertEqual(activeCount, 1)

        await tracer.endSpan(spanID: context.spanID)

        activeCount = await tracer.activeSpanCount()
        XCTAssertEqual(activeCount, 0)

        let completedCount = await tracer.completedSpanCount()
        XCTAssertEqual(completedCount, 1)
    }

    func testSpanTags() async {
        let tracer = RequestTracer()
        let context = await tracer.startSpan(operationName: "http-request")
        await tracer.setTag(spanID: context.spanID, key: "http.method", value: "GET")
        await tracer.setTag(spanID: context.spanID, key: "http.url", value: "/api/test")
        await tracer.endSpan(spanID: context.spanID)

        let span = await tracer.getSpan(spanID: context.spanID)
        XCTAssertEqual(span?.tags["http.method"], "GET")
        XCTAssertEqual(span?.tags["http.url"], "/api/test")
    }

    func testSpanLogs() async {
        let tracer = RequestTracer()
        let context = await tracer.startSpan(operationName: "process")
        await tracer.log(spanID: context.spanID, message: "Started processing")
        await tracer.log(spanID: context.spanID, message: "Completed")
        await tracer.endSpan(spanID: context.spanID)

        let span = await tracer.getSpan(spanID: context.spanID)
        XCTAssertEqual(span?.logs.count, 2)
    }

    func testTraceContext() {
        let context = RequestTracer.TraceContext.new()
        XCTAssertFalse(context.traceID.isEmpty)
        XCTAssertFalse(context.spanID.isEmpty)

        let child = context.child()
        XCTAssertEqual(child.traceID, context.traceID)
        XCTAssertNotEqual(child.spanID, context.spanID)
    }

    func testW3CHeader() {
        let context = RequestTracer.TraceContext(traceID: "abc123", spanID: "def456")
        XCTAssertEqual(context.w3cHeader, "00-abc123-def456-01")

        let parsed = RequestTracer.TraceContext.parse(header: "00-abc123-def456-01")
        XCTAssertEqual(parsed?.traceID, "abc123")
        XCTAssertEqual(parsed?.spanID, "def456")
    }

    func testGetTrace() async {
        let tracer = RequestTracer()
        let parent = await tracer.startSpan(operationName: "parent")
        let child = await tracer.startSpan(operationName: "child", context: parent.child(), parentSpanID: parent.spanID)

        await tracer.endSpan(spanID: child.spanID)
        await tracer.endSpan(spanID: parent.spanID)

        let trace = await tracer.getTrace(traceID: parent.traceID)
        XCTAssertEqual(trace.count, 2)
    }
}

final class PrometheusExporterTests: XCTestCase {

    func testExportCounters() async {
        let collector = MetricsCollector()
        await collector.increment("requests_total", by: 100)

        let metrics = await collector.allMetrics()
        let exporter = PrometheusExporter()
        let output = exporter.export(metrics)

        XCTAssertTrue(output.contains("requests_total"))
        XCTAssertTrue(output.contains("100"))
        XCTAssertTrue(output.contains("counter"))
    }

    func testExportGauges() async {
        let collector = MetricsCollector()
        await collector.gauge("temperature", value: 23.5)

        let metrics = await collector.allMetrics()
        let exporter = PrometheusExporter()
        let output = exporter.export(metrics)

        XCTAssertTrue(output.contains("temperature"))
        XCTAssertTrue(output.contains("gauge"))
    }

    func testExportWithLabels() async {
        let collector = MetricsCollector()
        await collector.increment("http_requests", labels: ["method": "GET", "status": "200"])

        let metrics = await collector.allMetrics()
        let exporter = PrometheusExporter()
        let output = exporter.export(metrics)

        XCTAssertTrue(output.contains("method=GET"))
        XCTAssertTrue(output.contains("status=200"))
    }
}

final class StructuredLoggerTests: XCTestCase {

    func testLogContext() {
        let context = LogContext(requestID: UUID(), subdomain: "test")
        let metadata = context.metadata

        XCTAssertNotNil(metadata["requestID"])
        XCTAssertEqual(metadata["subdomain"], "test")
    }

    func testLoggerWithContext() {
        let logger = StructuredLogger(label: "test")
        let contextLogger = logger.with(requestID: UUID(), subdomain: "myapp")

        XCTAssertNotNil(contextLogger)
    }
}
