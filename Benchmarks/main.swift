import Foundation
import NIOCore
import TunnelCore
#if os(Linux)
import Glibc
#endif

struct Benchmark {
    let name: String
    let iterations: Int
    let warmupIterations: Int
    let operation: () async throws -> Void

    init(name: String, iterations: Int = 10000, warmupIterations: Int = 100, operation: @escaping () async throws -> Void) {
        self.name = name
        self.iterations = iterations
        self.warmupIterations = warmupIterations
        self.operation = operation
    }

    func run() async throws -> BenchmarkResult {
        for _ in 0..<warmupIterations {
            try await operation()
        }

        let start = currentTime()
        for _ in 0..<iterations {
            try await operation()
        }
        let elapsed = currentTime() - start

        return BenchmarkResult(
            name: name,
            iterations: iterations,
            totalTime: elapsed,
            averageTime: elapsed / Double(iterations),
            opsPerSecond: Double(iterations) / elapsed
        )
    }

    private func currentTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}

struct BenchmarkResult: CustomStringConvertible {
    let name: String
    let iterations: Int
    let totalTime: TimeInterval
    let averageTime: TimeInterval
    let opsPerSecond: Double

    var description: String {
        let avgMicro = averageTime * 1_000_000
        return "\(name): \(String(format: "%.2f", opsPerSecond)) ops/s, avg: \(String(format: "%.2f", avgMicro))µs"
    }
}

@main
struct BenchmarkRunner {
    static func main() async throws {
        print("Running Cok Benchmarks\n")
        print(String(repeating: "=", count: 60))

        let results = try await runAllBenchmarks()

        print("\nResults:")
        print(String(repeating: "-", count: 60))
        for result in results {
            print(result)
        }
    }

    static func runAllBenchmarks() async throws -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []

        results.append(try await bufferPoolBenchmark())
        results.append(try await protocolFrameEncodeBenchmark())
        results.append(try await protocolFrameDecodeBenchmark())
        results.append(try await jsonCodecEncodeBenchmark())
        results.append(try await jsonCodecDecodeBenchmark())
        results.append(try await rateLimiterBenchmark())
        results.append(try await subdomainValidatorBenchmark())

        return results
    }

    static func bufferPoolBenchmark() async throws -> BenchmarkResult {
        let pool = BufferPool()
        return try await Benchmark(name: "BufferPool acquire/release", iterations: 100000) {
            let buffer = pool.acquire(minimumCapacity: 4096)
            pool.release(buffer)
        }.run()
    }

    static func protocolFrameEncodeBenchmark() async throws -> BenchmarkResult {
        let allocator = ByteBufferAllocator()
        var payload = allocator.buffer(capacity: 1024)
        payload.writeString(String(repeating: "x", count: 1024))
        let frame = try ProtocolFrame(messageType: .httpRequest, payload: payload)

        return try await Benchmark(name: "ProtocolFrame encode", iterations: 100000) {
            _ = frame.encode()
        }.run()
    }

    static func protocolFrameDecodeBenchmark() async throws -> BenchmarkResult {
        let allocator = ByteBufferAllocator()
        var payload = allocator.buffer(capacity: 1024)
        payload.writeString(String(repeating: "x", count: 1024))
        let frame = try ProtocolFrame(messageType: .httpRequest, payload: payload)
        let encoded = frame.encode()

        return try await Benchmark(name: "ProtocolFrame decode", iterations: 100000) {
            var buffer = encoded
            _ = try ProtocolFrame.decode(from: &buffer)
        }.run()
    }

    static func jsonCodecEncodeBenchmark() async throws -> BenchmarkResult {
        let codec = JSONMessageCodec()
        let message = PingMessage(timestamp: Date())

        return try await Benchmark(name: "JSON encode", iterations: 100000) {
            _ = try codec.encode(message)
        }.run()
    }

    static func jsonCodecDecodeBenchmark() async throws -> BenchmarkResult {
        let codec = JSONMessageCodec()
        let message = PingMessage(timestamp: Date())
        let buffer = try codec.encode(message)

        return try await Benchmark(name: "JSON decode", iterations: 100000) {
            _ = try codec.decode(PingMessage.self, from: buffer)
        }.run()
    }

    static func rateLimiterBenchmark() async throws -> BenchmarkResult {
        let limiter = RateLimiter(configuration: .http)

        return try await Benchmark(name: "RateLimiter tryConsume", iterations: 10000) {
            _ = await limiter.tryConsume(identifier: "test-client")
        }.run()
    }

    static func subdomainValidatorBenchmark() async throws -> BenchmarkResult {
        return try await Benchmark(name: "SubdomainValidator validate", iterations: 100000) {
            _ = SubdomainValidator.isValid("my-test-subdomain123")
        }.run()
    }
}
