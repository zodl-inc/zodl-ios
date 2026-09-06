//
//  RootRetryStartReentrancyTests.swift
//  zodlTests
//
//  MOB-1854: guards `.initialization(.retryStart)` against re-entry. `.retryStart` is sent from
//  several independent sites (foreground, the background task, the start-failure retry, the
//  migration gate resume), so two start pipelines can overlap. `SlipstreamSynchronizer.start()` has
//  no cancellation points, so cancelling the first pipeline mid-`start()` would let it run to
//  completion anyway and the second pipeline would then call `start()` again — draining and
//  restarting the engine. `Root.State.isRetryStartInFlight` makes the FIRST pipeline win instead: a
//  re-entrant `.retryStart` is dropped (and logged) while a pipeline is already running, and
//  `.retryStartFinished` — sent as the last statement of both the success and failure exits of the
//  `.run` effect — clears the latch once that pipeline is done.
//
//  MOB-1854 follow-up: a dropped `.retryStart` is not lost. The pipeline it was dropped behind may
//  be a broadcast-only pass that never calls `start()` at all, so simply dropping the request could
//  leave sync unresumed for the rest of the session. Each admitted pipeline is tagged with a
//  generation (`Root.State.retryStartGeneration`); a request dropped while one is in flight arms
//  `retryStartRequestedWhileInFlight` instead of clearing the migration-resume flags, and the
//  in-flight pipeline's own `.retryStartFinished` replays it exactly once. `.retryStartFinished` and
//  `.registerForSynchronizersUpdate` both carry the generation they were sent for, so a pipeline that
//  finishes (or registers) after a newer one has already taken over can neither release that newer
//  pipeline's latch nor re-subscribe the synchronizer streams on its behalf.
//
//  This suite holds `sdkSynchronizer.start` open on a gate to drive the race directly, mirroring
//  `RootInitializeSDKSingleFlightTests`' `PrepareGate` pattern (itself the single-flight precedent
//  for `isInitializingSDK`/`initializeSDKFinished`) and reusing `RootMigrationGateRefusalTests`'
//  proven dependency stub set for a full, successful sync-branch `.retryStart` pass.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized per repo convention for suites driving `.retryStart`/`.didEnterBackground` through a
// real TestStore — see RootMigrationGateRefusalTests' identical `@Suite(.serialized)` rationale.
// `.timeLimit` records a gate that genuinely never opens (or a finishing action that genuinely never
// arrives) as a failure instead of hanging the run. Every wait a test actually depends on for its
// pass/fail outcome also carries its own short, explicit timeout (see `.receive(timeout:)` below) so
// a real regression fails in seconds rather than riding this suite-wide backstop.
@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct RootRetryStartReentrancyTests {
    private static let seedDerivedAccount = WalletAccount(
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Zashi",
            keySource: "zashi",
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    )

    private static func makeInitialState() -> Root.State {
        Root.State(
            destinationState: Root.DestinationState(internalDestination: .home),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
    }

    /// Builds a `Root` `TestStore` wired for a full, successful sync-branch `.retryStart` pass —
    /// the same dependency shape as `RootMigrationGateRefusalTests.syncPassStillReRegistersSynchronizerStreams`.
    /// Every `sdkSynchronizer.start` call is recorded into `startCalls` and then parks on
    /// `gates[min(ordinal, gates.count) - 1]` (1-based call ordinal) until the test releases that
    /// gate — a single shared gate (the `gate:` overload below) holds every pipeline behind the
    /// same latch, while a per-pipeline `gates:` array lets a test release one pipeline's `start()`
    /// without releasing another's, which is what the generation tests need to drive a stale
    /// completion independently of the pipeline that currently owns the latch.
    ///
    /// `isMigrationSyncBlockedCalls`, when supplied, records every `sdkSynchronizer.isMigrationSyncBlocked()`
    /// call — the first thing `.registerForSynchronizersUpdate`'s subscription effect does — so a
    /// test can prove a generation-stale register never re-subscribed anything, without needing a
    /// production seam beyond the generation guard itself.
    private func makeStore(
        startCalls: SignalledRecords<Void>,
        gates: [ResumableGate],
        isMigrationSyncBlockedCalls: SignalledRecords<Void>? = nil
    ) -> TestStore<Root.State, Root.Action> {
        let seedDerivedAccount = RootRetryStartReentrancyTests.seedDerivedAccount

        // Pinned to a fresh, per-call `InMemoryStorage` — `Root.State` and the `TestStore` must be
        // created INSIDE this scope, since every `@Shared(.inMemory(...))` slot (including the ones
        // `RootInitialization.swift` reads/writes locally, like `.migrationStoppedSyncForBroadcast`)
        // binds to whichever storage is current at the moment its owning state/reducer code runs.
        // Left unpinned, this suite would share the process-global default storage with every other
        // suite exercising the same slots (e.g. `RootMigrationTickLoopTests`), which — since Swift
        // Testing runs different suites' tests concurrently — can flip a flag this suite depends on
        // out from under it mid-test. See `RootTerminalStallRebuildTests.swift`'s identical pinning.
        return withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = TestStore(
                initialState: RootRetryStartReentrancyTests.makeInitialState()
            ) {
                Root()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.continuousClock = TestClock()

                $0.exchangeRate = .noOp
                $0.autolockHandler = .noOp
                $0.shieldingProcessor = ShieldingProcessorClient(
                    observe: { Empty().eraseToAnyPublisher() },
                    shieldFunds: { }
                )

                $0.mnemonic = .noOp
                $0.databaseFiles = .noOp

                $0.walletStorage = .noOp
                $0.walletStorage.exportWallet = { .placeholder }

                $0.flexaHandler = .noOp
                $0.flexaHandler.signOut = { }

                $0.userStoredPreferences.removeAll = { }
                $0.readTransactionsStorage = .noOp

                $0.userDefaults.objectForKey = { _ in nil }
                $0.userDefaults.remove = { _ in }
                $0.userDefaults.setValue = { _, _ in }

                $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
                $0.userMetadataProvider.load = { _ in }

                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }

                $0.sdkSynchronizer = .mocked(
                    stateStream: { Empty().eraseToAnyPublisher() },
                    latestState: {
                        var syncState = SynchronizerState.zero
                        syncState.syncStatus = .upToDate
                        return syncState
                    },
                    prepareWith: { _, _, _, _ in .success },
                    start: { _ in
                        let ordinal = startCalls.recordCall()
                        await gates[min(ordinal, gates.count) - 1].wait()
                    },
                    isMigrationSyncBlocked: {
                        isMigrationSyncBlockedCalls?.recordCall()
                        return false
                    },
                    getAllTransactions: { _ in [] },
                    isSeedRelevantToAnyDerivedAccount: { _ in true },
                    walletAccounts: { [seedDerivedAccount] }
                )
            }
            store.exhaustivity = .off
            return store
        }
    }

    /// Convenience for the common single-pipeline case: every `start()` call parks on the same gate.
    /// Also pinned to a fresh `InMemoryStorage`, even though it only delegates to the `gates:`
    /// overload (which pins its own) — kept explicit so this overload stays self-isolating on its
    /// own terms if that delegation ever changes.
    private func makeStore(
        startCalls: SignalledRecords<Void>,
        gate: ResumableGate
    ) -> TestStore<Root.State, Root.Action> {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            makeStore(startCalls: startCalls, gates: [gate])
        }
    }

    /// Builds a store whose FIRST `.retryStart` pipeline takes the broadcast-only (`visitKind() ==
    /// .send`) branch and never calls `start()`, while every pipeline after it finds nothing left
    /// due and takes the ordinary sync branch — the same shape a real broadcast going out and
    /// clearing its own dueness produces. `migrationManager.advance` parks on `advanceGate` so a
    /// test can hold the broadcast-only pass "in flight" for as long as the race needs the window
    /// held open; `sdkSynchronizer.start` is recorded but not gated, since nothing in this scenario
    /// needs a START call to stay in flight.
    // Pinned to a fresh `InMemoryStorage`, same rationale and idiom as the `makeStore` overloads
    // above — this is the store `gateFalseEdgeDuringABroadcastOnlyPipelineResumesSyncOnce` uses, and
    // its final assertions depend on `.migrationSyncGateChanged`'s `shouldResume` reading
    // `.migrationStoppedSyncForBroadcast` as this test left it, not as some other concurrently
    // running suite last left the process-global default.
    private func makeBroadcastOnlyStore(
        startCalls: SignalledRecords<Void>,
        advanceGate: ResumableGate,
        visitKindCallCount: LockIsolated<Int>
    ) -> TestStore<Root.State, Root.Action> {
        let seedDerivedAccount = RootRetryStartReentrancyTests.seedDerivedAccount

        return withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = TestStore(
                initialState: RootRetryStartReentrancyTests.makeInitialState()
            ) {
                Root()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.continuousClock = TestClock()

                $0.exchangeRate = .noOp
                $0.autolockHandler = .noOp
                $0.shieldingProcessor = ShieldingProcessorClient(
                    observe: { Empty().eraseToAnyPublisher() },
                    shieldFunds: { }
                )

                $0.mnemonic = .noOp
                $0.databaseFiles = .noOp

                $0.walletStorage = .noOp
                $0.walletStorage.exportWallet = { .placeholder }

                $0.flexaHandler = .noOp
                $0.flexaHandler.signOut = { }

                $0.userStoredPreferences.removeAll = { }
                $0.readTransactionsStorage = .noOp

                $0.userDefaults.objectForKey = { _ in nil }
                $0.userDefaults.remove = { _ in }
                $0.userDefaults.setValue = { _, _ in }

                $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
                $0.userMetadataProvider.load = { _ in }

                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }

                // The first pipeline is a broadcast-only pass; every pipeline after it finds nothing
                // left due and syncs normally.
                $0.migrationManager.visitKind = {
                    let ordinal = visitKindCallCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    return ordinal == 1 ? .send : .sync
                }
                $0.migrationManager.advance = { _ in
                    await advanceGate.wait()
                    return .broadcast(id: 1)
                }

                $0.sdkSynchronizer = .mocked(
                    stateStream: { Empty().eraseToAnyPublisher() },
                    latestState: {
                        var syncState = SynchronizerState.zero
                        syncState.syncStatus = .upToDate
                        return syncState
                    },
                    prepareWith: { _, _, _, _ in .success },
                    start: { _ in
                        startCalls.recordCall()
                    },
                    getAllTransactions: { _ in [] },
                    isSeedRelevantToAnyDerivedAccount: { _ in true },
                    walletAccounts: { [seedDerivedAccount] }
                )
            }
            store.exhaustivity = .off
            return store
        }
    }

    /// Lets the rest of a cascade (SmartBanner evaluation, contacts, user metadata, the battery-state
    /// subscription, the migration gate stream, …) settle without asserting on any of it — identical
    /// rationale to RootMigrationGateRefusalTests' `drain`.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - A re-entrant retryStart is dropped: start() is called exactly once

    @Test func secondRetryStartWhileFirstInFlightDropsWithoutCallingStartAgain() async throws {
        let startCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        // The first pipeline is still parked on the gate — a second retryStart arriving now must be
        // dropped: no second `start()` call, and (under .off exhaustivity) no unexpected state change
        // since the guard's `else` branch is a bare `return .none`.
        await store.send(.initialization(.retryStart))

        #expect(startCalls.count == 1, "a retryStart arriving while a pipeline is in flight must not call start() again")
        #expect(store.state.isRetryStartInFlight, "the in-flight pipeline's own latch must be untouched by the dropped duplicate")

        gate.open()
        await drain(store)
    }

    // MARK: - retryStartFinished clears the latch; the next retryStart proceeds normally

    @Test func retryStartFinishedClearsTheLatchAndAllowsTheNextPipelineToCallStartAgain() async throws {
        let startCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        gate.open()

        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished) = action else { return false }
                return true
            },
            timeout: .seconds(10)
        ) {
            $0.isRetryStartInFlight = false
        }

        // A THIRD retryStart, sent only after the finishing action cleared the latch, must call
        // start() again — the guard is a single-flight latch, not a one-shot.
        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(2)
        #expect(startCalls.count == 2, "retryStart after the latch clears must call start() again")

        gate.open()
        await drain(store)
    }

    // MARK: - didEnterBackground resets the latch even if the in-flight pipeline never finished

    @Test func retryStartAfterDidEnterBackgroundProceedsEvenIfThePreviousPipelineNeverFinished() async throws {
        let startCalls = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let store = makeStore(startCalls: startCalls, gates: [gateA, gateB])

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let aGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        // Background WITHOUT releasing gateA — the first pipeline's `.run` effect carries no
        // `.cancellable` id of its own, so it stays parked, and its finishing send never arrives on
        // its own. This is exactly the "dropped by cancellation (store teardown)" scenario the
        // background reset exists to guard against — reproduced here directly via a pipeline that
        // simply never completes on its own.
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight, "backgrounding must reset the latch even though the in-flight pipeline never finished")

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        #expect(bGeneration != aGeneration, "backgrounding must give the next pipeline its own generation")
        await startCalls.countReached(2)
        #expect(startCalls.count == 2, "a retryStart after backgrounding must proceed even though the previous pipeline never finished")

        // Now let A's own long-parked start() finally return. Its completion is STALE (generation
        // aGeneration, while B — generation bGeneration — is the current owner) and must not release
        // the latch B is still using; B's own gate (gateB) stays closed throughout, so only A's
        // completion is in play here.
        gateA.open()
        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let generation)) = action else { return false }
                return generation == aGeneration
            },
            timeout: .seconds(10)
        )
        #expect(store.state.isRetryStartInFlight, "A's stale completion must not release the latch B still owns")

        gateB.open()
        await drain(store)
    }

    // MARK: - A retryStart dropped while a pipeline is in flight is replayed once that pipeline finishes

    @Test func aRetryStartDroppedWhileInFlightIsReplayedOnceWhenThePipelineFinishes() async throws {
        let startCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let generation = store.state.retryStartGeneration
        await startCalls.countReached(1)

        // Dropped: the first pipeline is still parked in `start()`. Unlike a plain drop, this must
        // be remembered rather than lost.
        await store.send(.initialization(.retryStart)) {
            $0.retryStartRequestedWhileInFlight = true
        }
        #expect(startCalls.count == 1, "the dropped request must not call start() itself")

        gate.open()

        // The in-flight pipeline finishes — its own retryStartFinished replays the request that was
        // dropped behind it.
        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let receivedGeneration)) = action else { return false }
                return receivedGeneration == generation
            },
            timeout: .seconds(10)
        ) {
            $0.isRetryStartInFlight = false
            $0.retryStartRequestedWhileInFlight = false
        }

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) {
            $0.isRetryStartInFlight = true
        }

        await startCalls.countReached(2)
        #expect(startCalls.count == 2, "the replay must call start() exactly once more")

        gate.open()
        await drain(store)
        #expect(startCalls.count == 2, "no third start() call must happen once the replay's own pipeline finishes")
    }

    // MARK: - The migration-resume flags survive a dropped retryStart

    @Test func migrationResumeFlagsSurviveADroppedRetryStart() async throws {
        let startCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        // Arm the migration-resume flag as if a broadcast-only pipeline had deferred sync while this
        // (unrelated) pipeline is in flight.
        await store.send(.migrationGateDeferredSyncStart) {
            $0.syncDeferredByMigrationGate = true
        }

        // A second retryStart arrives while the first is in flight and must be dropped — and, unlike
        // the pre-fix behavior, must not consume the flag on its way out.
        await store.send(.initialization(.retryStart))

        #expect(store.state.syncDeferredByMigrationGate, "a dropped retryStart must not consume the migration-resume flag")
        #expect(store.state.isRetryStartInFlight, "the in-flight pipeline's own latch must be untouched by the dropped duplicate")
        #expect(store.state.retryStartRequestedWhileInFlight, "the dropped request must be armed for replay")

        gate.open()
        await drain(store)
    }

    // MARK: - A gate-false edge during a broadcast-only pipeline still resumes sync, exactly once

    @Test func gateFalseEdgeDuringABroadcastOnlyPipelineResumesSyncOnce() async throws {
        let startCalls = SignalledRecords<Void>()
        let advanceGate = ResumableGate()
        let visitKindCallCount = LockIsolated<Int>(0)
        let store = makeBroadcastOnlyStore(
            startCalls: startCalls,
            advanceGate: advanceGate,
            visitKindCallCount: visitKindCallCount
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let generation = store.state.retryStartGeneration

        // The broadcast-only branch arms the resume flag before parking in `advance(.beforeSync)`.
        await store.receive(
            { action in
                guard case .migrationGateDeferredSyncStart = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) {
            $0.syncDeferredByMigrationGate = true
        }

        // Pipeline A is now parked inside `advance(.beforeSync)` — still in flight. A gate-false edge
        // arrives; `shouldResume` reads true off the flag just armed, but the replay must be
        // DEFERRED rather than dropped outright.
        await store.send(.migrationSyncGateChanged(false))

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) {
            $0.retryStartRequestedWhileInFlight = true
        }

        #expect(store.state.syncDeferredByMigrationGate, "the deferred retryStart must not consume the flag pipeline A still needs")
        #expect(store.state.isRetryStartInFlight, "pipeline A is still the latch's owner")

        advanceGate.open()

        // A finishes (broadcast-only — no start()) and its own retryStartFinished replays the
        // deferred request — by now visitKind answers .sync, so this pipeline actually starts sync.
        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let receivedGeneration)) = action else { return false }
                return receivedGeneration == generation
            },
            timeout: .seconds(10)
        ) {
            $0.isRetryStartInFlight = false
            $0.retryStartRequestedWhileInFlight = false
        }

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) {
            $0.isRetryStartInFlight = true
        }

        await startCalls.countReached(1)
        #expect(startCalls.count == 1, "the replayed pipeline must start sync exactly once")

        await drain(store)
        #expect(!store.state.syncDeferredByMigrationGate, "the replay's own retryStart consumed the flag past its guards")
        #expect(!store.state.retryStartRequestedWhileInFlight, "the replay consumed its own request flag")

        // A second gate emission, now that both resume flags are clear, must add nothing.
        await store.send(.migrationSyncGateChanged(false))
        await drain(store)
        #expect(startCalls.count == 1, "a second gate emission after the resume already ran must not start sync again")
    }

    // MARK: - A stale pipeline finishing after backgrounding cannot clear a newer latch or re-register

    @Test func aPipelineFinishingAfterBackgroundDoesNotClearTheNewerLatchOrReregister() async throws {
        let startCalls = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let isMigrationSyncBlockedCalls = SignalledRecords<Void>()
        let store = makeStore(
            startCalls: startCalls,
            gates: [gateA, gateB],
            isMigrationSyncBlockedCalls: isMigrationSyncBlockedCalls
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let aGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        #expect(bGeneration != aGeneration, "backgrounding must give the next pipeline its own generation")
        await startCalls.countReached(2)

        // Release ONLY A — B stays parked on its own gate, still the latch's current owner.
        gateA.open()

        await store.receive(
            { action in
                guard case .initialization(.registerForSynchronizersUpdate(let receivedGeneration)) = action else { return false }
                return receivedGeneration == aGeneration
            },
            timeout: .seconds(10)
        )
        #expect(isMigrationSyncBlockedCalls.isEmpty, "A's stale register must not re-subscribe the synchronizer streams")

        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let receivedGeneration)) = action else { return false }
                return receivedGeneration == aGeneration
            },
            timeout: .seconds(5)
        )
        #expect(store.state.isRetryStartInFlight, "A's stale completion must not release the latch B still owns")

        gateB.open()
        await drain(store)
    }

    // MARK: - Backgrounding clears a deferred replay request, so a stale finish replays nothing

    @Test func backgroundingClearsADeferredReplayRequestSoTheStaleFinishReplaysNothing() async throws {
        let startCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let generation = store.state.retryStartGeneration
        await startCalls.countReached(1)

        // Dropped while pipeline A is still parked in start() — armed for a replay, exactly like
        // the replay-proof test above.
        await store.send(.initialization(.retryStart)) {
            $0.retryStartRequestedWhileInFlight = true
        }
        #expect(startCalls.count == 1, "the dropped request must not call start() itself")

        // Backgrounding must clear the deferred-replay flag along with the latch — a backgrounded
        // app has no business replaying a request that predates it.
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.retryStartRequestedWhileInFlight, "backgrounding must clear a deferred replay request")
        #expect(!store.state.isRetryStartInFlight, "backgrounding must clear the in-flight latch too")

        gate.open()

        // A's own long-parked start() finally returns. Its completion is stale (tagged for the
        // pre-background generation) and, even though a replay was armed behind it before
        // backgrounding, that arming was already cleared above — so this finish must replay nothing.
        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let receivedGeneration)) = action else { return false }
                return receivedGeneration == generation
            },
            timeout: .seconds(10)
        )

        await drain(store)
        #expect(startCalls.count == 1, "a stale finish after backgrounding must not replay retryStart")
        #expect(!store.state.retryStartRequestedWhileInFlight, "the stale finish must not re-arm the replay flag")
        #expect(!store.state.isRetryStartInFlight, "the stale finish must not re-set the latch")
    }
}
