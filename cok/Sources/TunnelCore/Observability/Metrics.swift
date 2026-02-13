import Foundation

public actor MetricsCollector {
    public struct Metric: Sendable {
        public let name: String
        public let value: Double
        public let timestamp: Date
        public let labels: [String: String]
        
        public init(name: String, value: Double, labels: [String: String] = [:]) {
            self.name = name
            self.value = value
            self.timestamp = Date()
            self.labels = labels
        }
    }
    
    private var counters: [String: Int64] = [:]
    private var gauges: [String: Double] = [:]
    private var histograms: [String: [Double]] = [:]
    private let maxHistogramSamples: Int
    
    public init(maxHistogramSamples: Int = 1000) {
        self.maxHistogramSamples = maxHistogramSamples
    }
    
    public func increment(_ name: String, by value: Int64 = 1, labels: [String: String] = [:]) {
        let key = metricKey(name, labels)
        counters[key, default: 0] += value
    }
    
    public func gauge(_ name: String, value: Double, labels: [String: String] = [:]) {
        let key = metricKey(name, labels)
        gauges[key] = value
    }
    
    public func histogram(_ name: String, value: Double, labels: [String: String] = [:]) {
        let key = metricKey(name, labels)
        var samples = histograms[key] ?? []
        samples.append(value)
        if samples.count > maxHistogramSamples {
            samples.removeFirst(samples.count - maxHistogramSamples)
        }
        histograms[key] = samples
    }
    
    public func recordDuration(_ name: String, start: Date, labels: [String: String] = [:]) {
        let duration = Date().timeIntervalSince(start)
        histogram(name, value: duration, labels: labels)
    }
    
    public func counter(_ name: String, labels: [String: String] = [:]) -> Int64 {
        counters[metricKey(name, labels)] ?? 0
    }
    
    public func gaugeValue(_ name: String, labels: [String: String] = [:]) -> Double? {
        gauges[metricKey(name, labels)]
    }
    
    public func histogramStats(_ name: String, labels: [String: String] = [:]) -> HistogramStats? {
        guard let samples = histograms[metricKey(name, labels)], !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return HistogramStats(
            count: samples.count,
            sum: samples.reduce(0, +),
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            mean: samples.reduce(0, +) / Double(samples.count),
            p50: percentile(sorted, 0.50),
            p90: percentile(sorted, 0.90),
            p99: percentile(sorted, 0.99)
        )
    }
    
    public func allMetrics() -> AllMetrics {
        AllMetrics(counters: counters, gauges: gauges, histograms: histograms.mapValues { HistogramStats.from($0) })
    }
    
    public func reset() {
        counters.removeAll()
        gauges.removeAll()
        histograms.removeAll()
    }
    
    private func metricKey(_ name: String, _ labels: [String: String]) -> String {
        guard !labels.isEmpty else { return name }
        let labelStr = labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(name){\(labelStr)}"
    }
    
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
}

public struct HistogramStats: Sendable {
    public let count: Int
    public let sum: Double
    public let min: Double
    public let max: Double
    public let mean: Double
    public let p50: Double
    public let p90: Double
    public let p99: Double
    
    static func from(_ samples: [Double]) -> HistogramStats {
        guard !samples.isEmpty else {
            return HistogramStats(count: 0, sum: 0, min: 0, max: 0, mean: 0, p50: 0, p90: 0, p99: 0)
        }
        let sorted = samples.sorted()
        return HistogramStats(
            count: samples.count,
            sum: samples.reduce(0, +),
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            mean: samples.reduce(0, +) / Double(samples.count),
            p50: sorted[Int(Double(sorted.count - 1) * 0.50)],
            p90: sorted[Int(Double(sorted.count - 1) * 0.90)],
            p99: sorted[Int(Double(sorted.count - 1) * 0.99)]
        )
    }
}

public struct AllMetrics: Sendable {
    public let counters: [String: Int64]
    public let gauges: [String: Double]
    public let histograms: [String: HistogramStats]
}

public enum StandardMetrics {
    public static let requestsTotal = "cok_requests_total"
    public static let requestDuration = "cok_request_duration_seconds"
    public static let activeConnections = "cok_active_connections"
    public static let tunnelsActive = "cok_tunnels_active"
    public static let bytesReceived = "cok_bytes_received_total"
    public static let bytesSent = "cok_bytes_sent_total"
    public static let errorsTotal = "cok_errors_total"
    public static let rateLimitHits = "cok_rate_limit_hits_total"
}
