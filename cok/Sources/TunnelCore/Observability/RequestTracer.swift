import Foundation

public actor RequestTracer {
    public struct Span: Sendable {
        public let traceID: String
        public let spanID: String
        public let parentSpanID: String?
        public let operationName: String
        public let startTime: Date
        public var endTime: Date?
        public var tags: [String: String]
        public var logs: [(Date, String)]
        
        public init(traceID: String, spanID: String, parentSpanID: String?, operationName: String) {
            self.traceID = traceID
            self.spanID = spanID
            self.parentSpanID = parentSpanID
            self.operationName = operationName
            self.startTime = Date()
            self.endTime = nil
            self.tags = [:]
            self.logs = []
        }
        
        public var duration: TimeInterval? {
            guard let endTime else { return nil }
            return endTime.timeIntervalSince(startTime)
        }
        
        public var durationMs: Double? {
            guard let duration else { return nil }
            return duration * 1000
        }
    }
    
    public struct TraceContext: Sendable {
        public let traceID: String
        public let spanID: String
        
        public init(traceID: String, spanID: String) {
            self.traceID = traceID
            self.spanID = spanID
        }
        
        public static func new() -> TraceContext {
            TraceContext(traceID: generateID(), spanID: generateID())
        }
        
        public func child() -> TraceContext {
            TraceContext(traceID: traceID, spanID: Self.generateID())
        }
        
        private static func generateID() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        }
        
        public var w3cHeader: String {
            "00-\(traceID)-\(spanID)-01"
        }
        
        public static func parse(header: String) -> TraceContext? {
            let parts = header.split(separator: "-")
            guard parts.count >= 3 else { return nil }
            return TraceContext(traceID: String(parts[1]), spanID: String(parts[2]))
        }
    }
    
    private var activeSpans: [String: Span] = [:]
    private var completedSpans: [Span] = []
    private let maxCompletedSpans: Int
    
    public init(maxCompletedSpans: Int = 1000) {
        self.maxCompletedSpans = maxCompletedSpans
    }
    
    public func startSpan(operationName: String, context: TraceContext? = nil, parentSpanID: String? = nil) -> TraceContext {
        let ctx = context ?? TraceContext.new()
        let span = Span(traceID: ctx.traceID, spanID: ctx.spanID, parentSpanID: parentSpanID, operationName: operationName)
        activeSpans[ctx.spanID] = span
        return ctx
    }
    
    public func setTag(spanID: String, key: String, value: String) {
        activeSpans[spanID]?.tags[key] = value
    }
    
    public func log(spanID: String, message: String) {
        activeSpans[spanID]?.logs.append((Date(), message))
    }
    
    public func endSpan(spanID: String) {
        guard var span = activeSpans.removeValue(forKey: spanID) else { return }
        span.endTime = Date()
        completedSpans.append(span)
        if completedSpans.count > maxCompletedSpans {
            completedSpans.removeFirst(completedSpans.count - maxCompletedSpans)
        }
    }
    
    public func getSpan(spanID: String) -> Span? {
        activeSpans[spanID] ?? completedSpans.first { $0.spanID == spanID }
    }
    
    public func getTrace(traceID: String) -> [Span] {
        let active = activeSpans.values.filter { $0.traceID == traceID }
        let completed = completedSpans.filter { $0.traceID == traceID }
        return (Array(active) + completed).sorted { $0.startTime < $1.startTime }
    }
    
    public func activeSpanCount() -> Int { activeSpans.count }
    public func completedSpanCount() -> Int { completedSpans.count }
    
    public func recentSpans(limit: Int = 100) -> [Span] {
        Array(completedSpans.suffix(limit))
    }
}

public struct SpanScope: Sendable {
    private let tracer: RequestTracer
    private let spanID: String
    
    public init(tracer: RequestTracer, spanID: String) {
        self.tracer = tracer
        self.spanID = spanID
    }
    
    public func tag(_ key: String, _ value: String) async {
        await tracer.setTag(spanID: spanID, key: key, value: value)
    }
    
    public func log(_ message: String) async {
        await tracer.log(spanID: spanID, message: message)
    }
    
    public func end() async {
        await tracer.endSpan(spanID: spanID)
    }
}
