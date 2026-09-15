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
