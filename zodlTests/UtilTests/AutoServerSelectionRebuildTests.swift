import Foundation
import Testing
import ComposableArchitecture
import os
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
        /// Set from inside the mocked `setServer` closure by reading a guard-aware
        /// `TransactionGuardClient` wrapper's held flag at call time -- true only when the
        /// preference write actually happened while the transaction guard was still acquired.
        var persistedInsideGuard = false
    }

    /// Mutated by a test AFTER `rebuildAfterStall` has started waiting on the guard, to simulate a
    /// manual save or a pinning change landing during the wait. Genuine cross-task mutation (unlike
    /// `Recorder`, only ever written from inside the awaited `rebuildAfterStall` call itself), so
    /// this needs real synchronization rather than a bare `var` -- `OSAllocatedUnfairLock`, per this
    /// project's general preference over `NSLock`.
    private final class PolicyBox: @unchecked Sendable {
        private struct State {
            var automatic: Bool?
            var current: LightWalletEndpoint
            var snapshots: [MigrationNetworkSnapshot]
        }
        private let state: OSAllocatedUnfairLock<State>

        init(automatic: Bool?, current: LightWalletEndpoint, snapshots: [MigrationNetworkSnapshot] = []) {
            state = OSAllocatedUnfairLock(uncheckedState: State(automatic: automatic, current: current, snapshots: snapshots))
        }

        var automatic: Bool? {
            get { state.withLockUnchecked { $0.automatic } }
            set { state.withLockUnchecked { $0.automatic = newValue } }
        }

        var current: LightWalletEndpoint {
            get { state.withLockUnchecked { $0.current } }
            set { state.withLockUnchecked { $0.current = newValue } }
        }

        var snapshots: [MigrationNetworkSnapshot] {
            get { state.withLockUnchecked { $0.snapshots } }
            set { state.withLockUnchecked { $0.snapshots = newValue } }
        }
    }

    /// Set on `acquire`/`acquireWithTimeout`, cleared on `release` -- lets a test capture, from
    /// inside a mocked `setServer` closure, whether the write actually landed while the transaction
    /// guard was held.
    private final class GuardHeldFlag: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)

        func setHeld(_ held: Bool) {
            state.withLock { $0 = held }
        }

        var isHeld: Bool {
            state.withLock { $0 }
        }
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

    /// Drives the shape shared by the three "policy changes while the rebuild waits" tests below: a
    /// holder task takes the transaction guard first, `rebuildAfterStall` starts -- benchmarking
    /// under whatever `policy` holds right now -- and parks on the guard, `mutateWhileWaiting`
    /// changes what `policy` exposes, then the holder releases and the guard hands off to the
    /// parked rebuild, which must decide under the policy in force NOW, not the one the benchmark
    /// ran under.
    private func runRebuildWhileGuardHeld(
        policy: PolicyBox,
        benchmarkDecision: LightWalletEndpoint?,
        recorder: Recorder,
        mutateWhileWaiting: @Sendable () -> Void
    ) async -> Bool {
        let guardActor = TransactionGuard()
        let holderAcquired = AsyncBox()
        let releaseHolder = AsyncBox()

        let holder = Task {
            try? await guardActor.acquire()
            await holderAcquired.signal()
            await releaseHolder.wait()
            await guardActor.release()
        }
        await holderAcquired.wait()

        let rebuild = Task {
            await withDependencies {
                $0.userStoredPreferences.automaticServerSelection = { policy.automatic }
                $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.zcashSDKEnvironment.endpoint = { policy.current }
                $0.migrationManager.activeNetworkSnapshots = { policy.snapshots }
                $0.sdkSynchronizer.evaluateServerSwitch = { _, _, _, _, _ in benchmarkDecision }
                $0.sdkSynchronizer.restartSync = { endpoint in
                    recorder.restartCallCount += 1
                    recorder.restartedAt = endpoint
                }
                $0.transactionGuard = Self.client(over: guardActor)
            } operation: {
                await AutoServerSelectionClient.liveValue.rebuildAfterStall()
            }
        }

        // Give the rebuild a moment to benchmark and park on the guard before the policy mutates
        // underneath it.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.restartCallCount == 0, "must still be waiting for the guard")

        mutateWhileWaiting()

        await releaseHolder.signal()
        _ = try? await holder.value
        return await rebuild.value
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

    // MOB-1853: a rebuild cancelled while it is still parked on the guard -- e.g. the app went to
    // the background while it waited -- must retire quietly instead of turning into a restart once
    // the guard frees up. The SDK's own `restartSync` throws `CancellationError` and touches
    // nothing when its caller was already cancelled before the restart began; this caller
    // (`rebuildAfterStall`) must treat that the same way: report "no pass started" without ever
    // reaching `restartSync`, and without persisting anything.
    @Test func aRebuildCancelledWhileWaitingForTheGuardNeverReachesTheRestart() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let guardActor = TransactionGuard()
        let holderAcquired = AsyncBox()
        let releaseHolder = AsyncBox()

        // A fake submission holds the guard, the same shape as
        // `rebuildWaitsForTheGuardThenCompletesOnceTheHolderReleases` above.
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

        // Give the rebuild a moment to benchmark and park on the guard -- same 50ms precedent as
        // the sibling test above -- then cancel it while the holder still owns the guard, before
        // it ever gets a chance to restart.
        try? await Task.sleep(for: .milliseconds(50))
        rebuild.cancel()

        await releaseHolder.signal()
        _ = try? await holder.value
        let started = await rebuild.value

        #expect(started == false)
        #expect(recorder.restartCallCount == 0, "a cancelled wait must not turn into a restart once the guard frees up")
        #expect(recorder.persisted == nil)
    }

    // MOB-1853: the rebuild's benchmark runs before the guard so waiting for it never holds other
    // work back, but the policy it was computed under can go stale during that wait -- a manual
    // Server Setup save takes the SAME `switchWaiting` guard and can land while the rebuild is still
    // parked on it. `rebuildAfterStall` must decide under the policy in force when it actually gets
    // the guard, not the one the benchmark ran under minutes or milliseconds earlier -- so a manual
    // choice made while it waited wins over the stale benchmark.
    @Test func aManualChoiceMadeWhileWaitingForTheGuardWins() async {
        let recorder = Recorder()
        let policy = PolicyBox(automatic: true, current: endpoint("zec.rocks"))
        let candidateB = endpoint("B")
        let manualC = endpoint("C")

        let started = await runRebuildWhileGuardHeld(
            policy: policy,
            benchmarkDecision: candidateB,
            recorder: recorder
        ) {
            // The manual Server Setup save landed while the rebuild was parked on the guard.
            policy.automatic = false
            policy.current = manualC
        }

        #expect(started)
        #expect(recorder.restartedAt?.host == "C")
        #expect(recorder.persisted == nil, "manual mode never rewrites the stored server")
    }

    @Test func aPinningChangeWhileWaitingExcludesTheCandidate() async {
        let recorder = Recorder()
        let policy = PolicyBox(automatic: true, current: endpoint("zec.rocks"))
        let candidateB = endpoint("B")
        let excludingB = pinningExcludingSnapshot()

        let started = await runRebuildWhileGuardHeld(
            policy: policy,
            benchmarkDecision: candidateB,
            recorder: recorder
        ) {
            // A migration pinning change landed while the rebuild was parked, excluding B.
            policy.snapshots = [excludingB]
        }

        #expect(started)
        #expect(recorder.restartedAt?.host == "zec.rocks")
        #expect(recorder.persisted == nil)
    }

    @Test func aManualToManualChangeWhileWaitingRestartsAtTheNewServer() async {
        let recorder = Recorder()
        let policy = PolicyBox(automatic: false, current: endpoint("A"))
        // A red herring, same as the manual-mode tests above: manual mode must never even ask
        // `evaluateServerSwitch`, so a decision here must never surface.
        let redHerring = endpoint("na.zec.rocks")
        let manualC = endpoint("C")

        let started = await runRebuildWhileGuardHeld(
            policy: policy,
            benchmarkDecision: redHerring,
            recorder: recorder
        ) {
            // A second manual save landed while the rebuild was parked.
            policy.current = manualC
        }

        #expect(started)
        #expect(recorder.restartedAt?.host == "C")
        #expect(recorder.persisted == nil)
    }

    // MOB-1853: mirrors `ServerSetupStore.applyServerSwitch`'s own discipline -- the preference
    // write must happen INSIDE `switchWaiting`, not after it returns, so a connection-mode flip or
    // manual save that lands the instant the guard is released can never race a write still pending
    // from here.
    @Test func automaticModePersistsInsideTheGuardWhenTheCandidateIsUsed() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        let candidateB = endpoint("B")
        let heldFlag = GuardHeldFlag()

        let started = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.userStoredPreferences.setServer = { config in
                recorder.persistedInsideGuard = heldFlag.isHeld
                recorder.persisted = config
            }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.migrationManager.activeNetworkSnapshots = { [] }
            $0.sdkSynchronizer.evaluateServerSwitch = { _, _, _, _, _ in candidateB }
            $0.sdkSynchronizer.restartSync = { endpoint in
                recorder.restartCallCount += 1
                recorder.restartedAt = endpoint
            }
            $0.transactionGuard = TransactionGuardClient(
                acquire: { heldFlag.setHeld(true) },
                acquireWithTimeout: { _ in heldFlag.setHeld(true) },
                tryAcquire: { true },
                release: { heldFlag.setHeld(false) }
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.rebuildAfterStall()
        }

        #expect(started)
        #expect(recorder.restartedAt?.host == "B")
        #expect(recorder.persistedInsideGuard, "the preference write happens while the guard is held")
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
