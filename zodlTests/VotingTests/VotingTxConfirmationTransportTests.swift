#if VOTING_ENABLED
//
//  VotingTxConfirmationTransportTests.swift
//  zodlTests
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VotingTxConfirmationTransportTests {
    private struct BoundedCall: Equatable, Sendable {
        let url: URL?
        let retryLimit: UInt8
        let timeoutMilliseconds: UInt64
    }

    @Test func aProtectedConfirmationUsesTheBoundedSDKWithTenSecondMaximumAndNoNativeRetry() async throws {
        let calls = SignalledRecords<BoundedCall>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, timeoutMilliseconds in
            try await SDKSynchronizerClient.performBoundedTorGET(
                request,
                timeoutMilliseconds: timeoutMilliseconds
            ) { request, retryLimit, timeoutMilliseconds in
                calls.record(BoundedCall(
                    url: request.url,
                    retryLimit: retryLimit,
                    timeoutMilliseconds: timeoutMilliseconds
                ))
                return (Data(), Self.response(for: request, statusCode: 404))
            }
        }

        _ = try await routeVotingRequest(
            URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc")!),
            fast: true,
            torTimeout: .seconds(30),
            access: .protected,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { _, _ in
                Issue.record("protected confirmation escaped to the direct transport")
                return (Data(), URLResponse())
            }
        )

        #expect(calls.values == [BoundedCall(
            url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc"),
            retryLimit: 0,
            timeoutMilliseconds: 10_000
        )])
    }

    @Test func aProtectedConfirmationClipsTheBoundedSDKToItsRemainingBudget() async throws {
        let timeouts = SignalledRecords<UInt64>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, timeoutMilliseconds in
            timeouts.record(timeoutMilliseconds)
            return (Data(), Self.response(for: request, statusCode: 404))
        }

        _ = try await routeVotingRequest(
            URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc")!),
            fast: true,
            torTimeout: .milliseconds(2_500),
            access: .protected,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { _, _ in (Data(), URLResponse()) }
        )

        #expect(timeouts.values == [2_500])
    }

    @Test func aZeroOrSubmillisecondBudgetStartsNoBoundedSDKRequest() async {
        let calls = SignalledRecords<Void>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, _ in
            calls.recordCall()
            return (Data(), Self.response(for: request, statusCode: 404))
        }
        let configuredSDK = sdkSynchronizer
        let request = URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc")!)

        for timeout in [Duration.zero, .nanoseconds(999_999)] {
            do {
                _ = try await routeVotingRequest(
                    request,
                    fast: true,
                    torTimeout: timeout,
                    access: .protected,
                    sdkSynchronizer: configuredSDK,
                    directRequest: { _, _ in (Data(), URLResponse()) }
                )
                Issue.record("a non-positive native timeout was admitted")
            } catch let error as URLError {
                #expect(error.code == .timedOut)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        #expect(calls.isEmpty)
    }

    @Test func cancellationBeforeAdmissionStartsNoBoundedSDKRequest() async {
        let enter = ResumableGate()
        let calls = SignalledRecords<Void>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, _ in
            calls.recordCall()
            return (Data(), Self.response(for: request, statusCode: 404))
        }
        let configuredSDK = sdkSynchronizer
        let request = URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc")!)

        let task = Task {
            await enter.wait()
            return try await routeVotingRequest(
                request,
                fast: true,
                torTimeout: .seconds(10),
                access: .protected,
                sdkSynchronizer: configuredSDK,
                directRequest: { _, _ in (Data(), URLResponse()) }
            )
        }
        task.cancel()
        enter.open()

        guard case .failure(let error) = await task.result else {
            Issue.record("a cancelled confirmation request succeeded")
            return
        }
        #expect(error is CancellationError)
        #expect(calls.isEmpty)
    }

    @Test func activeCancellationWaitsForTheOwnedBoundedSDKRequestToReturn() async {
        let started = ResumableGate()
        let release = ResumableGate()
        let completed = SignalledRecords<Void>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, _ in
            started.open()
            await release.wait()
            return (Data(), Self.response(for: request, statusCode: 404))
        }
        let configuredSDK = sdkSynchronizer
        let request = URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc")!)

        let task = Task {
            defer { completed.recordCall() }
            return try await routeVotingRequest(
                request,
                fast: true,
                torTimeout: .seconds(10),
                access: .protected,
                sdkSynchronizer: configuredSDK,
                directRequest: { _, _ in (Data(), URLResponse()) }
            )
        }
        await started.wait()
        task.cancel()
        #expect(completed.isEmpty)

        release.open()
        guard case .failure(let error) = await task.result else {
            Issue.record("a cancelled active confirmation request succeeded")
            return
        }
        #expect(error is CancellationError)
        #expect(completed.count == 1)
    }

    @Test func aConfirmationFallbackStartsItsNextOwnedRequestOnlyAfterTheFirstReturns() async throws {
        let calls = SignalledRecords<URL?>()
        let firstStarted = ResumableGate()
        let releaseFirst = ResumableGate()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, _ in
            let ordinal = calls.record(request.url)
            if ordinal == 1 {
                firstStarted.open()
                await releaseFirst.wait()
                return (Data(), Self.response(for: request, statusCode: 500))
            }
            return (Data(), Self.response(for: request, statusCode: 404))
        }
        let configuredSDK = sdkSynchronizer

        let task = Task {
            try await VotingTxConfirmationWalk.run(
                servers: ["https://vote-a.example", "https://vote-b.example"],
                preferredServerURL: nil,
                remainingBudget: .seconds(20),
                clock: ContinuousClock()
            ) { base, remainingBudget in
                try await lookupTxConfirmation(
                    base: base,
                    txHash: "abc",
                    remainingBudget: remainingBudget
                ) { request, timeout in
                    try await routeVotingRequest(
                        request,
                        fast: true,
                        torTimeout: timeout,
                        access: .protected,
                        sdkSynchronizer: configuredSDK,
                        directRequest: { _, _ in (Data(), URLResponse()) }
                    )
                }
            }
        }

        await firstStarted.wait()
        #expect(calls.count == 1)
        releaseFirst.open()
        await calls.countReached(2)
        #expect(try await task.value == nil)
        #expect(calls.values == [
            URL(string: "https://vote-a.example/shielded-vote/v1/tx/abc"),
            URL(string: "https://vote-b.example/shielded-vote/v1/tx/abc")
        ])
    }

    @Test func aProtectedBroadcastKeepsTheLegacySDKTransportAndItsRetryPolicy() async throws {
        let retries = SignalledRecords<UInt8>()
        let boundedCalls = SignalledRecords<Void>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { request in
            try await SDKSynchronizerClient.performLegacyTorRequest(request) { request, retryLimit in
                retries.record(retryLimit)
                return (Data(), Self.response(for: request, statusCode: 200))
            }
        }
        sdkSynchronizer.boundedTorGET = { request, _ in
            boundedCalls.recordCall()
            return (Data(), Self.response(for: request, statusCode: 200))
        }
        var request = URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/cast-vote")!)
        request.httpMethod = "POST"

        _ = try await routeVotingRequest(
            request,
            fast: false,
            torTimeout: nil,
            access: .protected,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { _, _ in
                Issue.record("protected broadcast escaped to the direct transport")
                return (Data(), URLResponse())
            }
        )

        #expect(retries.values == [3])
        #expect(boundedCalls.isEmpty)
    }

    @Test func aStalledDirectResponseTimesOutAndStopsItsTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingTxConfirmationURLProtocol.self]
        let request = URLRequest(url: URL(string: "https://vote.example/shielded-vote/v1/tx/abc")!)

        do {
            _ = try await withTimeout(.milliseconds(500)) {
                try await performDirectTxConfirmationRequest(
                    request,
                    resourceTimeout: .milliseconds(100),
                    configuration: configuration
                )
            }
            Issue.record("a stalled confirmation transport returned without timing out")
        } catch is URLError {
            // The request's own resource deadline fired.
        } catch {
            Issue.record("the request outlived its remaining budget: \(error)")
        }

        await StallingTxConfirmationURLProtocol.started.countReached(1)
        await StallingTxConfirmationURLProtocol.stopped.countReached(1)
        #expect(StallingTxConfirmationURLProtocol.started.count == 1)
        #expect(StallingTxConfirmationURLProtocol.stopped.count == 1)
    }

    @Test func lookupRoutesItsRemainingBudgetIntoTheRequest() async throws {
        let receivedBudgets = SignalledRecords<Duration>()
        let body = Data("{\"height\":100,\"code\":0}".utf8)

        let result = try await lookupTxConfirmation(
            base: "https://vote.example",
            txHash: "abc",
            remainingBudget: .seconds(4)
        ) { request, remainingBudget in
            receivedBudgets.record(remainingBudget)
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        #expect(result == .confirmed(TxConfirmation(height: 100, code: 0)))
        #expect(receivedBudgets.values == [.seconds(4)])
    }

    @Test func configurationDelayThatExhaustsTheBudgetStartsNoLookup() async throws {
        let clock = TestClock()
        let configurationStarted = SignalledRecords<Void>()
        let releaseConfiguration = ResumableGate()
        let receivedBudgets = SignalledRecords<Swift.Duration>()

        let task = Task {
            try await fetchTxConfirmationFromConfiguredServers(
                preferredServerURL: nil,
                remainingBudget: .seconds(5),
                clock: clock,
                configuredServerURLs: {
                    configurationStarted.recordCall()
                    await releaseConfiguration.wait()
                    return ["https://vote.example"]
                },
                lookup: { _, remainingBudget in
                    receivedBudgets.record(remainingBudget)
                    return .confirmed(TxConfirmation(height: 100, code: 0))
                }
            )
        }

        await configurationStarted.countReached(1)
        await clock.advance(by: .seconds(5))
        releaseConfiguration.open()
        let result = try await task.value

        #expect(result == nil)
        #expect(receivedBudgets.isEmpty)
    }

    @Test func configurationDelayIsDeductedFromTheFirstLookupBudget() async throws {
        let clock = TestClock()
        let configurationStarted = SignalledRecords<Void>()
        let releaseConfiguration = ResumableGate()
        let receivedBudgets = SignalledRecords<Swift.Duration>()
        let confirmation = TxConfirmation(height: 100, code: 0)

        let task = Task {
            try await fetchTxConfirmationFromConfiguredServers(
                preferredServerURL: nil,
                remainingBudget: .seconds(10),
                clock: clock,
                configuredServerURLs: {
                    configurationStarted.recordCall()
                    await releaseConfiguration.wait()
                    return ["https://vote.example"]
                },
                lookup: { _, remainingBudget in
                    receivedBudgets.record(remainingBudget)
                    return .confirmed(confirmation)
                }
            )
        }

        await configurationStarted.countReached(1)
        await clock.advance(by: .seconds(4))
        releaseConfiguration.open()
        let result = try await task.value

        #expect(result == confirmation)
        #expect(receivedBudgets.values == [.seconds(6)])
    }

    @Test func configurationDelayDoesNotCreateABudgetForAOneShotLookup() async throws {
        let clock = TestClock()
        let configurationStarted = SignalledRecords<Void>()
        let releaseConfiguration = ResumableGate()
        let receivedBudgets = SignalledRecords<Swift.Duration>()
        let confirmation = TxConfirmation(height: 100, code: 0)

        let task = Task {
            try await fetchTxConfirmationFromConfiguredServers(
                preferredServerURL: nil,
                remainingBudget: nil,
                clock: clock,
                configuredServerURLs: {
                    configurationStarted.recordCall()
                    await releaseConfiguration.wait()
                    return ["https://vote.example"]
                },
                lookup: { _, remainingBudget in
                    receivedBudgets.record(remainingBudget)
                    return .confirmed(confirmation)
                }
            )
        }

        await configurationStarted.countReached(1)
        await clock.advance(by: .seconds(100))
        releaseConfiguration.open()
        let result = try await task.value

        #expect(result == confirmation)
        #expect(receivedBudgets.values == [.seconds(10)])
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private final class StallingTxConfirmationURLProtocol: URLProtocol, @unchecked Sendable {
    static let started = SignalledRecords<Void>()
    static let stopped = SignalledRecords<Void>()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.started.recordCall()
    }

    override func stopLoading() {
        Self.stopped.recordCall()
    }
}
#endif
