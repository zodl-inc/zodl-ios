//
//  RootMigrationTickLoopTests.swift
//  zodlTests
//
//  MOB-1466 — the FOREGROUND TICK LOOP: with a `privateScheduled` migration run active, an app left
//  open advances the migration on a recurring 30s wake-up rather than waiting for the next app-open.
//
//  These are Root-level TestStore tests, mirroring `RootMigrationGateRefusalTests`'s dependency
//  stubbing (driving real lifecycle actions through a real `Root` reducer) and
//  `MigrationSyncCompleteEdgeTests`'s spy-client pattern — but the spy here stands in for the WHOLE
//  `migrationManager` client, since what is under test is Root's OWN loop-management reducer logic
//  (spawn / restart / cancel / self-stop), not the driver's internals (covered by
//  `MigrationTickDriverTests` instead).
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized per repo convention for suites driving lifecycle actions through a real TestStore —
// see `RootMigrationGateRefusalTests`'s identical `@Suite(.serialized)` rationale.
@Suite(.serialized) @MainActor struct RootMigrationTickLoopTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0A, count: 16))

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Records every `advance` call's phase and answers a caller-configured, mutable verdict —
    /// standing in for the WHOLE `migrationManager` client (`isIronwoodActivated`/`migrationMode`
    /// included) so these tests exercise Root's loop-management reducer logic in isolation from the
    /// driver's own internals.
    private final class TickSpy: @unchecked Sendable {
        let phases = LockIsolated<[MigrationOpenPhase]>([])
        let verdict: LockIsolated<MigrationStepVerdict>
        private let ironwoodActivated: LockIsolated<Bool>
        private let mode: LockIsolated<MigrationMode?>

        init(
            verdict: MigrationStepVerdict = .idle,
            isIronwoodActivated: Bool = true,
            migrationMode: MigrationMode? = .privateScheduled
        ) {
            self.verdict = LockIsolated(verdict)
            self.ironwoodActivated = LockIsolated(isIronwoodActivated)
            self.mode = LockIsolated(migrationMode)
        }

        var tickCalls: Int { phases.value.filter { $0 == MigrationOpenPhase.tick }.count }
        var nonTickCalls: Int { phases.value.filter { $0 != MigrationOpenPhase.tick }.count }

        func install(_ values: inout DependencyValues) {
            var client = MigrationManagerClient.noOp
            client.isIronwoodActivated = { [ironwoodActivated] in ironwoodActivated.value }
            client.migrationMode = { [mode] _ in mode.value }
            client.visitKind = { .sync }
            client.advance = { [phases, verdict] phase in
                phases.withValue { $0.append(phase) }
                return verdict.value
            }
            client.armNextWindowNotifications = { _ in }
            values.migrationManager = client
        }
    }

    /// Builds a `Root` `TestStore` with `accountUUID` pre-selected (the sole candidate the spawn
    /// condition and the spy's `migrationMode` both key off), the injected `testClock` standing in
    /// for `@Dependency(\.continuousClock)`, and enough of the rest of Root's dependency surface
    /// stubbed for `.initializationSuccessfullyDone`/`.appDelegate(.willEnterForeground)`/
    /// `.appDelegate(.didEnterBackground)` to run without crashing — mirrors
    /// `RootMigrationGateRefusalTests.makeStore`.
    private func makeStore(
        spy: TickSpy,
        testClock: TestClock<Swift.Duration>,
        // A literal, not Constants.migrationTickInterval: these tests exercise the loop, so they must not go blind when the shipped default is the .zero off switch.
        tickInterval: Swift.Duration = .seconds(30),
        lastMigrationSyncGateBlocked: Bool = false,
        syncDeferredByMigrationGate: Bool = false
    ) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .home),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        initialState.$selectedWalletAccount.withLock { $0 = Self.account() }
        initialState.$walletAccounts.withLock { $0 = [Self.account()] }
        initialState.lastMigrationSyncGateBlocked = lastMigrationSyncGateBlocked
        initialState.syncDeferredByMigrationGate = syncDeferredByMigrationGate

        let store = TestStore(initialState: initialState) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.continuousClock = testClock
            $0.migrationTickInterval = tickInterval

            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { },
                reset: { }
            )

            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet

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
            $0.autoServerSelection.findBestServer = { nil }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: {
                    var syncState = SynchronizerState.zero
                    syncState.syncStatus = .upToDate
                    return syncState
                },
                start: { _ in },
                stop: { },
                isMigrationSyncBlocked: { false },
                migrationSyncBlockedStream: { Empty().eraseToAnyPublisher() },
                getAllTransactions: { _ in [] }
            )

            spy.install(&$0)
        }
        store.exhaustivity = .off
        return store
    }

    /// Lets the rest of a cascade (SmartBanner evaluation, contacts, user metadata, the battery-state
    /// subscription, the migration gate stream, …) settle without asserting on any of it — identical
    /// rationale to `RootMigrationGateRefusalTests`'s `drain`. Deliberately does NOT send
    /// `.cancelAllRunningEffects` — that action cancels a fixed, unrelated set of legacy cancel ids
    /// and has nothing to do with the tick loop's own id, so cancelling it here would mask exactly
    /// the cancellation behaviour some of these tests exist to prove.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// Bounded real-time polling for a condition driven by the store's own concurrently-running
    /// effects — needed because advancing a `TestClock` resumes suspended sleepers but does not
    /// itself guarantee the resulting action has finished propagating through the store by the time
    /// `advance(by:)` returns.
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Launch snapshot sweep (audit 2026-08-03, #6)

    /// The launch-time sweep the snapshot docs always named but nothing implemented: every
    /// candidate account's abandoned pre-commit network snapshot is cleared at launch-done, so a
    /// flow the app died inside can no longer pin auto-server selection forever.
    @Test func launchDoneSweepsAbandonedSnapshotsForEveryCandidate() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)
        let sweptFor = LockIsolated<[AccountUUID]>([])
        store.dependencies.migrationManager.clearAbandonedNetworkSnapshot = { accountUUID in
            if let accountUUID {
                sweptFor.withValue { $0.append(accountUUID) }
            }
        }

        await store.send(.initialization(.initializationSuccessfullyDone))
        await waitUntil { !sweptFor.value.isEmpty }

        #expect(sweptFor.value == [Self.accountUUID], "every candidate account gets the abandoned-snapshot sweep at launch")

        await drain(store)
    }

    // MARK: - First tick, never at t=0

    @Test func noTickBeforeThirtySecondsElapse() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(29))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(spy.tickCalls == 0, "the first tick must not fire before a full 30s has elapsed")

        await testClock.advance(by: .seconds(1))
        await waitUntil { spy.tickCalls == 1 }
        #expect(spy.tickCalls == 1)

        await drain(store)
    }

    // MARK: - Foreground restart resets the countdown (§5 / §9)

    @Test func foregroundRestartResetsTheCountdown() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(29))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(spy.tickCalls == 0)

        await store.send(.initialization(.appDelegate(.willEnterForeground)))

        await testClock.advance(by: .seconds(29))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(spy.tickCalls == 0, "the foreground restart must reset the countdown, not merely continue the old one")

        await testClock.advance(by: .seconds(1))
        await waitUntil { spy.tickCalls == 1 }
        #expect(spy.tickCalls == 1, "exactly one tick once the RESTARTED countdown reaches 30s")

        await drain(store)
    }

    // MARK: - Backgrounding cancels

    @Test func backgroundingCancelsTheLoop() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))
        await store.send(.initialization(.appDelegate(.didEnterBackground)))

        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(spy.tickCalls == 0, "no tick advance may occur once the app is backgrounded, however far the clock runs")

        await drain(store)
    }

    // MARK: - Ticks call .tick, and nothing else

    @Test func ticksOnlyEverCallAdvanceAtTickPhase() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(90))
        await waitUntil { spy.tickCalls >= 3 }

        #expect(spy.tickCalls == 3, "three 30s wake-ups in 90s")
        #expect(spy.nonTickCalls == 0, ".initializationSuccessfullyDone alone must never call .beforeSync/.afterSync")

        await drain(store)
    }

    // MARK: - Spawn condition

    /// G1 (field 2026-08-05): an IMMEDIATE-mode run spawns the loop too. A run's
    /// note-preparations are engine-paced wallet plumbing in EVERY mode, and the tick lane is
    /// what proves and delivers them between opens — the belt still holds immediate-mode
    /// TRANSFERS (AUD-3 F4 exempts preps from it), so a live loop changes nothing about the
    /// user's own delivery pace. The old pin here asserted the opposite and starved immediate
    /// runs' splits of their only between-opens discharger.
    @Test func immediateModeCandidateSpawnsTheLoop() async {
        let spy = TickSpy(migrationMode: .immediate)
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(30))
        await waitUntil { spy.tickCalls == 1 }
        #expect(spy.tickCalls == 1, "a committed immediate-mode run must tick — its preparations are engine-paced")

        await drain(store)
    }

    /// No stored mode = no committed run = nothing for a tick to help with — the loop never
    /// spawns. (This is the fresh-install / pre-commit shape; a run committed MID-session gets
    /// its loop from the commit delegates in `RootCoordinator`, not from this launch-time spawn.)
    @Test func noCommittedRunNeverSpawnsTheLoop() async {
        let spy = TickSpy(migrationMode: nil)
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(spy.tickCalls == 0, "with no committed run the loop must never spawn at all")

        await drain(store)
    }

    @Test func ironwoodNotActivatedNeverSpawnsTheLoop() async {
        let spy = TickSpy(isIronwoodActivated: false)
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(spy.tickCalls == 0, "pre-activation, the loop must never spawn regardless of mode")

        await drain(store)
    }

    // MARK: - Self-stop

    /// Audit 2026-08-03 (P1): `.notApplicable` must NOT self-stop the loop — the driver answers
    /// it for transient wobbles too (a tip momentarily reading 0 during an engine restart, an
    /// account list momentarily empty during a switch), and cancelling on those killed the tick
    /// lane for the rest of the session. A live loop's 30 s guard re-check costs nothing.
    @Test func notApplicableVerdictKeepsTheLoopAlive() async {
        let spy = TickSpy(verdict: .notApplicable)
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(30))
        await waitUntil { spy.tickCalls == 1 }
        #expect(spy.tickCalls == 1)

        await testClock.advance(by: .seconds(30))
        await waitUntil { spy.tickCalls == 2 }
        #expect(spy.tickCalls == 2, "a transient .notApplicable must not kill the loop — the next tick still fires")

        await drain(store)
    }

    @Test func terminalVerdictSelfStopsTheLoopUntilTheNextForeground() async {
        let spy = TickSpy(verdict: .complete)
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(30))
        await waitUntil { spy.tickCalls == 1 }
        #expect(spy.tickCalls == 1)

        await testClock.advance(by: .seconds(300))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(spy.tickCalls == 1, "a terminal verdict must self-stop the loop — no further ticks no matter how far the clock runs")

        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await testClock.advance(by: .seconds(30))
        await waitUntil { spy.tickCalls == 2 }
        #expect(spy.tickCalls == 2, "a fresh foreground must respawn the loop")

        await drain(store)
    }

    // MARK: - Resume invariant (I5): a broadcast that suppresses sync must always end with an
    // armed resume — see `.migrationSyncGateChanged(false)`'s `shouldResume` computation.
    //
    // Three sync states at the moment a broadcast lands, per the driver's `broadcastOneTransfer` /
    // `stopSyncBeforeMigrationBroadcast`:
    //  (a) actively syncing — `stopSyncBeforeMigrationBroadcast` stops it and sets the shared
    //      `migrationStoppedSyncForBroadcast` flag. Pinned below — the EXISTING mechanism, now
    //      exercised for a tick-triggered broadcast rather than only an app-open's.
    //  (b) already stopped-and-deferred (`syncDeferredByMigrationGate` true) — covered by
    //      `RootMigrationGateRefusalTests.migrationSyncGateChangedToUnblockedTriggersRetryStart`,
    //      not duplicated here.
    //  (c) started but IDLE AT THE TIP — nothing to stop, so NEITHER flag gets set by the broadcast
    //      itself. Pinned below: WITHOUT the tick handler's own pre-arm, this is the one state that
    //      leaves `.retryStart` never sent once the SDK's own post-broadcast gate clears.

    /// (a) — unchanged from today's behavior; a tick-triggered broadcast that had to stop an
    /// in-flight sync resumes it exactly as an app-open's broadcast already does.
    @Test func resumeInvariantWhenSyncWasActivelyStopped() async throws {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock, lastMigrationSyncGateBlocked: true)

        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = true }

        await store.send(.migrationSyncGateChanged(false)) { state in
            state.lastMigrationSyncGateBlocked = false
        }

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(!migrationStoppedSyncForBroadcast, "the resume must clear the flag it consumed")

        // Parked-debt pin (2026-08-03): `.off` exhaustivity would silently swallow a SPURIOUS
        // second resume — a duplicated `.retryStart` means a duplicated `.beforeSync` driver call
        // (a second engine read and a second arming pass per resume). The spy counts the phase,
        // so the pin is on the observable consequence rather than the action stream.
        await waitUntil { spy.nonTickCalls >= 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(spy.nonTickCalls == 1, "exactly ONE resume open — a second .beforeSync means a duplicated .retryStart")

        await drain(store)
    }

    /// (c) — the risky one. A tick's broadcast finds sync already idle at the tip: there is nothing
    /// for `stopSyncBeforeMigrationBroadcast` to stop, so neither `migrationStoppedSyncForBroadcast`
    /// nor `syncDeferredByMigrationGate` is set by the broadcast itself. The SDK's OWN post-broadcast
    /// gate still engages and clears on its own schedule regardless (a landed broadcast is a landed
    /// broadcast); this proves that edge still resumes sync once it does.
    @Test func resumeInvariantIdleAtTipTickArmsItsOwnResume() async throws {
        let spy = TickSpy(verdict: MigrationStepVerdict.broadcast(id: 1))
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock)

        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(30))
        await waitUntil { spy.tickCalls == 1 }

        // The shape a LANDED broadcast produces regardless of whether the app had anything of its
        // own to stop: the SDK's post-broadcast gate blocks, then clears.
        await store.send(.migrationSyncGateChanged(true)) { $0.lastMigrationSyncGateBlocked = true }
        await store.send(.migrationSyncGateChanged(false)) { state in
            state.lastMigrationSyncGateBlocked = false
            state.syncDeferredByMigrationGate = false
        }

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        // Parked-debt pin (2026-08-03), same rationale as (a) above: exactly one resume open.
        await waitUntil { spy.nonTickCalls >= 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(spy.nonTickCalls == 1, "exactly ONE resume open — a second .beforeSync means a duplicated .retryStart")

        await drain(store)
    }

    // MARK: - The zero switch (interval constant set to 0 disables the loop; opens unaffected)

    /// Zero interval: the loop must never spawn from the launch-done site — no tick advance no
    /// matter how far the clock runs.
    @Test func zeroIntervalNeverSpawnsTheLoopFromLaunchDone() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock, tickInterval: Swift.Duration.zero)

        await store.send(.initialization(.initializationSuccessfullyDone))

        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(spy.tickCalls == 0, "a zero interval must disable the loop entirely")

        await drain(store)
    }

    /// Zero interval: the foreground spawn site is equally dead.
    @Test func zeroIntervalNeverSpawnsTheLoopFromForeground() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock, tickInterval: Swift.Duration.zero)

        await store.send(.initialization(.appDelegate(.willEnterForeground)))

        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(spy.tickCalls == 0, "a zero interval must disable the foreground spawn site too")

        await drain(store)
    }

    /// THE requirement that must survive the switch: with the loop disabled, an app-open still
    /// pokes the driver — the foreground path runs its own `.beforeSync` advance exactly as before.
    @Test func zeroIntervalKeepsTheForegroundPokeWorking() async {
        let spy = TickSpy()
        let testClock = TestClock()
        let store = makeStore(spy: spy, testClock: testClock, tickInterval: Swift.Duration.zero)

        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await waitUntil { spy.phases.value.contains(MigrationOpenPhase.beforeSync) }

        #expect(
            spy.phases.value.contains(MigrationOpenPhase.beforeSync),
            "the open poke is a separate lane and must survive the zero switch"
        )
        #expect(spy.tickCalls == 0, "and still no tick, ever")

        await drain(store)
    }
}

// F-C9-4 REGRESSION PIN (campaign 9, 2026-08-05): the tick loop was fully wired and NEVER RAN in
// the field, because `Root.Constants.migrationTickInterval` shipped parked at `.zero` — the
// documented OFF switch — while every TestStore above overrides the dependency and stayed green.
// This is the one test that reads the SHIPPED constant: if the loop is ever parked again, this
// fails instead of a campaign discovering it.
@Suite struct MigrationTickIntervalLivePin {
    @Test
    func theShippedTickIntervalIsNotTheOffSwitch() {
        #expect(Root.Constants.migrationTickInterval > Swift.Duration.zero)
    }
}
