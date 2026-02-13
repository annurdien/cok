import NIOCore
import Foundation

public final class BufferPool: @unchecked Sendable {
    private let allocator: ByteBufferAllocator
    private var pool: [ByteBuffer] = []
    private let maxPoolSize: Int
    private let defaultCapacity: Int
    private let lock = NSLock()

    public init(maxPoolSize: Int = 32, defaultCapacity: Int = 4096) {
        self.allocator = ByteBufferAllocator()
        self.maxPoolSize = maxPoolSize
        self.defaultCapacity = defaultCapacity
    }

    public func acquire(minimumCapacity: Int? = nil) -> ByteBuffer {
        let capacity = minimumCapacity ?? defaultCapacity

        lock.lock()
        defer { lock.unlock() }

        if let index = pool.firstIndex(where: { $0.capacity >= capacity }) {
            var buffer = pool.remove(at: index)
            buffer.clear()
            return buffer
        }

        return allocator.buffer(capacity: capacity)
    }

    public func release(_ buffer: ByteBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard pool.count < maxPoolSize else { return }

        var mutableBuffer = buffer
        mutableBuffer.clear()
        pool.append(mutableBuffer)
    }

    public var pooledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pool.count
    }

    public func drain() {
        lock.lock()
        defer { lock.unlock() }
        pool.removeAll()
    }
}

public actor BufferPoolActor {
    private let allocator: ByteBufferAllocator
    private var pool: [ByteBuffer] = []
    private let maxPoolSize: Int
    private let defaultCapacity: Int

    public init(maxPoolSize: Int = 32, defaultCapacity: Int = 4096) {
        self.allocator = ByteBufferAllocator()
        self.maxPoolSize = maxPoolSize
        self.defaultCapacity = defaultCapacity
    }

    public func acquire(minimumCapacity: Int? = nil) -> ByteBuffer {
        let capacity = minimumCapacity ?? defaultCapacity

        if let index = pool.firstIndex(where: { $0.capacity >= capacity }) {
            var buffer = pool.remove(at: index)
            buffer.clear()
            return buffer
        }

        return allocator.buffer(capacity: capacity)
    }

    public func release(_ buffer: ByteBuffer) {
        guard pool.count < maxPoolSize else { return }
        var mutableBuffer = buffer
        mutableBuffer.clear()
        pool.append(mutableBuffer)
    }

    public var pooledCount: Int { pool.count }

    public func drain() { pool.removeAll() }
}
