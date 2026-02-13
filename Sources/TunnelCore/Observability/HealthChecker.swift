import Foundation

public actor HealthChecker {
    public enum Status: String, Sendable, Codable {
        case healthy = "healthy"
        case degraded = "degraded"
        case unhealthy = "unhealthy"
    }
    
    public struct Check: Sendable {
        public let name: String
        public let check: @Sendable () async -> CheckResult
        
        public init(name: String, check: @escaping @Sendable () async -> CheckResult) {
            self.name = name
            self.check = check
        }
    }
    
    public struct CheckResult: Sendable {
        public let status: Status
        public let message: String?
        public let duration: TimeInterval
        
        public init(status: Status, message: String? = nil, duration: TimeInterval = 0) {
            self.status = status
            self.message = message
            self.duration = duration
        }
        
        public static func healthy(_ message: String? = nil) -> CheckResult {
            CheckResult(status: .healthy, message: message)
        }
        
        public static func degraded(_ message: String) -> CheckResult {
            CheckResult(status: .degraded, message: message)
        }
        
        public static func unhealthy(_ message: String) -> CheckResult {
            CheckResult(status: .unhealthy, message: message)
        }
    }
    
    public struct HealthReport: Sendable, Codable {
        public let status: Status
        public let checks: [String: ComponentHealth]
        public let timestamp: Date
        public let version: String
        
        public init(status: Status, checks: [String: ComponentHealth], version: String) {
            self.status = status
            self.checks = checks
            self.timestamp = Date()
            self.version = version
        }
    }
    
    public struct ComponentHealth: Sendable, Codable {
        public let status: Status
        public let message: String?
        public let durationMs: Double
        
        public init(status: Status, message: String?, durationMs: Double) {
            self.status = status
            self.message = message
            self.durationMs = durationMs
        }
    }
    
    private var checks: [Check] = []
    private let version: String
    
    public init(version: String = "1.0.0") {
        self.version = version
    }
    
    public func register(_ check: Check) {
        checks.append(check)
    }
    
    public func register(name: String, check: @escaping @Sendable () async -> CheckResult) {
        checks.append(Check(name: name, check: check))
    }
    
    public func runChecks() async -> HealthReport {
        var componentResults: [String: ComponentHealth] = [:]
        var overallStatus: Status = .healthy
        
        for check in checks {
            let start = Date()
            let result = await check.check()
            let duration = Date().timeIntervalSince(start) * 1000
            
            componentResults[check.name] = ComponentHealth(
                status: result.status,
                message: result.message,
                durationMs: duration
            )
            
            switch result.status {
            case .unhealthy:
                overallStatus = .unhealthy
            case .degraded:
                if overallStatus == .healthy { overallStatus = .degraded }
            case .healthy:
                break
            }
        }
        
        return HealthReport(status: overallStatus, checks: componentResults, version: version)
    }
    
    public func liveness() -> CheckResult {
        .healthy()
    }
    
    public func readiness() async -> CheckResult {
        let report = await runChecks()
        switch report.status {
        case .healthy: return .healthy()
        case .degraded: return .degraded("Some checks degraded")
        case .unhealthy: return .unhealthy("System not ready")
        }
    }
}

public extension HealthChecker {
    func registerMemoryCheck(warningMB: Int = 512, criticalMB: Int = 1024) {
        register(name: "memory") {
            let info = ProcessInfo.processInfo
            let physicalMemory = info.physicalMemory
            let usedMemory = physicalMemory - UInt64(info.physicalMemory)
            let usedMB = Int(usedMemory / 1024 / 1024)
            
            if usedMB > criticalMB {
                return .unhealthy("Memory usage: \(usedMB)MB exceeds \(criticalMB)MB")
            } else if usedMB > warningMB {
                return .degraded("Memory usage: \(usedMB)MB exceeds \(warningMB)MB")
            }
            return .healthy("Memory: \(usedMB)MB")
        }
    }
    
    func registerUptimeCheck() {
        let startTime = Date()
        register(name: "uptime") {
            let uptime = Date().timeIntervalSince(startTime)
            return .healthy("Uptime: \(Int(uptime))s")
        }
    }
}
