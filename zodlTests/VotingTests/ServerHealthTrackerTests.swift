#if VOTING_ENABLED
import Foundation
import Testing
import os
@testable import zodl_internal

// Exercises the deferred-probing lifecycle: configuration never probes, sweeps
// are one-shot and coalescing, and the circuit breaker keeps its semantics.
// Every test uses its own tracker instance (never `.shared`), so this suite is
// safe to run in parallel with the rest of the target.
struct ServerHealthTrackerTests {
    private static let serverA = "https://a.example.com"
    private static let serverB = "https://b.example.com"
    private static let serverC = "https://c.example.com"

    private enum ProbeError: Error {
        case badFixture
        case unreachable
    }

    private final class ProbeRecorder: Sendable {
        private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])

        func record(_ url: String) {
            recorded.withLock { $0.append(url) }
        }

        var urls: [String] {
            recorded.withLock { $0 }
        }
    }

    private static func response(_ statusCode: Int, for request: URLRequest) throws -> (Data, URLResponse) {
        guard
            let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        else {
            throw ProbeError.badFixture
        }
        return (Data(), response)
    }

    @Test func configureAlonePerformsNoProbes() async {
        let tracker = ServerHealthTracker()
        let recorder = ProbeRecorder()
        await tracker.configure(serverURLs: [Self.serverA]) { request in
            recorder.record(request.url?.absoluteString ?? "")
            throw ProbeError.unreachable
        }

        await Task.yield()

        #expect(recorder.urls.isEmpty)
    }

    @Test func startProbeSweepProbesEveryConfiguredServerOnce() async throws {
        let tracker = ServerHealthTracker()
        let recorder = ProbeRecorder()
        await tracker.configure(serverURLs: [Self.serverA, Self.serverB, Self.serverC]) { request in
            recorder.record(request.url?.absoluteString ?? "")
            return try Self.response(200, for: request)
        }

        let sweep = try #require(await tracker.startProbeSweep())
        await sweep.value

        let expected = Set([Self.serverA, Self.serverB, Self.serverC].map { "\($0)/shielded-vote/v1/status" })
        #expect(Set(recorder.urls) == expected)
        #expect(recorder.urls.count == 3)
        let healthy = await tracker.healthyServers()
        #expect(Set(healthy) == Set([Self.serverA, Self.serverB, Self.serverC]))
    }

    // A non-200 status is a probe failure just like a transport error; three
    // sweeps' worth of them open the circuit.
    @Test func repeatedSweepFailuresOpenTheCircuit() async throws {
        let tracker = ServerHealthTracker()
        let recorder = ProbeRecorder()
        await tracker.configure(serverURLs: [Self.serverA, Self.serverB]) { request in
            let url = request.url?.absoluteString ?? ""
            recorder.record(url)
            guard url.hasPrefix(Self.serverA) else {
                return try Self.response(200, for: request)
            }
            return try Self.response(503, for: request)
        }

        // Each call after a finished sweep starts a fresh one (returns non-nil).
        for _ in 1...3 {
            let sweep = try #require(await tracker.startProbeSweep())
            await sweep.value
        }

        #expect(await tracker.healthyServers() == [Self.serverB])
        #expect(recorder.urls.filter { $0.hasPrefix(Self.serverA) }.count == 3)
    }

    @Test func sweepCoalescesWhileInFlight() async throws {
        let tracker = ServerHealthTracker()
        let recorder = ProbeRecorder()
        let gate = AsyncStream<Void>.makeStream()
        await tracker.configure(serverURLs: [Self.serverA]) { request in
            recorder.record(request.url?.absoluteString ?? "")
            for await _ in gate.stream { }
            return try Self.response(200, for: request)
        }

        let first = try #require(await tracker.startProbeSweep())
        // The sweep task is registered synchronously inside the actor, so a
        // second call must coalesce even before any probe request lands.
        #expect(await tracker.startProbeSweep() == nil)

        gate.continuation.finish()
        await first.value

        #expect(recorder.urls.count == 1)
    }

    @Test func unconfiguredTrackerNeverSweeps() async {
        let tracker = ServerHealthTracker()

        #expect(await tracker.startProbeSweep() == nil)
    }

    @Test func configureCancelsInFlightSweepAndResetsState() async throws {
        let tracker = ServerHealthTracker()
        let recorder = ProbeRecorder()
        let gate = AsyncStream<Void>.makeStream()
        await tracker.configure(serverURLs: [Self.serverA]) { request in
            recorder.record("old:\(request.url?.absoluteString ?? "")")
            for await _ in gate.stream { }
            throw ProbeError.unreachable
        }
        let first = try #require(await tracker.startProbeSweep())

        await tracker.configure(serverURLs: [Self.serverB]) { request in
            recorder.record("new:\(request.url?.absoluteString ?? "")")
            return try Self.response(200, for: request)
        }
        gate.continuation.finish()
        await first.value

        let second = try #require(await tracker.startProbeSweep())
        await second.value

        #expect(await tracker.healthyServers() == [Self.serverB])
        #expect(recorder.urls.filter { $0.hasPrefix("new:") }.count == 1)
    }

    @Test func threeRecordedFailuresOpenTheCircuit() async {
        let tracker = ServerHealthTracker()
        await tracker.configure(serverURLs: [Self.serverA, Self.serverB]) { _ in
            throw ProbeError.unreachable
        }

        for _ in 1...3 {
            await tracker.recordFailure(for: Self.serverA)
        }

        #expect(await tracker.healthyServers() == [Self.serverB])
    }

    @Test func allOpenFallsBackToFullList() async {
        let tracker = ServerHealthTracker(cooldownInterval: 10_000)
        await tracker.configure(serverURLs: [Self.serverA, Self.serverB]) { _ in
            throw ProbeError.unreachable
        }

        for _ in 1...3 {
            await tracker.recordFailure(for: Self.serverA)
            await tracker.recordFailure(for: Self.serverB)
        }

        #expect(Set(await tracker.healthyServers()) == Set([Self.serverA, Self.serverB]))
    }

    @Test func recordSuccessReclosesTheCircuit() async {
        let tracker = ServerHealthTracker(cooldownInterval: 10_000)
        await tracker.configure(serverURLs: [Self.serverA, Self.serverB]) { _ in
            throw ProbeError.unreachable
        }
        for _ in 1...3 {
            await tracker.recordFailure(for: Self.serverA)
        }
        #expect(await tracker.healthyServers() == [Self.serverB])

        await tracker.recordSuccess(for: Self.serverA)

        #expect(Set(await tracker.healthyServers()) == Set([Self.serverA, Self.serverB]))
    }

    @Test func cooldownExpiryReadmitsOpenServer() async {
        let expired = ServerHealthTracker(cooldownInterval: 0)
        await expired.configure(serverURLs: [Self.serverA, Self.serverB]) { _ in
            throw ProbeError.unreachable
        }
        for _ in 1...3 {
            await expired.recordFailure(for: Self.serverA)
        }
        #expect(Set(await expired.healthyServers()) == Set([Self.serverA, Self.serverB]))

        let cooling = ServerHealthTracker(cooldownInterval: 10_000)
        await cooling.configure(serverURLs: [Self.serverA, Self.serverB]) { _ in
            throw ProbeError.unreachable
        }
        for _ in 1...3 {
            await cooling.recordFailure(for: Self.serverA)
        }
        #expect(await cooling.healthyServers() == [Self.serverB])
    }
}
#endif
