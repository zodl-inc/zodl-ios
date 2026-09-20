#if VOTING_ENABLED
//
//  VotingPollLoadingTransportTests.swift
//  zodlTests
//

import ComposableArchitecture
import CryptoKit
import Foundation
import os
import Testing
@testable import zodl_internal
@preconcurrency import enum ZcashLightClientKit.ZcashError

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VotingPollLoadingTransportTests {
    private enum PollLoadingTestError: Error {
        case legacyTransportUsed
    }

    @Test func protectedRoundListUsesBoundedTransport() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }

        let config = Self.serviceConfig(voteServerURLs: ["https://rounds.example"])
        let calls = OSAllocatedUnfairLock(initialState: [UInt64]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, timeout in
            #expect(request.url?.path == "/shielded-vote/v1/rounds")
            calls.withLock { $0.append(timeout) }
            return (
                Data("{\"rounds\":[]}".utf8),
                Self.response(for: request, statusCode: 200)
            )
        }
        let configuredSDK = sdkSynchronizer

        let rounds = try await Self.withRestoredConfigStore {
            try await withDependencies {
                $0.sdkSynchronizer = configuredSDK
            } operation: {
                await SvAPIConfigStore.shared.configure(from: config)
                return try await VotingAPIClient.liveValue.fetchAllRounds()
            }
        }

        #expect(rounds.isEmpty)
        #expect(calls.withLock { $0 } == [15_000])
    }

    @Test func pollLoadingBudgetClipsEachRequestAndRejectsAnExhaustedStage() async throws {
        let clock = ContinuousClock()
        let origin = clock.now
        let now = OSAllocatedUnfairLock(initialState: origin)
        let budget = VotingPollLoadingBudget(now: { now.withLock { $0 } })
        let timeouts = OSAllocatedUnfairLock(initialState: [UInt64]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, timeout in
            timeouts.withLock { $0.append(timeout) }
            return (Data(), Self.response(for: request, statusCode: 200))
        }
        let request = URLRequest(url: URL(string: "https://vote.example/rounds")!)

        _ = try await routePollLoadingRequest(
            request,
            budget: budget,
            access: .protected,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { _, _ in (Data(), URLResponse()) }
        )
        now.withLock { $0 = origin.advanced(by: .seconds(50)) }
        _ = try await routePollLoadingRequest(
            request,
            budget: budget,
            access: .protected,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { _, _ in (Data(), URLResponse()) }
        )
        now.withLock { $0 = origin.advanced(by: .seconds(60)) }

        do {
            _ = try await routePollLoadingRequest(
                request,
                budget: budget,
                access: .protected,
                sdkSynchronizer: sdkSynchronizer,
                directRequest: { _, _ in (Data(), URLResponse()) }
            )
            Issue.record("an exhausted poll-loading stage started another request")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }

        #expect(timeouts.withLock { $0 } == [15_000, 10_000])
    }

    @Test func directPollLoadingIgnoresTheTorBudget() async throws {
        let clock = ContinuousClock()
        let origin = clock.now
        let now = OSAllocatedUnfairLock(initialState: origin)
        let budget = VotingPollLoadingBudget(now: { now.withLock { $0 } })
        now.withLock { $0 = origin.advanced(by: .seconds(60)) }
        let directCalls = OSAllocatedUnfairLock(initialState: 0)
        let boundedCalls = OSAllocatedUnfairLock(initialState: 0)
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, _ in
            boundedCalls.withLock { $0 += 1 }
            return (Data(), Self.response(for: request, statusCode: 200))
        }
        let request = URLRequest(url: URL(string: "https://vote.example/rounds")!)

        let (data, _) = try await routePollLoadingRequest(
            request,
            budget: budget,
            access: .direct,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { request, fast in
                #expect(!fast)
                directCalls.withLock { $0 += 1 }
                return (Data("direct".utf8), Self.response(for: request, statusCode: 200))
            }
        )

        #expect(data == Data("direct".utf8))
        #expect(directCalls.withLock { $0 } == 1)
        #expect(boundedCalls.withLock { $0 } == 0)
    }

    @Test func submillisecondPollLoadingBudgetStartsNoBoundedRequest() async {
        let clock = ContinuousClock()
        let origin = clock.now
        let now = OSAllocatedUnfairLock(initialState: origin)
        let budget = VotingPollLoadingBudget(now: { now.withLock { $0 } })
        now.withLock {
            $0 = origin.advanced(by: Duration.seconds(60) - .nanoseconds(999_999))
        }
        let boundedCalls = OSAllocatedUnfairLock(initialState: 0)
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.boundedTorGET = { request, _ in
            boundedCalls.withLock { $0 += 1 }
            return (Data(), Self.response(for: request, statusCode: 200))
        }
        let request = URLRequest(url: URL(string: "https://vote.example/rounds")!)

        do {
            _ = try await routePollLoadingRequest(
                request,
                budget: budget,
                access: .protected,
                sdkSynchronizer: sdkSynchronizer,
                directRequest: { _, _ in
                    Issue.record("protected poll loading used direct transport")
                    return (Data(), URLResponse())
                }
            )
            Issue.record("a sub-millisecond poll-loading timeout was admitted")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(boundedCalls.withLock { $0 } == 0)
    }

    @Test func protectedRoundListFallsThroughAfterNativeTorTransportFailure() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        let calls = OSAllocatedUnfairLock(initialState: [URL]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, _ in
            let url = try #require(request.url)
            calls.withLock { $0.append(url) }
            if request.url?.host == "first.example" {
                throw ZcashError.rustTorHttpRequest("offline")
            }
            return (
                Data("{\"rounds\":[]}".utf8),
                Self.response(for: request, statusCode: 200)
            )
        }
        let configuredSDK = sdkSynchronizer

        let rounds = try await Self.withRestoredConfigStore {
            try await withDependencies {
                $0.sdkSynchronizer = configuredSDK
            } operation: {
                await SvAPIConfigStore.shared.configure(
                    from: Self.serviceConfig(
                        voteServerURLs: ["https://first.example", "https://second.example"]
                    )
                )
                return try await VotingAPIClient.liveValue.fetchAllRounds()
            }
        }

        #expect(rounds.isEmpty)
        #expect(calls.withLock { $0.map(\.host) } == ["first.example", "second.example"])
    }

    @Test func cancelledProtectedRoundListDoesNotTryAnotherServer() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        let started = ResumableGate()
        let release = ResumableGate()
        let calls = OSAllocatedUnfairLock(initialState: [URL]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, _ in
            let url = try #require(request.url)
            calls.withLock { $0.append(url) }
            started.open()
            await release.wait()
            throw ZcashError.rustTorHttpRequest("offline")
        }
        let configuredSDK = sdkSynchronizer

        await Self.withRestoredConfigStore {
            let task = Task {
                try await withDependencies {
                    $0.sdkSynchronizer = configuredSDK
                } operation: {
                    await SvAPIConfigStore.shared.configure(
                        from: Self.serviceConfig(
                            voteServerURLs: ["https://only.example"]
                        )
                    )
                    return try await VotingAPIClient.liveValue.fetchAllRounds()
                }
            }
            await started.wait()
            task.cancel()
            release.open()
            guard case .failure(let error) = await task.result else {
                Issue.record("a cancelled poll-loading request succeeded")
                return
            }
            #expect(error is CancellationError)
        }
        #expect(calls.withLock { $0.map(\.host) } == ["only.example"])
    }

    @Test func protectedConfigLoadingUsesOneBoundedStageForStaticAndDynamicFetches() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        let clock = ContinuousClock()
        let origin = clock.now
        let now = OSAllocatedUnfairLock(initialState: origin)
        let budget = VotingPollLoadingBudget(now: { now.withLock { $0 } })
        let dynamicURL = "https://dynamic.example/config.json"
        let staticData = Data(Self.staticConfigJSON(dynamicURL: dynamicURL).utf8)
        let digest = Data(SHA256.hash(data: staticData)).map { String(format: "%02x", $0) }.joined()
        let source = try PinnedConfigSource.parse(
            "https://static.example/config.json?checksum=sha256:\(digest)"
        )
        let requests = OSAllocatedUnfairLock(initialState: [(URL?, UInt64)]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, timeout in
            requests.withLock { $0.append((request.url, timeout)) }
            let data: Data
            if request.url?.host == "static.example" {
                data = staticData
                now.withLock { $0 = origin.advanced(by: .seconds(50)) }
            } else {
                data = Data(Self.dynamicConfigJSON.utf8)
            }
            return (data, Self.response(for: request, statusCode: 200))
        }
        let configuredSDK = sdkSynchronizer

        let config = try await Self.withRestoredConfigStore {
            try await withDependencies {
                $0.sdkSynchronizer = configuredSDK
            } operation: {
                try await fetchVotingServiceConfig(
                    override: source,
                    pollLoadingBudget: budget
                )
            }
        }

        #expect(config.voteServers.map(\.url) == ["https://rounds.example"])
        let observed = requests.withLock { $0 }
        #expect(observed.map { $0.0?.host } == ["static.example", "dynamic.example"])
        #expect(observed.map { $0.1 } == [15_000, 10_000])
    }

    @Test func cancelledFinalStaticConfigRequestPreservesCancellationAfterNativeFailure() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        let staticData = Data(Self.staticConfigJSON(dynamicURL: "https://dynamic.example/config.json").utf8)
        let digest = Data(SHA256.hash(data: staticData)).map { String(format: "%02x", $0) }.joined()
        let source = try PinnedConfigSource.parse(
            "https://static.example/config.json?checksum=sha256:\(digest)"
        )
        let started = ResumableGate()
        let release = ResumableGate()
        let requests = OSAllocatedUnfairLock(initialState: [URL]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, _ in
            let url = try #require(request.url)
            requests.withLock { $0.append(url) }
            started.open()
            await release.wait()
            throw ZcashError.rustTorHttpRequest("offline")
        }
        let configuredSDK = sdkSynchronizer

        await Self.withRestoredConfigStore {
            let task = Task {
                try await withDependencies {
                    $0.sdkSynchronizer = configuredSDK
                } operation: {
                    try await VotingAPIClient.liveValue.fetchServiceConfig(source)
                }
            }
            await started.wait()
            task.cancel()
            release.open()
            guard case .failure(let error) = await task.result else {
                Issue.record("a cancelled final static config request succeeded")
                return
            }
            #expect(error is CancellationError)
        }
        #expect(requests.withLock { $0.map(\.host) } == ["static.example"])
    }

    @Test func cancelledFinalDynamicConfigRequestPreservesCancellationAfterNativeFailure() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        let dynamicURL = "https://dynamic.example/config.json"
        let staticData = Data(Self.staticConfigJSON(dynamicURL: dynamicURL).utf8)
        let digest = Data(SHA256.hash(data: staticData)).map { String(format: "%02x", $0) }.joined()
        let source = try PinnedConfigSource.parse(
            "https://static.example/config.json?checksum=sha256:\(digest)"
        )
        let dynamicStarted = ResumableGate()
        let releaseDynamic = ResumableGate()
        let requests = OSAllocatedUnfairLock(initialState: [URL]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, _ in
            let url = try #require(request.url)
            requests.withLock { $0.append(url) }
            if url.host == "static.example" {
                return (staticData, Self.response(for: request, statusCode: 200))
            }
            dynamicStarted.open()
            await releaseDynamic.wait()
            throw ZcashError.rustTorHttpRequest("offline")
        }
        let configuredSDK = sdkSynchronizer

        await Self.withRestoredConfigStore {
            let task = Task {
                try await withDependencies {
                    $0.sdkSynchronizer = configuredSDK
                } operation: {
                    try await VotingAPIClient.liveValue.fetchServiceConfig(source)
                }
            }
            await dynamicStarted.wait()
            task.cancel()
            releaseDynamic.open()
            guard case .failure(let error) = await task.result else {
                Issue.record("a cancelled final dynamic config request succeeded")
                return
            }
            #expect(error is CancellationError)
        }
        #expect(requests.withLock { $0.map(\.host) } == ["static.example", "dynamic.example"])
    }

    @Test func protectedMissingEndorsementsRetainEmptyListSemantics() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, timeout in
            #expect(timeout == 15_000)
            #expect(request.url?.path == "/shielded-vote/v1/endorsed-rounds/zodl")
            return (Data(), Self.response(for: request, statusCode: 404))
        }
        let configuredSDK = sdkSynchronizer

        let ids = try await Self.withRestoredConfigStore {
            try await withDependencies {
                $0.sdkSynchronizer = configuredSDK
            } operation: {
                await SvAPIConfigStore.shared.configure(
                    from: Self.serviceConfig(voteServerURLs: ["https://rounds.example"])
                )
                return try await VotingAPIClient.liveValue.fetchZodlEndorsedRoundIds()
            }
        }

        #expect(ids.isEmpty)
    }

    @Test func protectedEndorsementsParseAfterNativeTorFailover() async throws {
        @Shared(.inMemory(.swapAPIAccess))
        var access: WalletStorage.SwapAPIAccess = .direct
        let previousAccess = access
        $access.withLock { $0 = .protected }
        defer { $access.withLock { $0 = previousAccess } }
        let expectedRoundId = String(repeating: "ab", count: 32)
        let responseData = Data("{\"vote_round_ids\":[\"\(expectedRoundId)\"]}".utf8)
        let calls = OSAllocatedUnfairLock(initialState: [(URL?, UInt64)]())
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { _ in
            Issue.record("endorsement loading used legacy Tor transport")
            throw PollLoadingTestError.legacyTransportUsed
        }
        sdkSynchronizer.boundedTorGET = { request, timeout in
            #expect(request.url?.path == "/shielded-vote/v1/endorsed-rounds/zodl")
            calls.withLock { $0.append((request.url, timeout)) }
            if request.url?.host == "first.example" {
                throw ZcashError.rustTorHttpRequest("offline")
            }
            return (responseData, Self.response(for: request, statusCode: 200))
        }
        let configuredSDK = sdkSynchronizer

        let ids = try await Self.withRestoredConfigStore {
            try await withDependencies {
                $0.sdkSynchronizer = configuredSDK
            } operation: {
                await SvAPIConfigStore.shared.configure(
                    from: Self.serviceConfig(
                        voteServerURLs: ["https://first.example", "https://second.example"]
                    )
                )
                return try await VotingAPIClient.liveValue.fetchZodlEndorsedRoundIds()
            }
        }

        #expect(ids == Set([expectedRoundId]))
        let observed = calls.withLock { $0 }
        #expect(observed.map { $0.0?.host } == ["first.example", "second.example"])
        #expect(observed.map { $0.1 } == [15_000, 15_000])
    }

    @Test func aProtectedGeneralGETKeepsTheLegacyRetryPolicy() async throws {
        let retries = SignalledRecords<UInt8>()
        var sdkSynchronizer = SDKSynchronizerClient.noOp
        sdkSynchronizer.httpRequestOverTor = { request in
            try await SDKSynchronizerClient.performLegacyTorRequest(request) { request, retryLimit in
                retries.record(retryLimit)
                return (Data(), Self.response(for: request, statusCode: 200))
            }
        }

        _ = try await routeVotingRequest(
            URLRequest(url: try #require(URL(string: "https://vote.example/rounds"))),
            fast: true,
            access: .protected,
            sdkSynchronizer: sdkSynchronizer,
            directRequest: { _, _ in
                Issue.record("protected general GET escaped to the direct transport")
                return (Data(), URLResponse())
            }
        )

        #expect(retries.values == [3])
    }

    private static func withRestoredConfigStore<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        let snapshot = await SvAPIConfigStore.shared.currentState()
        do {
            let result = try await operation()
            await SvAPIConfigStore.shared.replaceState(with: snapshot)
            #expect(await SvAPIConfigStore.shared.currentState() == snapshot)
            return result
        } catch {
            await SvAPIConfigStore.shared.replaceState(with: snapshot)
            #expect(await SvAPIConfigStore.shared.currentState() == snapshot)
            throw error
        }
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func serviceConfig(voteServerURLs: [String]) -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: voteServerURLs.map {
                VotingServiceConfig.ServiceEndpoint(url: $0, label: "test")
            },
            pirEndpoints: [
                VotingServiceConfig.ServiceEndpoint(url: "https://pir.example", label: "test")
            ],
            supportedVersions: VotingServiceConfig.SupportedVersions(
                pir: ["v0"],
                voteProtocol: "v0",
                tally: "v0",
                voteServer: "v1"
            ),
            rounds: [:],
            pirLayout: VotingServiceConfig.PirLayout(
                pirDepth: 8,
                tier0Layers: 2,
                tier1Layers: 2,
                polyLen: 2_048
            )
        )
    }

    private static func staticConfigJSON(dynamicURL: String) -> String {
        """
        {
          "static_config_version": 2,
          "dynamic_config_urls": ["\(dynamicURL)"],
          "trusted_keys": [
            {
              "key_id": "test",
              "alg": "ed25519",
              "pubkey": "\(Data(repeating: 1, count: 32).base64EncodedString())"
            }
          ]
        }
        """
    }

    private static let dynamicConfigJSON = """
    {
      "config_version": 1,
      "vote_servers": [{"url":"https://rounds.example","label":"test"}],
      "pir_endpoints": [{"url":"https://pir.example","label":"test"}],
      "supported_versions": {
        "pir":["v0"],
        "vote_protocol":"v0",
        "tally":"v0",
        "vote_server":"v1"
      },
      "rounds": {},
      "pir_layout": {"pir_depth":8,"tier0_layers":2,"tier1_layers":2,"poly_len":2048}
    }
    """
}
#endif
