import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `AutoServerSelectionClient.rebuildAfterStall` -- the bounded way back to a running sync once the
// SDK's own stall recovery has given up. Unlike `applySwitch` (which receives an already-benchmarked,
// possibly minutes-stale candidate from `Root`), this member computes its own candidate synchronously
// via `findBestServer()` and always restarts at SOMETHING: the benchmark winner when Automatic mode
// qualifies one, otherwise the currently configured endpoint -- restarting at the current endpoint is
// still useful when recovery gave up with no engine handle left behind. Mirrors the driving pattern in
// `AutoServerSelectionClientTests.swift` (`applySwitch`) and `AutoServerSelectionFindServerTests.swift`
// (`findBestServer`, including the migration-pinning predicate this composes with unchanged).
@Suite struct AutoServerSelectionRebuildTests {
    private final class Recorder: @unchecked Sendable {
        var restartCallCount = 0
        var restartedAt: LightWalletEndpoint?
        var persisted: UserPreferencesStorage.ServerConfig?
    }

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    /// A snapshot whose sync provider classifies as `.custom(host:)` and matches none of the
    /// built-in mainnet endpoints (all `.zec.rocks`/`.zec.stardust.rest`) -- `isCandidateAllowed`
    /// then excludes every one of them, so `findBestServer()`'s own `candidates` list is empty.
    private func pinningExcludingSnapshot() -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "custom-provider.example.com", port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "custom-provider.example.com", port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func runRebuild(
        automatic: Bool?,
        current: LightWalletEndpoint,
        sdkDecision: LightWalletEndpoint?,
        snapshots: [MigrationNetworkSnapshot] = [],
        guardBusy: Bool = false,
        restartThrows: Bool = false,
        recorder: Recorder
    ) async -> Bool {
        await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { automatic }
            $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.migrationManager.activeNetworkSnapshots = { snapshots }
            $0.sdkSynchronizer.evaluateServerSwitch = { _, _, _, _, _ in sdkDecision }
            $0.sdkSynchronizer.restartSync = { endpoint in
                recorder.restartCallCount += 1
                recorder.restartedAt = endpoint
                if restartThrows { throw URLError(URLError.Code.timedOut) }
            }
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                acquireWithTimeout: { _ in },
                tryAcquire: { !guardBusy },
                release: {}
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.rebuildAfterStall()
        }
    }

    @Test func manualModeRestartsAtConfiguredEndpoint() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        // A red herring: manual mode must never even ask, so this decision must never surface.
        let started = await runRebuild(automatic: false, current: current, sdkDecision: endpoint("na.zec.rocks"), recorder: recorder)

        #expect(started)
        #expect(recorder.restartCallCount == 1)
        #expect(recorder.restartedAt?.host == "zec.rocks")
        #expect(recorder.persisted == nil, "restarting at the already-configured endpoint is not a change worth persisting")
    }

    @Test func automaticModeWithCandidateRestartsThereAndPersists() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let started = await runRebuild(automatic: true, current: current, sdkDecision: endpoint("na.zec.rocks"), recorder: recorder)

        #expect(started)
        #expect(recorder.restartedAt?.host == "na.zec.rocks")
        #expect(recorder.persisted?.host == "na.zec.rocks")
        #expect(recorder.persisted?.isCustom == false)
    }

    @Test func automaticModeReturningNilFallsBackToConfiguredEndpoint() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let started = await runRebuild(automatic: true, current: current, sdkDecision: nil, recorder: recorder)

        #expect(started)
        #expect(recorder.restartedAt?.host == "zec.rocks")
        #expect(recorder.persisted == nil)
    }

    @Test func migrationPinningExcludingEveryCandidateFallsBackToConfiguredEndpoint() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let started = await runRebuild(
            automatic: true,
            current: current,
            sdkDecision: endpoint("na.zec.rocks"), // would win if the benchmark ever ran -- it must not
            snapshots: [pinningExcludingSnapshot()],
            recorder: recorder
        )

        #expect(started)
        #expect(recorder.restartedAt?.host == "zec.rocks")
        #expect(recorder.persisted == nil)
    }

    @Test func restartSyncThrowingReturnsFalse() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let started = await runRebuild(automatic: false, current: current, sdkDecision: nil, restartThrows: true, recorder: recorder)

        #expect(!started)
        #expect(recorder.persisted == nil)
    }

    @Test func guardBusySkipsAndReturnsFalse() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let started = await runRebuild(automatic: false, current: current, sdkDecision: nil, guardBusy: true, recorder: recorder)

        #expect(!started)
        #expect(recorder.restartCallCount == 0)
        #expect(recorder.persisted == nil)
    }
}
