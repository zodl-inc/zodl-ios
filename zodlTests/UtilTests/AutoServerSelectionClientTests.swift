import Testing
import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

final class AutoServerSelectionClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var switchedTo: LightWalletEndpoint?
        var persisted: UserPreferencesStorage.ServerConfig?
    }

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    // MARK: - applySwitch

    /// Runs `applySwitch` with controlled dependencies and returns (didSwitch, recorder).
    private func runApply(
        flag: Bool?,
        current: LightWalletEndpoint,
        candidate: LightWalletEndpoint,
        guardBusy: Bool = false
    ) async -> (didSwitch: Bool, recorder: Recorder) {
        let recorder = Recorder()
        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { flag }
            $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.sdkSynchronizer.switchToEndpoint = { recorder.switchedTo = $0 }
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                tryAcquire: { !guardBusy },
                release: {}
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(candidate)
        }
        return (didSwitch, recorder)
    }

    func testApplySwitchesAndPersists() async {
        let (didSwitch, r) = await runApply(flag: true, current: endpoint("zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(r.switchedTo?.host, "na.zec.rocks")
        XCTAssertEqual(r.persisted?.host, "na.zec.rocks")
        XCTAssertEqual(r.persisted?.isCustom, false)
    }

    func testApplySkipsWhenGuardBusy() async {
        let (didSwitch, r) = await runApply(
            flag: true,
            current: endpoint("zec.rocks"),
            candidate: endpoint("na.zec.rocks"),
            guardBusy: true
        )
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyNoOpWhenFlagTurnedOff() async {
        // The user may flip to Manual while a candidate sits deferred.
        let (didSwitch, r) = await runApply(flag: false, current: endpoint("zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyNoOpWhenCandidateEqualsCurrent() async {
        // A manual switch may have landed on the candidate while it sat deferred.
        let (didSwitch, r) = await runApply(flag: true, current: endpoint("na.zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyReturnsFalseWhenSwitchThrows() async {
        let recorder = Recorder()
        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0) }
            $0.sdkSynchronizer.switchToEndpoint = { _ in throw URLError(URLError.Code.timedOut) }
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                tryAcquire: { true },
                release: {}
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            )
        }
        XCTAssertFalse(didSwitch)
        XCTAssertNil(recorder.persisted)
    }
}

@Suite(.serialized) @MainActor
struct RootAutoServerCandidateTests {
    @Test
    func sensitiveFlowsDeferAutomaticSwitches() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            // MOB-1853: `canApplyAutoServerSwitch` now also requires an idle sync status; seed one
            // so this test still isolates the sensitive-flow term it is named for.
            state.lastKnownSyncStatus = .upToDate
            #expect(state.canApplyAutoServerSwitch)

            let sensitivePaths: [Root.State.Path] = [
                .migrationCoordFlow, .sendCoordFlow, .scanCoordFlow,
                .swapAndPayCoordFlow, .transactionsCoordFlow, .settings
            ]
            for path in sensitivePaths {
                state.path = path
                #expect(state.isSensitiveFlowActive)
                #expect(!state.canApplyAutoServerSwitch)
            }

            state.path = nil
            state.signWithKeystoneCoordFlowBinding = true
            #expect(state.isSensitiveFlowActive)
            #expect(!state.canApplyAutoServerSwitch)
        }
    }

    @Test
    func nonSensitivePathsRemainNonSensitive() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            let nonSensitivePaths: [Root.State.Path] = [
                .addKeystoneHWWalletCoordFlow, .currencyConversionSetup, .receive,
                .requestZecCoordFlow, .serverSwitch, .torSetup, .walletBackup
            ]
            for path in nonSensitivePaths {
                state.path = path
                #expect(!state.isSensitiveFlowActive)
            }
        }
    }

    @Test
    func serverSetupBlocksAutomaticSwitches() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            // MOB-1853: `canApplyAutoServerSwitch` now also requires an idle sync status; seed one
            // so this test still isolates the server-setup term it is named for.
            state.lastKnownSyncStatus = .upToDate
            #expect(state.canApplyAutoServerSwitch)

            state.serverSetupViewBinding = true
            #expect(!state.canApplyAutoServerSwitch)

            state.serverSetupViewBinding = false
            state.path = .serverSwitch
            #expect(state.isServerSetupVisible)
            #expect(!state.canApplyAutoServerSwitch)
        }
    }

    @Test
    func benchmarkWinnerRequiresACompletedLocalSnapshotRead() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let endpoint = LightWalletEndpoint(
                address: "zec.rocks",
                port: 443,
                secure: true,
                streamingCallTimeoutInMillis: 0
            )
            let didApply = LockIsolated(false)
            // MOB-1853: `canApplyAutoServerSwitch` now also requires an idle sync status; seed one
            // so this test still isolates the snapshot-read gate it is named for.
            var initialState = Root.State.initial
            initialState.lastKnownSyncStatus = .upToDate
            let store = TestStore(initialState: initialState) {
                Root()
            } withDependencies: {
                $0.autoServerSelection = AutoServerSelectionClient(
                    findBestServer: { endpoint },
                    applySwitch: { _ in
                        didApply.setValue(true)
                        return true
                    }
                )
                $0.sdkSynchronizer = .mocked(getLocalAccountBalances: { nil })
            }
            store.exhaustivity = .off

            await store.send(.refreshAutomaticServer)
            await store.finish()

            #expect(!didApply.value)
        }
    }

    @Test
    func benchmarkWinnerWaitsForLocalSnapshotReadToComplete() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let endpoint = LightWalletEndpoint(
                address: "zec.rocks",
                port: 443,
                secure: true,
                streamingCallTimeoutInMillis: 0
            )
            let benchmarkCompleted = AsyncStream<Void>.makeStream()
            let snapshotReadStarted = AsyncStream<Void>.makeStream()
            let snapshotReadRelease = AsyncStream<Void>.makeStream()
            let didApply = LockIsolated(false)
            // MOB-1853: `canApplyAutoServerSwitch` now also requires an idle sync status; seed one
            // so this test still isolates the snapshot-read gate it is named for.
            var initialState = Root.State.initial
            initialState.lastKnownSyncStatus = .upToDate
            let store = TestStore(initialState: initialState) {
                Root()
            } withDependencies: {
                $0.autoServerSelection = AutoServerSelectionClient(
                    findBestServer: {
                        benchmarkCompleted.continuation.yield(())
                        return endpoint
                    },
                    applySwitch: { _ in
                        didApply.setValue(true)
                        return true
                    }
                )
                $0.sdkSynchronizer = .mocked(
                    getLocalAccountBalances: {
                        snapshotReadStarted.continuation.yield(())
                        for await _ in snapshotReadRelease.stream { break }
                        return [:]
                    }
                )
                $0.date.now = { Date(timeIntervalSince1970: 1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.refreshAutomaticServer)
            for await _ in benchmarkCompleted.stream { break }
            for await _ in snapshotReadStarted.stream { break }
            #expect(!didApply.value)

            snapshotReadRelease.continuation.yield(())
            await store.receive(\.autoServerCandidateReady)
            await store.finish()

            #expect(didApply.value)
        }
    }

    @Test
    func emptyLocalSnapshotStillAllowsBenchmarkWinner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let endpoint = LightWalletEndpoint(
                address: "zec.rocks",
                port: 443,
                secure: true,
                streamingCallTimeoutInMillis: 0
            )
            let benchmarkedAt = Date(timeIntervalSince1970: 1_000_000)
            let didApply = LockIsolated(false)
            // MOB-1853: `canApplyAutoServerSwitch` now also requires an idle sync status; seed one
            // so this test still isolates the empty-snapshot behavior it is named for.
            var initialState = Root.State.initial
            initialState.lastKnownSyncStatus = .upToDate
            let store = TestStore(initialState: initialState) {
                Root()
            } withDependencies: {
                $0.autoServerSelection = AutoServerSelectionClient(
                    findBestServer: { endpoint },
                    applySwitch: { _ in
                        didApply.setValue(true)
                        return true
                    }
                )
                $0.sdkSynchronizer = .mocked(getLocalAccountBalances: { [:] })
                $0.date.now = { benchmarkedAt }
            }
            store.exhaustivity = .off

            await store.send(.refreshAutomaticServer)
            await store.receive(\.autoServerCandidateReady)
            await store.finish()

            #expect(didApply.value)
        }
    }

    @Test
    func pendingCandidateExpiresAtFifteenMinutes() {
        let benchmarkedAt = Date(timeIntervalSince1970: 1_000_000)
        let candidate = Root.State.PendingServerCandidate(
            endpoint: LightWalletEndpoint(
                address: "zec.rocks",
                port: 443,
                secure: true,
                streamingCallTimeoutInMillis: 0
            ),
            benchmarkedAt: benchmarkedAt
        )
        #expect(!candidate.isExpired(now: benchmarkedAt.addingTimeInterval(14 * 60)))
        #expect(candidate.isExpired(now: benchmarkedAt.addingTimeInterval(15 * 60)))
    }

    @Test
    func deferredCandidateKeepsOriginalBenchmarkTimestamp() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.path = .sendCoordFlow
            let endpoint = LightWalletEndpoint(
                address: "zec.rocks",
                port: 443,
                secure: true,
                streamingCallTimeoutInMillis: 0
            )
            let benchmarkedAt = Date(timeIntervalSince1970: 1_000_000)
            let store = TestStore(initialState: state) {
                Root()
            }
            store.exhaustivity = .off

            await store.send(.autoServerCandidateReady(endpoint, benchmarkedAt))

            #expect(store.state.pendingServerCandidate?.benchmarkedAt == benchmarkedAt)
            #expect(store.state.pendingServerCandidate?.endpoint.host == endpoint.host)
        }
    }
}
