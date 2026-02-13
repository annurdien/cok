import NIOCore
import Foundation

public actor BackpressureController {
    public enum State: Sendable {
        case accepting
        case throttling
        case rejecting
    }
    
    public struct Configuration: Sendable {
        public let lowWatermark: Int
        public let highWatermark: Int
        public let criticalWatermark: Int
        
        public init(lowWatermark: Int = 1000, highWatermark: Int = 5000, criticalWatermark: Int = 10000) {
            self.lowWatermark = lowWatermark
            self.highWatermark = highWatermark
            self.criticalWatermark = criticalWatermark
        }
    }
    
    private let config: Configuration
    private var pendingRequests: Int = 0
    private var state: State = .accepting
    
    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }
    
    public func requestPermission() -> (allowed: Bool, delay: TimeInterval?) {
        pendingRequests += 1
        updateState()
        
        switch state {
        case .accepting:
            return (true, nil)
        case .throttling:
            let delay = calculateDelay()
            return (true, delay)
        case .rejecting:
            pendingRequests -= 1
            return (false, nil)
        }
    }
    
    public func complete() {
        pendingRequests = max(0, pendingRequests - 1)
        updateState()
    }
    
    public func currentState() -> State { state }
    public func pendingCount() -> Int { pendingRequests }
    
    public func utilization() -> Double {
        Double(pendingRequests) / Double(config.criticalWatermark)
    }
    
    private func updateState() {
        if pendingRequests >= config.criticalWatermark {
            state = .rejecting
        } else if pendingRequests >= config.highWatermark {
            state = .throttling
        } else if pendingRequests < config.lowWatermark {
            state = .accepting
        }
    }
    
    private func calculateDelay() -> TimeInterval {
        let ratio = Double(pendingRequests - config.lowWatermark) / Double(config.highWatermark - config.lowWatermark)
        return min(ratio * 0.5, 2.0)
    }
}

public final class ChannelBackpressureHandler: ChannelDuplexHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private let highWatermark: Int
    private let lowWatermark: Int
    private var bufferedBytes: Int = 0
    private var isWritable: Bool = true
    
    public init(lowWatermark: Int = 32 * 1024, highWatermark: Int = 64 * 1024) {
        self.lowWatermark = lowWatermark
        self.highWatermark = highWatermark
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bufferedBytes += buffer.readableBytes
        
        if bufferedBytes >= highWatermark && isWritable {
            isWritable = false
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        }
        
        context.fireChannelRead(wrapInboundOut(buffer))
    }
    
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        bufferedBytes = max(0, bufferedBytes - buffer.readableBytes)
        
        if bufferedBytes < lowWatermark && !isWritable {
            isWritable = true
            context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
        }
        
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }
}

public actor MemoryPressureMonitor {
    public enum Level: Sendable {
        case normal
        case warning
        case critical
    }
    
    private let warningThreshold: Int
    private let criticalThreshold: Int
    private var currentUsage: Int = 0
    
    public init(warningThresholdMB: Int = 512, criticalThresholdMB: Int = 1024) {
        self.warningThreshold = warningThresholdMB * 1024 * 1024
        self.criticalThreshold = criticalThresholdMB * 1024 * 1024
    }
    
    public func recordAllocation(_ bytes: Int) {
        currentUsage += bytes
    }
    
    public func recordDeallocation(_ bytes: Int) {
        currentUsage = max(0, currentUsage - bytes)
    }
    
    public func currentLevel() -> Level {
        if currentUsage >= criticalThreshold { return .critical }
        if currentUsage >= warningThreshold { return .warning }
        return .normal
    }
    
    public func usage() -> Int { currentUsage }
    
    public func shouldShedLoad() -> Bool {
        currentLevel() == .critical
    }
}
