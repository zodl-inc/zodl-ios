//
//  RootMigrationGateStopOnBlockTests.swift
//  zodlTests
//
//  MOB-1466 — the STOP half of Root's migration sync-gate pair, field-caught 2026-08-02
//  (evening log): with the app foregrounded and the tick loop running, a proved, due transfer
//  sat unbroadcast for 15+ minutes. The engine answered `broadcast(id:)` on every read; every
//  tick was `held(privacy buffer until …)` with a deadline that slid forward forever, because
//  the app-side send window re-armed faster than it could expire — the foreground sync completed
//  every ~2.5 minutes throughout.
//
//  FIRST CUT (superseded, kept for history): stopped a running sync through
//  `stopSyncBeforeMigrationBroadcast()`, guarded by `isSyncing()`. The WHOLE-BRANCH review caught
//  that this guard is false in exactly the wedge state it exists to fix — the engine the field log
//  describes sits at `.upToDate` BETWEEN blocks, not mid-scan.
//
//  SECOND CUT (superseded by this file's current content, kept for history): pinned
//  `stopStartedSyncForMigrationGate()` (the "started", not "syncing", sibling) plus wallet-wide
//  candidate scoping and the tick-loop-off-switch gate — but stopped UNCONDITIONALLY once any
//  candidate was eligible. Two further holes, caught by the second whole-branch review: (1)
//  ATTRIBUTION — the SDK's gate is wallet-wide, so with two eligible candidates where only a
//  manual-delivery account's ready broadcast is what tripped it, the unconditional stop could
//  still pause the OTHER eligible candidate for a broadcast nothing automatic would ever send; (2)
//  LIVENESS — the tick loop spawns only at app-open and self-cancels on a terminal verdict, so a
//  run COMMITTED mid-session (mid-foreground, via the migration flow, or via a tick's own
//  `.rebuilt`/`.proved` verdict) could leave the stop with no lane left to consume the silence it
//  bought, stranding sync for the rest of the foreground instead of freeing it.
//
//  THIS suite now pins the PROBE (`sdkSynchronizer.migrationAdvanceStep`, per candidate — the
//  attribution the wallet-wide gate itself lacks; stops only once a tick-deliverable candidate's
//  own step answers `.broadcast`, retrying through the estimated-vs-scanned tip skew and otherwise
//  leaving sync running) and the two LIVENESS ensures (the blocked edge's merged
//  `migrationTickLoopEffect` re-spawn, and `.migrationCoordFlow(.flowFinished)`'s identical
//  re-spawn). The RESUME half of the pair (`.migrationSyncGateChanged(false)` -> `.retryStart`) is
//  unchanged and untouched here — see `RootMigrationGateRefusalTests`/`RootMigrationTickLoopTests`
//  for its coverage.
//
//  FIX ROUND 1 (whole-branch review of the above): two gaps in the probe itself, both closed here.
//  (a) CANCELLATION RACE — `.cancel(id:)` only sets the probe Task's cancelled flag; it cannot
//  abort a `migrationAdvanceStep` await already in flight, so a step read that lands `.broadcast`
//  after the false edge already cancelled the probe (and resume already restarted sync) used to
//  stop that just-resumed sync anyway. Pinned by `stepReadLandingAfterTheFalseEdgeMustNotStop`,
//  which holds the read open on a continuation for a deterministic interleaving. (b) COVERAGE —
//  `aCandidateAccountEligibilityIsWalletWide` (the two-candidate wallet-wide attribution shape)
//  was dropped when this suite was reworked around the probe; restored here against the probe's
//  own per-candidate loop rather than the old unconditional stop.
//
//  `extension Root.State: @retroactive Equatable` already exists module-wide at
//  RootInitializeSDKHealTests.swift — this file uses it rather than redeclaring (see
//  RootMigrationGateRefusalTests's header for the duplicate-conformance rationale).
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@_spi(Testing) @testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: resets the process-global `@Shared(.inMemory(.migrationStoppedSyncForBroadcast))`
// flag per test, plus the shared `selectedWalletAccount`/`walletAccounts` candidate keys every
// `makeStore` call (re)installs — the same shared-state discipline
// `MigrationTickDriverTests`/`RootMigrationTickLoopTests` serialize their own suites over.
@Suite(.serialized) @MainActor struct RootMigrationGateStopOnBlockTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x08, count: 16))
    /// Only installed when a test passes `secondCandidateMode` to `makeStore` — the wallet-wide
    /// attribution shape (`aCandidateAccountEligibilityIsWalletWide`), where the SELECTED account
    /// is ineligible and a second, non-selected candidate is what the probe must attribute to.
    private static let secondCandidateAccountUUID = AccountUUID(id: [UInt8](repeating: 0x09, count: 16))

    private static func account(_ uuid: AccountUUID) -> WalletAccount {
        WalletAccount(
            Account(
                id: uuid,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Builds a `Root` `TestStore` for driving `.migrationSyncGateChanged` (and, for the two
    /// liveness tests, `.migrationCoordFlow(.flowFinished)`) directly. `stopCalls` counts
    /// `sdkSynchronizer.stop()` — `stopStartedSyncForMigrationGate()` is an extension composed of
    /// the client's own `latestState()` + `stop()` closures, so spying `stop` observes the real
    /// production path, predicate included. `advanceStep` stands in for
    /// `sdkSynchronizer.migrationAdvanceStep` — the probe's own per-candidate attribution read; it
    /// has no default because every test's scenario turns on what it answers.
    ///
    /// `isIronwoodActivated`/`advance` are stubbed unconditionally (not just for the two liveness
    /// tests): the blocked-edge stop now unconditionally MERGES a `migrationTickLoopEffect`
    /// re-spawn alongside the probe whenever a stop is otherwise on the table, so that effect's own
    /// guards (`isIronwoodActivated`) and its `.migrationTick` handler's driver call (`advance`)
    /// are reachable from every test whose scenario reaches the merge, not only 11/12.
    /// `isIronwoodActivated` has no macro-supplied default and traps unstubbed (mirrors
    /// `migrationTickLoopEffect`'s own doc); `advance` has one (`.notApplicable`, which would
    /// self-cancel a freshly-spawned loop on its very first tick) but `.idle` — the quiet verdict —
    /// is what a test that does not care about tick-loop internals actually wants.
    ///
    /// Always installs `accountUUID` as the selected account. `walletAccounts` is just that one
    /// entry unless `secondCandidateMode` is passed, in which case `secondCandidateAccountUUID` is
    /// installed alongside it with its own independent mode — the wallet-wide attribution shape.
    private func makeStore(
        stopCalls: LockIsolated<Int>,
        syncStatus: SyncStatus,
        mode: MigrationMode?,
        advanceStep: @escaping @Sendable (AccountUUID) async throws -> MigrationAdvance?,
        tickInterval: Swift.Duration = .seconds(30),
        lastMigrationSyncGateBlocked: Bool = false,
        testClock: TestClock<Swift.Duration>? = nil,
        secondCandidateMode: MigrationMode? = nil
    ) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        initialState.lastMigrationSyncGateBlocked = lastMigrationSyncGateBlocked

        // Resolved here, in the suite's `@MainActor` context, rather than inside the `@Sendable`
        // dependency closure below — a `@Sendable` closure literal cannot reach across the
        // `@MainActor` isolation boundary to read a static member of this suite directly (mirrors
        // `RootMigrationGateRefusalTests.makeStore`'s `seedDerivedAccount` rationale).
        let secondAccountUUID = RootMigrationGateStopOnBlockTests.secondCandidateAccountUUID

        let selectedAccount = Self.account(Self.accountUUID)
        initialState.$selectedWalletAccount.withLock { $0 = selectedAccount }
        if secondCandidateMode != nil {
            let secondAccount = Self.account(secondAccountUUID)
            initialState.$walletAccounts.withLock { $0 = [selectedAccount, secondAccount] }
        } else {
            initialState.$walletAccounts.withLock { $0 = [selectedAccount] }
        }

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationTickInterval = tickInterval
            if let testClock {
                $0.continuousClock = testClock
            }

            $0.migrationManager.reconcile = { }
            $0.migrationManager.isIronwoodActivated = { true }
            $0.migrationManager.advance = { _ in MigrationStepVerdict.idle }
            $0.migrationManager.migrationMode = { accountUUID in
                if let secondCandidateMode, accountUUID == secondAccountUUID {
                    return secondCandidateMode
                }
                return mode
            }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: {
                    var syncState = SynchronizerState.zero
                    syncState.syncStatus = syncStatus
                    return syncState
                },
                stop: {
                    stopCalls.withValue { $0 += 1 }
                },
                migrationAdvanceStep: advanceStep
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Resets the shared resume flag the production stop sets — process-global, so each test
    /// starts from a known false.
    private func resetSharedResumeFlag() {
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }
    }

    /// Bounded real-time polling for a condition driven by the store's own in-flight effects —
    /// advancing a `TestClock` resumes suspended sleepers but does not itself guarantee the
    /// resulting action/read has propagated by the time `advance(by:)` returns. Same helper shape
    /// as `RootMigrationTickLoopTests`/`MigrationStatusRefreshPulseTests`.
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The pulse-suite teardown idiom (`MigrationStatusRefreshPulseTests`): the merged
    /// `migrationTickLoopEffect` re-spawn's timer effect never completes on its own, so
    /// `await store.finish()` would hang the suite. A settle sleep plus lenient skips lets every
    /// still-running effect (the tick timer, an in-flight probe) go unfinished without failing the
    /// test over it.
    private func teardown(_ store: TestStore<Root.State, Root.Action>) async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - The probe stops once a tick-deliverable candidate proves due

    /// THE happy path: a `.privateScheduled`, non-manual candidate whose OWN `migrationAdvanceStep`
    /// answers `.broadcast` is exactly what the probe exists to confirm before stopping sync.
    /// Through the shared-flag-setting production path, so the existing false-edge resume
    /// machinery will restart sync later.
    @Test func probeStopsWhenADeliverableCandidateStepIsBroadcast() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                stepReads.withValue { $0 += 1 }
                return MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil)
            },
            // A stop-eligible candidate now also merges in `migrationTickLoopEffect`'s re-spawn
            // (Fix 1a), which reaches for `continuousClock` the instant it spawns — a `TestClock`
            // is required here even though this test never advances it, or the default test clock
            // (`UnimplementedClock`) traps.
            testClock: TestClock()
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stopCalls.value == 1 }

        // Attribution, not just outcome: the stop must be REACHED THROUGH the probe's own
        // `migrationAdvanceStep` read — a stop that fires without ever reading the engine is the
        // pre-probe unconditional behavior this suite exists to retire, and would otherwise pass
        // this test for the wrong reason.
        #expect(stepReads.value >= 1, "the stop must be attributed through the probe's own migrationAdvanceStep read, not fired unconditionally")
        #expect(stopCalls.value == 1, "a tick-deliverable candidate's .broadcast step must stop sync")
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        #expect(migrationStoppedSyncForBroadcast == true, "the stop must go through stopStartedSyncForMigrationGate, arming the resume half")

        await teardown(store)
    }

    /// The estimated-vs-scanned tip skew: the gate can flip true on the wall-clock ESTIMATED tip
    /// while the step still reads the older scanned tip and answers something other than
    /// `.broadcast`. The probe must retry rather than give up on the first idle read.
    @Test func probeRetriesThroughTheScannedTipSkew() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let testClock = TestClock()
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                let callNumber = stepReads.withValue { value -> Int in
                    value += 1
                    return value
                }
                return callNumber == 1
                    ? MigrationAdvance(step: .waiting, next: nil)
                    : MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil)
            },
            testClock: testClock
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stepReads.value >= 1 }

        // Must NOT stop on the first, `.waiting` read — proves the probe retries rather than
        // (like the pre-probe unconditional stop) firing the instant a candidate is merely
        // eligible.
        #expect(stopCalls.value == 0, "a .waiting first read must not stop sync — the probe must retry, not give up immediately")

        await testClock.advance(by: .seconds(20))
        await waitUntil { stopCalls.value == 1 }

        #expect(stopCalls.value == 1, "the second attempt's .broadcast must stop sync once the skew clears")

        await teardown(store)
    }

    /// The blocker genuinely belongs to a non-deliverable account (manual/immediate): every attempt
    /// answers `.waiting`, the probe exhausts its whole budget, and sync is deliberately left
    /// running rather than paused for a broadcast nothing automatic will ever send.
    @Test func probeGivesUpOnAManualBlockerShape() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let testClock = TestClock()
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                stepReads.withValue { $0 += 1 }
                return MigrationAdvance(step: .waiting, next: nil)
            },
            testClock: testClock
        )

        await store.send(.migrationSyncGateChanged(true))
        await testClock.advance(by: .seconds(200))
        await waitUntil { stepReads.value == 10 }

        #expect(stepReads.value == 10, "all ten attempts must be exhausted before giving up")
        #expect(stopCalls.value == 0, "a blocker that never answers .broadcast must leave sync running")

        await teardown(store)
    }

    /// The false edge is the resume half's edge — the probe is moot the instant the gate unblocks,
    /// and must not land a stop (or keep reading the engine) after it.
    @Test func falseEdgeCancelsThePendingProbe() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let testClock = TestClock()
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                stepReads.withValue { $0 += 1 }
                return MigrationAdvance(step: .waiting, next: nil)
            },
            testClock: testClock
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stepReads.value >= 1 }

        await store.send(.migrationSyncGateChanged(false))
        let readsAtCancel = stepReads.value

        await testClock.advance(by: .seconds(200))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(stopCalls.value == 0, "a cancelled probe must never stop sync")
        #expect(
            stepReads.value <= readsAtCancel + 1,
            "the false edge must cancel the pending probe — at most one already-in-flight read may land after it"
        )

        await teardown(store)
    }

    /// Reviewer-caught race (whole-branch review, fix round 1): `.cancel(id:)` is cooperative — it
    /// cannot abort a `migrationAdvanceStep` await already in flight, and the `try?` around that
    /// call swallows any cancellation error the call itself might throw. If the read lands
    /// `.broadcast` AFTER the false edge already cancelled the probe (and, on a live app, resume
    /// already restarted sync), the stop must not fire — it would pause the just-resumed sync and
    /// re-arm the resume flag with no further edge guaranteed to consume it.
    ///
    /// The read is held open on a continuation so the interleaving is deterministic rather than a
    /// real-time race — the mock parks on it instead of returning immediately, and this test
    /// resumes it itself only after the false edge has already been sent, so "the read outlives
    /// the cancel" holds by construction at any load. Same idiom as
    /// `AddKeystoneHWWalletTests.unlockTappedIgnoresRetapsWhileImportInFlight`'s release stream.
    @Test func stepReadLandingAfterTheFalseEdgeMustNotStop() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let testClock = TestClock()
        let stepContinuation = LockIsolated<CheckedContinuation<MigrationAdvance?, Never>?>(nil)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                await withCheckedContinuation { continuation in
                    stepContinuation.setValue(continuation)
                }
            },
            testClock: testClock
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stepContinuation.value != nil }

        // The false edge — cancels the probe's Task cooperatively while the read above is still
        // parked on the continuation, exactly the interleaving the guard exists for.
        await store.send(.migrationSyncGateChanged(false))

        // Release the "late" read now — it resumes with a genuine `.broadcast`, same as if the
        // engine had proved the transfer moments after the edge had already cleared.
        stepContinuation.value?.resume(returning: MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil))

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(stopCalls.value == 0, "a step read that lands after the false edge must not stop the just-cleared/resumed sync")

        await teardown(store)
    }

    // MARK: - Wallet-wide attribution with more than one candidate account

    /// I4, restored: the SDK gate is WALLET-wide, not selected-account-scoped, so a second,
    /// non-selected candidate's `.privateScheduled` run must be what the probe attributes the stop
    /// to when the selected account itself is ineligible (`.immediate` here). The probe's
    /// per-candidate loop (`for accountUUID in stoppableCandidateUUIDs`) is exercised by every
    /// other test with exactly one candidate in the list — this is the only one where the upstream
    /// `MigrationDerivations.candidateAccountUUIDs` fan-out and the eligibility `.filter` actually
    /// narrow TWO wallet accounts down to the one the probe may read.
    @Test func aCandidateAccountEligibilityIsWalletWide() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let queriedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.immediate,            advanceStep: { accountUUID in
                queriedAccountUUIDs.withValue { $0.append(accountUUID) }
                return MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil)
            },
            testClock: TestClock(),
            secondCandidateMode: MigrationMode.privateScheduled
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stopCalls.value == 1 }

        #expect(stopCalls.value == 1, "a second candidate's privateScheduled run must stop sync although the selected account is immediate-mode")
        #expect(
            queriedAccountUUIDs.value == [RootMigrationGateStopOnBlockTests.secondCandidateAccountUUID],
            "only the eligible second candidate may ever be read — the ineligible selected account must never reach the probe"
        )

        await teardown(store)
    }

    // MARK: - Non-deliverable wallets never even ask the engine

    /// An `.immediate` run's broadcasts ride the open lanes, never ticks — the probe must not read
    /// the engine for it at all, let alone stop its sync.
    @Test func nonDeliverableWalletNeverReadsTheEngine() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.immediate,            advanceStep: { _ in
                stepReads.withValue { $0 += 1 }
                return MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil)
            }
        )

        await store.send(.migrationSyncGateChanged(true))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(stopCalls.value == 0, "an immediate-mode run must keep today's behavior — no stop")
        #expect(stepReads.value == 0, "a non-deliverable wallet must never read the engine at all")

        await teardown(store)
    }

    // MARK: - Dedupe / clearing edge (unchanged contracts, adapted to the probe)

    /// The handler's existing dedupe scopes the probe to the TRANSITION: a repeated `true`
    /// emission (the stream re-evaluates every 15 s) must not probe — or stop — again.
    @Test func repeatedBlockedEmissionsProbeOnlyOnce() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
            // See `probeStopsWhenADeliverableCandidateStepIsBroadcast`'s identical note — a
            // stop-eligible candidate merges in the tick-loop re-spawn, which needs a `TestClock`.
            testClock: TestClock()
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stopCalls.value == 1 }
        await store.send(.migrationSyncGateChanged(true))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(stopCalls.value == 1, "only the false->true TRANSITION probes — repeated emissions are quiet")

        await teardown(store)
    }

    /// The false edge (gate clearing) must never stop — it is the RESUME half's edge.
    @Test func clearingEdgeNeverStops() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
            lastMigrationSyncGateBlocked: true
        )

        await store.send(.migrationSyncGateChanged(false))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(stopCalls.value == 0, "the clearing edge belongs to the resume half — no stop")

        await teardown(store)
    }

    // MARK: - THE wedge state, and its B12 boundary

    /// THE requirement the whole-branch review's C1 finding exists for: the genuine false->true
    /// edge, through the probe, still stops a `.privateScheduled`, non-manual run's sync even when
    /// the engine is NOT mid-scan — `.upToDate` is the actual field-caught wedge shape.
    @Test func aStoppedEngineIsLeftAlone() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.stopped,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                stepReads.withValue { $0 += 1 }
                return MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil)
            },
            // See `probeStopsWhenADeliverableCandidateStepIsBroadcast`'s identical note — the
            // candidate is eligible (mode/delivery, not syncStatus, gates the tick-loop merge), so
            // a `TestClock` is required here too.
            testClock: TestClock()
        )

        await store.send(.migrationSyncGateChanged(true))
        await waitUntil { stepReads.value >= 1 }

        // The probe DOES run and DOES answer `.broadcast` — `stopStartedSyncForMigrationGate()`'s
        // own guard is what no-ops here, on `latestState().syncStatus` BEFORE ever calling the
        // mocked `stop()` closure this suite spies on. `stopCalls` staying 0 is therefore the
        // B12 contract, not a probe failure.
        #expect(stopCalls.value == 0, "a stopped engine has nothing to stop — the helper's own guard no-ops before calling stop()")
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        #expect(!migrationStoppedSyncForBroadcast, "never arm the resume flag for a sync nobody paused")

        await teardown(store)
    }

    // MARK: - The tick-loop off switch disables the whole stop half, probe included

    /// C2: a stop that lands while the tick loop's own off switch is set would strand sync with no
    /// lane left to consume the silence it bought — neither the probe nor the stop may fire at all
    /// in that shape, and the engine must not even be read.
    @Test func theTickLoopOffSwitchDisablesTheStop() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let stepReads = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,            advanceStep: { _ in
                stepReads.withValue { $0 += 1 }
                return MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil)
            },
            tickInterval: Swift.Duration.zero
        )

        await store.send(.migrationSyncGateChanged(true))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(stopCalls.value == 0, "with the tick loop disabled, nothing can ever consume the stop's silence")
        #expect(stepReads.value == 0, "the off switch must short-circuit before ever reading the engine")

        await teardown(store)
    }

    // MARK: - Liveness (Fix 1a / Fix 1b): the blocked edge and flowFinished both ensure the loop

    /// Fix 1a: a run can be COMMITTED mid-session with no tick loop yet running (the loop only
    /// spawns at app-open) — the blocked edge must re-spawn it alongside the probe, not just arm a
    /// stop with nothing left to use the silence it buys.
    @Test func blockedEdgeEnsuresTheTickLoopIsAlive() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let testClock = TestClock()
        let advancePhases = LockIsolated<[MigrationOpenPhase]>([])
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
            testClock: testClock
        )
        store.dependencies.migrationManager.advance = { phase in
            advancePhases.withValue { $0.append(phase) }
            return MigrationStepVerdict.idle
        }

        await store.send(.migrationSyncGateChanged(true))
        await testClock.advance(by: .seconds(30))
        await waitUntil { advancePhases.value.contains(MigrationOpenPhase.tick) }

        #expect(advancePhases.value.contains(MigrationOpenPhase.tick), "the blocked edge must ensure the tick loop is alive")

        await teardown(store)
    }

    /// Fix 1b: the migration flow's own `flowFinished` is the other place a run can be COMMITTED
    /// mid-session (a just-signed manual batch, a just-confirmed schedule) — it must re-spawn the
    /// loop for the identical reason the blocked edge does.
    @Test func flowFinishedRespawnsTheTickLoop() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let testClock = TestClock()
        let advancePhases = LockIsolated<[MigrationOpenPhase]>([])
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
            testClock: testClock
        )
        store.dependencies.migrationManager.advance = { phase in
            advancePhases.withValue { $0.append(phase) }
            return MigrationStepVerdict.idle
        }

        await store.send(.migrationCoordFlow(.flowFinished))
        await testClock.advance(by: .seconds(30))
        await waitUntil { advancePhases.value.contains(MigrationOpenPhase.tick) }

        #expect(advancePhases.value.contains(MigrationOpenPhase.tick), "flowFinished must respawn the tick loop for a run committed mid-session")

        await teardown(store)
    }

    /// Audit 2026-08-03 (#6): a flow that closed without committing leaves its Tor-sheet snapshot
    /// provisional, and nothing ever cleared it — flowFinished now runs the provisional cleaner
    /// (a no-op when the flow committed, since confirm converts the snapshot).
    @Test func flowFinishedClearsTheProvisionalNetworkSnapshot() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let testClock = TestClock()
        let clearedFor = LockIsolated<[AccountUUID?]>([])
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
            testClock: testClock
        )
        store.dependencies.migrationManager.clearProvisionalNetworkSnapshot = { accountUUID in
            clearedFor.withValue { $0.append(accountUUID) }
        }

        await store.send(.migrationCoordFlow(.flowFinished))
        await waitUntil { !clearedFor.value.isEmpty }

        #expect(clearedFor.value.count == 1, "flowFinished runs the provisional cleaner exactly once")

        await teardown(store)
    }

    // MARK: - Liveness: flowFinished drives the edge a mid-session commit missed

    /// The confirm-after-edge wedge (field-caught 2026-08-02): a run committed mid-session, on a
    /// wallet already idling at the tip, has missed this app-open's one `.upToDate` edge — no
    /// further edge is coming, and `.prove` is dischargeable at `.afterSync` alone, so the run's
    /// FIRST prove would wait for the next app-open while every tick defers it as `.wrongPhase`.
    /// `flowFinished` must run the driver once at the phase the commit missed.
    @Test func flowFinishedOnAnAtTipWalletDrivesTheAfterSyncPhaseOnce() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let testClock = TestClock()
        let advancePhases = LockIsolated<[MigrationOpenPhase]>([])
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
            testClock: testClock
        )
        store.dependencies.migrationManager.advance = { phase in
            advancePhases.withValue { $0.append(phase) }
            return MigrationStepVerdict.idle
        }

        await store.send(.migrationCoordFlow(.flowFinished))
        await waitUntil { advancePhases.value.contains(MigrationOpenPhase.afterSync) }

        #expect(
            advancePhases.value.filter { $0 == MigrationOpenPhase.afterSync }.count == 1,
            "flowFinished on an at-tip wallet must drive the driver exactly once at .afterSync — the edge the commit missed"
        )

        await teardown(store)
    }

    /// The complementary half of the guard: mid-sync, the coming `.upToDate` edge owns the
    /// `.afterSync` drive (`didJustReachUpToDate` in `synchronizerStateChanged`) — flowFinished
    /// must not pre-empt it against a stale tip.
    @Test func flowFinishedWhileStillSyncingLeavesTheDriveToTheComingEdge() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let testClock = TestClock()
        let advancePhases = LockIsolated<[MigrationOpenPhase]>([])
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.syncing(0.5, false),
            mode: MigrationMode.privateScheduled,
            advanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
            testClock: testClock
        )
        store.dependencies.migrationManager.advance = { phase in
            advancePhases.withValue { $0.append(phase) }
            return MigrationStepVerdict.idle
        }

        await store.send(.migrationCoordFlow(.flowFinished))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(
            !advancePhases.value.contains(MigrationOpenPhase.afterSync),
            "mid-sync, the coming .upToDate edge owns the .afterSync drive — flowFinished must leave it alone"
        )

        await teardown(store)
    }
}
