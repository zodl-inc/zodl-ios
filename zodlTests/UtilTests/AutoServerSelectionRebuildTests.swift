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
            // A pass-through guard: these tests are not about the guard's own waiting/blocking
            // behavior (see `rebuildWaitsForTheGuardThenCompletesOnceTheHolderReleases` below for
            // that), only about what `rebuildAfterStall` restarts at and persists once it runs.
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                acquireWithTimeout: { _ in },
                tryAcquire: { true },
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

    // MOB-1853: a give-up already spent one of a small per-foreground rebuild budget on this
    // attempt (`Root.State.maxTerminalStallRebuildsPerForeground`) -- skipping the rebuild outright
    // just because a broadcast happens to hold the guard would waste that budget credit for
    // nothing, since the SDK only emits `gaveUp: true` once per handle and a skipped rebuild is
    // never retried. `rebuildAfterStall` must wait for the guard (`switchWaiting`, the same
    // primitive the manual Server Setup save uses), not skip past it (`switchIfIdle`).
    @Test func rebuildWaitsForTheGuardThenCompletesOnceTheHolderReleases() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let guardActor = TransactionGuard()
        let holderAcquired = AsyncBox()
        let releaseHolder = AsyncBox()

        // A fake submission holds the guard, the same shape a real broadcast would.
        let holder = Task {
            try? await guardActor.acquire()
            await holderAcquired.signal()
            await releaseHolder.wait()
            await guardActor.release()
        }
        await holderAcquired.wait()

        let rebuild = Task {
            await withDependencies {
                $0.userStoredPreferences.automaticServerSelection = { false }
                $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.zcashSDKEnvironment.endpoint = { current }
                $0.migrationManager.activeNetworkSnapshots = { [] }
                $0.sdkSynchronizer.evaluateServerSwitch = { _, _, _, _, _ in nil }
                $0.sdkSynchronizer.restartSync = { endpoint in
                    recorder.restartCallCount += 1
                    recorder.restartedAt = endpoint
                }
                $0.transactionGuard = Self.client(over: guardActor)
            } operation: {
                await AutoServerSelectionClient.liveValue.rebuildAfterStall()
            }
        }

        // Give the rebuild a moment to park on the guard rather than skip past it while it is busy.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.restartCallCount == 0, "must wait for the guard, not skip past it, while it is held")

        await releaseHolder.signal()
        _ = try? await holder.value
        let started = await rebuild.value

        #expect(started, "the rebuild must complete once the guard frees up, not give up because it was briefly busy")
        #expect(recorder.restartCallCount == 1)
        #expect(recorder.restartedAt?.host == "zec.rocks")
    }

    /// A client wired over a test-local actor, so this timing-sensitive test never contends with
    /// the process-global `TransactionGuardClient.liveValue` guard -- same precedent as
    /// `TransactionGuardTests.swift`'s identically-named helper.
    private static func client(over guardActor: TransactionGuard) -> TransactionGuardClient {
        TransactionGuardClient(
            acquire: { try await guardActor.acquire() },
            acquireWithTimeout: { try await guardActor.acquire(timeout: $0) },
            tryAcquire: { await guardActor.tryAcquire() },
            release: { await guardActor.release() }
        )
    }
}

/// Minimal async one-shot signal for ordering test steps. Mirrors `TransactionGuardTests.swift`'s
/// private helper of the same name and shape -- kept as its own file-scoped copy per this
/// directory's established convention of not sharing test helpers across files.
private actor AsyncBox {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signaled = true
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
