#if VOTING_ENABLED
//
//  VotingTxConfirmationTransportTests.swift
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
struct VotingTxConfirmationTransportTests {
    private struct BoundedCall: Equatable, Sendable {
        let url: URL?
        let retryLimit: UInt8
        let timeoutMilliseconds: UInt64
    }

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
