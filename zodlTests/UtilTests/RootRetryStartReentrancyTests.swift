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

    /// MOB-1854: a start failure that is NOT the migration gate's own refusal — the "retired
    /// pipeline whose start comes back a FAILURE" shape `aRetiredPipelineFailingAfterBackgroundSchedulesNoRetry`
    /// needs, mirroring `RootMigrationGateRefusalTests.OtherStartError`.
    private struct RetiredPipelineStartError: Error, Equatable { }

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
    ///
    /// MOB-1854: `stopCalls`, `findBestServerCalls` and `stateStreamSubscriptions`, when supplied,
    /// record `sdkSynchronizer.stop()`, `autoServerSelection.findBestServer()` and every
    /// `sdkSynchronizer.stateStream()` subscription (`.registerForSynchronizersUpdate`'s own
    /// `Effect.publisher` closure runs this once per successful registration) — what the
    /// background-cancellation fix must (`stop`, once for the background itself and again for a
    /// pipeline undoing a start it no longer owns) and must NOT (`findBestServer`, a fresh state
    /// stream) let a cancelled pipeline reach. `startThrows`, when supplied, is thrown by `start()`
    /// AFTER its own gate opens instead of returning — the "retired pipeline whose start comes back
    /// a FAILURE" shape.
    private func makeStore(
        startCalls: SignalledRecords<Void>,
        gates: [ResumableGate],
        isMigrationSyncBlockedCalls: SignalledRecords<Void>? = nil,
        stopCalls: SignalledRecords<Void>? = nil,
        findBestServerCalls: SignalledRecords<Void>? = nil,
        stateStreamSubscriptions: SignalledRecords<Void>? = nil,
        startThrows: Error? = nil
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

                $0.autoServerSelection.findBestServer = {
                    findBestServerCalls?.recordCall()
                    return nil
                }

                $0.sdkSynchronizer = .mocked(
                    stateStream: {
                        stateStreamSubscriptions?.recordCall()
                        return Empty().eraseToAnyPublisher()
                    },
                    latestState: {
                        var syncState = SynchronizerState.zero
                        syncState.syncStatus = .upToDate
                        return syncState
                    },
                    prepareWith: { _, _, _, _ in .success },
                    start: { _ in
                        let ordinal = startCalls.recordCall()
                        await gates[min(ordinal, gates.count) - 1].wait()
                        if let startThrows {
                            throw startThrows
                        }
                    },
                    stop: {
                        stopCalls?.recordCall()
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
        gate: ResumableGate,
        stopCalls: SignalledRecords<Void>? = nil,
        findBestServerCalls: SignalledRecords<Void>? = nil,
        stateStreamSubscriptions: SignalledRecords<Void>? = nil,
        startThrows: Error? = nil
    ) -> TestStore<Root.State, Root.Action> {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            makeStore(
                startCalls: startCalls,
                gates: [gate],
                stopCalls: stopCalls,
                findBestServerCalls: findBestServerCalls,
                stateStreamSubscriptions: stateStreamSubscriptions,
                startThrows: startThrows
            )
        }
    }

    /// MOB-1854: builds a store whose FIRST `.retryStart` pipeline parks INSIDE
    /// `migrationManager.visitKind()` — i.e. BEFORE it ever reaches `sdkSynchronizer.start` — while
    /// every pipeline after it (a fresh foreground's admitted pipeline) passes straight through and
    /// parks inside `start()` instead, exactly like `makeStore(startCalls:gates:)` above. This is
    /// the "parked BEFORE start" shape: a pipeline cancelled while still doing migration work, never
    /// having touched the synchronizer at all. `visitKindCalls`, when supplied, records every
    /// `visitKind()` call (before it parks) so a test can wait for pipeline A to have genuinely
    /// entered the gate before backgrounding.
    private func makeStoreParkedBeforeStart(
        startCalls: SignalledRecords<Void>,
        beforeStartGate: ResumableGate,
        startGates: [ResumableGate],
        stopCalls: SignalledRecords<Void>? = nil,
        findBestServerCalls: SignalledRecords<Void>? = nil,
        stateStreamSubscriptions: SignalledRecords<Void>? = nil,
        visitKindCalls: SignalledRecords<Void>? = nil
    ) -> TestStore<Root.State, Root.Action> {
        let seedDerivedAccount = RootRetryStartReentrancyTests.seedDerivedAccount
        let visitKindOrdinal = LockIsolated<Int>(0)

        // Pinned to a fresh `InMemoryStorage`, same rationale as `makeStore(startCalls:gates:)` above.
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

                // Only the FIRST call (pipeline A) parks — every later pipeline's own visit passes
                // straight through, same ordinal idiom as `makeBroadcastOnlyStore`'s `visitKind` below.
                $0.migrationManager.visitKind = {
                    let ordinal = visitKindOrdinal.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    visitKindCalls?.recordCall()
                    if ordinal == 1 {
                        await beforeStartGate.wait()
                    }
                    return .sync
                }

                $0.autoServerSelection.findBestServer = {
                    findBestServerCalls?.recordCall()
                    return nil
                }

                $0.sdkSynchronizer = .mocked(
                    stateStream: {
                        stateStreamSubscriptions?.recordCall()
                        return Empty().eraseToAnyPublisher()
                    },
                    latestState: {
                        var syncState = SynchronizerState.zero
                        syncState.syncStatus = .upToDate
                        return syncState
                    },
                    prepareWith: { _, _, _, _ in .success },
                    start: { _ in
                        let ordinal = startCalls.recordCall()
                        await startGates[min(ordinal, startGates.count) - 1].wait()
                    },
                    stop: {
                        stopCalls?.recordCall()
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
        let stopCalls = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let store = makeStore(startCalls: startCalls, gates: [gateA, gateB], stopCalls: stopCalls)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let aGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        // Background WITHOUT releasing gateA — MOB-1854 cancels the first pipeline's `.run` effect
        // (`retryStartCancelId`), but the mocked `start()` is parked on a plain `ResumableGate`
        // (not itself cancellation-aware, same as the real `SlipstreamSynchronizer.start()` this
        // mock stands in for — see the re-entrancy guard's own doc), so A's task stays suspended
        // there until the test opens it, exactly as if backgrounding landed mid-`start()` for real.
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight, "backgrounding must reset the latch even though the in-flight pipeline never finished")
        await stopCalls.countReached(1)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        #expect(bGeneration != aGeneration, "backgrounding must give the next pipeline its own generation")
        await startCalls.countReached(2)
        #expect(startCalls.count == 2, "a retryStart after backgrounding must proceed even though the previous pipeline never finished")

        // Now let A's own long-parked start() finally return. A no longer owns anything —
        // backgrounding already cancelled its pipeline — but B, a NEWER pipeline, has already
        // been admitted (bGeneration above) by the time A's start() returns.
        //
        // This used to assert a SECOND `stop()` here (`stopCalls.countReached(2)`), on the theory
        // that a cancelled pipeline must always undo the start it no longer owns. That was itself
        // the bug: an unconditional undo tears down whatever the SDK is doing by the time this
        // cancelled pipeline's `start()` finally returns — which by now is B's fresh sync, not
        // anything of A's — and Root never restarts on the resulting `.stopped`. The fix reads a
        // shared admission counter (bumped once per pipeline admitted, never by a finish) and
        // undoes only while still holding the most recent admission, which stopped being true for
        // A the moment B was admitted above — so A's release here must add no second `stop()`.
        gateA.open()
        await drain(store)
        #expect(stopCalls.count == 1, "A must not undo a start B's own admission has already superseded")
        #expect(store.state.isRetryStartInFlight, "A's suppressed undo must not release the latch B still owns")

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
        let stopCalls = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let isMigrationSyncBlockedCalls = SignalledRecords<Void>()
        let store = makeStore(
            startCalls: startCalls,
            gates: [gateA, gateB],
            isMigrationSyncBlockedCalls: isMigrationSyncBlockedCalls,
            stopCalls: stopCalls
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let aGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)
        await stopCalls.countReached(1)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        #expect(bGeneration != aGeneration, "backgrounding must give the next pipeline its own generation")
        await startCalls.countReached(2)

        // Release ONLY A — B stays parked on its own gate, still the latch's current owner. A is
        // cancelled (MOB-1854), so releasing it must never reach `.registerForSynchronizersUpdate`/
        // `.retryStartFinished`: the generation guards on both those handlers stay as defense in
        // depth, but cancellation now stops a backgrounded pipeline before either send is even
        // attempted.
        //
        // A's release must also add no second `stop()`: B, a NEWER pipeline, was admitted above, so
        // the admission-gated undo leaves A's start() alone — an unconditional undo (this used to
        // assert `stopCalls.countReached(2)`) is exactly the bug that tears down a pipeline it
        // doesn't own, which is what MOB-1854's admission counter now prevents.
        gateA.open()
        await drain(store)
        #expect(stopCalls.count == 1, "A must not undo a start B's own admission has already superseded")
        #expect(isMigrationSyncBlockedCalls.isEmpty, "A's cancelled pipeline must not re-subscribe the synchronizer streams")
        #expect(store.state.isRetryStartInFlight, "A's undone start must not release the latch B still owns")

        gateB.open()
        await drain(store)
    }

    // MARK: - Backgrounding clears a deferred replay request, so a stale finish replays nothing

    @Test func backgroundingClearsADeferredReplayRequestSoTheStaleFinishReplaysNothing() async throws {
        let startCalls = SignalledRecords<Void>()
        let stopCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate, stopCalls: stopCalls)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
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
        await stopCalls.countReached(1)

        // A's own long-parked start() finally returns. It is cancelled (MOB-1854), so it undoes the
        // start rather than finishing — even though a replay was armed behind it before
        // backgrounding, that arming was already cleared above, and now the pipeline sends nothing
        // at all (no `.retryStartFinished`, so nothing to replay from).
        gate.open()
        await stopCalls.countReached(2)

        await drain(store)
        #expect(startCalls.count == 1, "a cancelled pipeline must not replay retryStart or call start() again")
        #expect(!store.state.retryStartRequestedWhileInFlight, "the cancelled pipeline must not re-arm the replay flag")
        #expect(!store.state.isRetryStartInFlight, "the cancelled pipeline must not re-set the latch")
    }

    // MARK: - MOB-1854: backgrounding while parked BEFORE start means no start, no observers, no selection
    //
    // The independent-review finding this task fixes: `.retryStart`'s `.run` effect carried no
    // cancellable id of its own, so a pipeline still parked in migration work when the app
    // backgrounds resumes on release and calls `start()`, re-subscribes transaction observation and
    // automatic server selection, and can schedule a retry — all for a foreground that has already
    // ended. `retryStartCancelId` (`RootStore.swift`) plus the `try Task.checkCancellation()`
    // checkpoints inside `.retryStart` (`RootInitialization.swift`) are the fix.

    @Test func backgroundingWhileParkedBeforeStartMeansNoStartNoObserversNoSelection() async throws {
        let startCalls = SignalledRecords<Void>()
        let stopCalls = SignalledRecords<Void>()
        let findBestServerCalls = SignalledRecords<Void>()
        let stateStreamSubscriptions = SignalledRecords<Void>()
        let visitKindCalls = SignalledRecords<Void>()
        let beforeStartGate = ResumableGate()
        // Never opened: if a regression lets the pipeline reach `start()` despite being cancelled
        // before it, this parks the mock forever instead of indexing off the end of an empty array
        // — the suite's own `.timeLimit` then records a clean failure instead of a crash.
        let unreachableStartGate = ResumableGate()
        let store = makeStoreParkedBeforeStart(
            startCalls: startCalls,
            beforeStartGate: beforeStartGate,
            startGates: [unreachableStartGate],
            stopCalls: stopCalls,
            findBestServerCalls: findBestServerCalls,
            stateStreamSubscriptions: stateStreamSubscriptions,
            visitKindCalls: visitKindCalls
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        // Parked inside `migrationManager.visitKind()` — before the pipeline has touched the
        // synchronizer at all.
        await visitKindCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)
        await stopCalls.countReached(1)

        // Release the pipeline. The first `try Task.checkCancellation()` it reaches — right before
        // the sync branch's own `advance(.beforeSync)` — throws the instant it resumes, so it never
        // reaches `advance`, `start`, or any of the tail sends.
        beforeStartGate.open()
        await drain(store)

        #expect(startCalls.count == 0, "a pipeline cancelled before start() must never call it")
        #expect(stopCalls.count == 1, "only the background's own stop — a pipeline that never started anything has nothing to undo")
        #expect(findBestServerCalls.count == 0, "a cancelled pipeline must not run automatic server selection")
        #expect(stateStreamSubscriptions.count == 0, "a cancelled pipeline must not re-register the state stream")
        #expect(!store.state.didScheduleStartFailureRetry, "a cancelled pipeline must not schedule a start-failure retry")
    }

    // MARK: - MOB-1854: backgrounding while start() is in flight undoes that start

    @Test func backgroundingWhileStartIsInFlightUndoesThatStart() async throws {
        let startCalls = SignalledRecords<Void>()
        let stopCalls = SignalledRecords<Void>()
        let stateStreamSubscriptions = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(
            startCalls: startCalls,
            gate: gate,
            stopCalls: stopCalls,
            stateStreamSubscriptions: stateStreamSubscriptions
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)
        await stopCalls.countReached(1)

        // Release the pipeline's parked start() call. It returns normally (the mock doesn't throw),
        // but the post-start `Task.isCancelled` check catches it: the pipeline no longer owns this
        // start, so it undoes it — the background's own `stop()` ran BEFORE this start was even
        // admitted, so undoing it here is the only thing that actually stops the engine.
        gate.open()
        await stopCalls.countReached(2)
        await drain(store)

        #expect(startCalls.count == 1, "the start already admitted before backgrounding still happens exactly once")
        #expect(stopCalls.count == 2, "the background's stop, then the pipeline undoing the start it no longer owns")
        #expect(stateStreamSubscriptions.count == 0, "an undone start must not re-register the state stream")
    }

    // MARK: - MOB-1854: a newer pipeline's admission suppresses the retired pipeline's undo
    //
    // The sibling of the test above, and the independent-review finding this fix round addresses:
    // the SDK's own lifecycle queue is FIFO. If A's undo were unconditional, and the app went to
    // background (A's undo enqueued behind A's own outstanding `start()`) and then came back to the
    // foreground admitting B BEFORE A's `start()` finally returned, A's eventual undo would run
    // AFTER B's fresh `start()` — tearing down the sync B just performed, with Root never restarting
    // on the resulting `.stopped`. Background alone must not suppress the undo (that is exactly the
    // case `backgroundingWhileStartIsInFlightUndoesThatStart` above proves it still runs for) — only
    // a NEWER admission may.

    @Test func backgroundingWhileStartIsInFlightThenAdmittingANewPipelineSuppressesTheUndo() async throws {
        let startCalls = SignalledRecords<Void>()
        let stopCalls = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let store = makeStore(startCalls: startCalls, gates: [gateA, gateB], stopCalls: stopCalls)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)
        await stopCalls.countReached(1)

        // Foreground admits B while A is still parked on its own long-outstanding start() call —
        // B's start() is admitted (and, in the mock, itself parked) while A's is still outstanding,
        // exactly like the real engine's FIFO lifecycle queue.
        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        await startCalls.countReached(2)

        // Release both. A returns from start() normally, but A was cancelled at background and B has
        // been admitted since — the undo must be suppressed: an unconditional stop() here would
        // tear down the sync B's own start() just began. B, unaffected by A's release, completes
        // normally. Deliberately NOT `drain(store)`ing between the two opens: `drain` clears TCA's
        // own in-flight-effects bookkeeping, and `store.receive` below only actually WAITS for a
        // not-yet-arrived action while that bookkeeping still shows an effect in flight — draining
        // first would make it fail-fast instead of giving B's (several-suspension-point-longer)
        // completion chain time to run, which is also what gives A's short, send-free suppressed
        // path time to finish.
        gateA.open()
        gateB.open()
        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let generation)) = action else { return false }
                return generation == bGeneration
            },
            timeout: .seconds(10)
        ) {
            $0.isRetryStartInFlight = false
        }

        await drain(store)
        #expect(startCalls.count == 2, "both A's and B's start() calls happen")
        #expect(stopCalls.count == 1, "only the background's own stop — A must not undo a start it no longer owns once B has been admitted, and B's normal finish must not call stop() at all")
    }

    // MARK: - MOB-1854: a retired pipeline failing after background schedules no retry

    @Test func aRetiredPipelineFailingAfterBackgroundSchedulesNoRetry() async throws {
        let startCalls = SignalledRecords<Void>()
        let stopCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = makeStore(
            startCalls: startCalls,
            gate: gate,
            stopCalls: stopCalls,
            startThrows: RetiredPipelineStartError()
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)
        await stopCalls.countReached(1)

        // Release the pipeline's parked start() call — it throws instead of returning, a start that
        // comes back a FAILURE for a pipeline that no longer owns anything. The thrown error is not
        // a `CancellationError`, so the general failure-handling code does run, but every `send`
        // inside it is still dropped by TCA's own cancelled-effect guard (`Send.callAsFunction`'s
        // `guard !Task.isCancelled`) — `.synchronizerStartFailed` never actually reaches the
        // reducer, so the one-shot retry it would otherwise arm (`didScheduleStartFailureRetry`) is
        // never scheduled. And since `start()` never returned successfully, there is nothing to
        // undo — no second `stop()`.
        gate.open()
        await drain(store)

        #expect(!store.state.didScheduleStartFailureRetry, "a cancelled pipeline's start failure must not arm the one-shot retry")
        #expect(startCalls.count == 1, "no retry effect ever re-called start() — the retry was never scheduled to begin with")
        #expect(stopCalls.count == 1, "a start that failed outright has nothing to undo — only the background's own stop")
    }

    // MARK: - MOB-1854: a new foreground start is unaffected by the old pipeline's eventual release

    @Test func aNewForegroundStartIsUnaffectedByTheOldPipelinesRelease() async throws {
        let startCalls = SignalledRecords<Void>()
        let visitKindCalls = SignalledRecords<Void>()
        let beforeStartGate = ResumableGate()
        let startGate = ResumableGate()
        let store = makeStoreParkedBeforeStart(
            startCalls: startCalls,
            beforeStartGate: beforeStartGate,
            startGates: [startGate],
            visitKindCalls: visitKindCalls
        )

        // Pipeline A: parked inside visitKind(), before it ever reaches start().
        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await visitKindCalls.countReached(1)

        // Background cancels A while it is still parked in migration work.
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight)

        // Foreground: a fresh retryStart admits pipeline B, its own generation. B's visitKind() call
        // is the SECOND overall, so the ordinal gating passes it straight through — B parks inside
        // start() instead, same as an ordinary in-flight start.
        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        // Release A's long-parked visitKind() — cancelled, so it stops at its own
        // `Task.checkCancellation()` checkpoint before ever reaching start().
        beforeStartGate.open()

        // Release B — unaffected by A's release; B's own start() is the only one that ever happens.
        startGate.open()

        await store.receive(
            { action in
                guard case .initialization(.retryStartFinished(let generation)) = action else { return false }
                return generation == bGeneration
            },
            timeout: .seconds(10)
        ) {
            $0.isRetryStartInFlight = false
        }

        await drain(store)
        #expect(startCalls.count == 1, "only B starts — A never reaches start() at all")
        #expect(!store.state.isRetryStartInFlight)
    }

    // MARK: - MOB-1854: the generation guards on retryStartFinished/registerForSynchronizersUpdate,
    // exercised directly
    //
    // Both guards are otherwise reachable only through a pipeline the `retryStartCancelId`
    // cancellation now stops before it can ever send either action for itself — so without a direct
    // `store.send`, they would pass vacuously. These two tests bypass the pipeline entirely and
    // send the actions straight in, proving the guards on their own terms.

    @Test func retryStartFinishedWithAStaleGenerationLeavesTheLatchAloneAndReplaysNothing() async throws {
        let startCalls = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let store = makeStore(startCalls: startCalls, gates: [gateA, gateB])

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let aGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let bGeneration = store.state.retryStartGeneration
        #expect(bGeneration != aGeneration, "backgrounding must give the next pipeline its own generation")
        await startCalls.countReached(2)

        // Sent directly with A's now-stale generation — B is current. A pipeline that reached this
        // send for itself is cancelled long before it gets here (see the suite's other tests); this
        // proves the guard rejects a stale generation independent of that cancellation.
        await store.send(.initialization(.retryStartFinished(generation: aGeneration)))
        #expect(store.state.isRetryStartInFlight, "a stale generation's finish must not clear the latch B still owns")
        #expect(!store.state.retryStartRequestedWhileInFlight, "a stale generation's finish must not replay anything")

        gateA.open()
        gateB.open()
        await drain(store)
    }

    @Test func registerForSynchronizersUpdateWithAStaleGenerationPerformsNoRegistrationButNilAlwaysRegisters() async throws {
        let startCalls = SignalledRecords<Void>()
        let isMigrationSyncBlockedCalls = SignalledRecords<Void>()
        let stateStreamSubscriptions = SignalledRecords<Void>()
        let gateA = ResumableGate()
        let gateB = ResumableGate()
        let store = makeStore(
            startCalls: startCalls,
            gates: [gateA, gateB],
            isMigrationSyncBlockedCalls: isMigrationSyncBlockedCalls,
            stateStreamSubscriptions: stateStreamSubscriptions
        )

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        let aGeneration = store.state.retryStartGeneration
        await startCalls.countReached(1)

        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        #expect(store.state.retryStartGeneration != aGeneration, "backgrounding must give the next pipeline its own generation")
        await startCalls.countReached(2)

        // Sent directly with A's now-stale generation — same rationale as the retryStartFinished
        // test above.
        await store.send(.initialization(.registerForSynchronizersUpdate(generation: aGeneration)))
        await drain(store)
        #expect(isMigrationSyncBlockedCalls.isEmpty, "a stale generation must not re-subscribe the migration gate feed")
        #expect(stateStreamSubscriptions.isEmpty, "a stale generation must not re-subscribe the state stream")

        // `nil` — the cold-launch call site's own generation-less shape — carries no generation to
        // compare, so the guard never applies to it: always honored, regardless of any pipeline's
        // current generation.
        await store.send(.initialization(.registerForSynchronizersUpdate(generation: nil)))
        await isMigrationSyncBlockedCalls.countReached(1)
        await stateStreamSubscriptions.countReached(1)

        gateA.open()
        gateB.open()
        await drain(store)
    }
}
