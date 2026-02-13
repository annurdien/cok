import Foundation

public struct PrometheusExporter: Sendable {
    public init() {}

    public func export(_ metrics: AllMetrics) -> String {
        var lines: [String] = []

        for (name, value) in metrics.counters.sorted(by: { $0.key < $1.key }) {
            let (metricName, labels) = parseKey(name)
            lines.append("# TYPE \(metricName) counter")
            lines.append("\(metricName)\(labels) \(value)")
        }

        for (name, value) in metrics.gauges.sorted(by: { $0.key < $1.key }) {
            let (metricName, labels) = parseKey(name)
            lines.append("# TYPE \(metricName) gauge")
            lines.append("\(metricName)\(labels) \(formatValue(value))")
        }

        for (name, stats) in metrics.histograms.sorted(by: { $0.key < $1.key }) {
            let (metricName, labels) = parseKey(name)
            lines.append("# TYPE \(metricName) histogram")
            lines.append("\(metricName)_count\(labels) \(stats.count)")
            lines.append("\(metricName)_sum\(labels) \(formatValue(stats.sum))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.005")) \(bucketCount(stats, 0.005))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.01")) \(bucketCount(stats, 0.01))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.025")) \(bucketCount(stats, 0.025))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.05")) \(bucketCount(stats, 0.05))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.1")) \(bucketCount(stats, 0.1))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.25")) \(bucketCount(stats, 0.25))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "0.5")) \(bucketCount(stats, 0.5))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "1.0")) \(bucketCount(stats, 1.0))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "2.5")) \(bucketCount(stats, 2.5))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "5.0")) \(bucketCount(stats, 5.0))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "10.0")) \(bucketCount(stats, 10.0))")
            lines.append("\(metricName)_bucket\(mergeLabels(labels, "le", "+Inf")) \(stats.count)")
        }

        return lines.joined(separator: "\n")
    }

    private func parseKey(_ key: String) -> (name: String, labels: String) {
        guard let braceStart = key.firstIndex(of: "{"),
              let braceEnd = key.lastIndex(of: "}") else {
            return (key, "")
        }
        let name = String(key[..<braceStart])
        let labels = String(key[braceStart...braceEnd])
        return (name, labels)
    }

    private func mergeLabels(_ existing: String, _ key: String, _ value: String) -> String {
        if existing.isEmpty {
            return "{\(key)=\"\(value)\"}"
        }
        let inner = existing.dropFirst().dropLast()
        return "{\(inner),\(key)=\"\(value)\"}"
    }

    private func formatValue(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    private func bucketCount(_ stats: HistogramStats, _ le: Double) -> Int {
        if stats.max <= le { return stats.count }
        if stats.min > le { return 0 }
        let ratio = (le - stats.min) / (stats.max - stats.min)
        return Int(Double(stats.count) * ratio)
    }
}
