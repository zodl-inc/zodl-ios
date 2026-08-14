//
//  RootMigrationGateRefusalTests.swift
//  zodlTests
//
//  MOB-1466 (B2, P0): TCA TestStore coverage for the sync gate's start() refusal handling in
//  Root.initializationReduce()'s `.initialization(.initializeSDK)` and `.initialization(.retryStart)`
//  cases (Features/Root/RootInitialization.swift).
//
//  THE BUG this pins: after a successful migration broadcast, the SDK's `start()` correctly throws
//  `ZcashError.migrationSyncBlocked` — the migration privacy gate says "this launch is a broadcast
//  session, don't sync". Before this fix, both call sites let that throw fall into their generic
//  catch (`.initializationFailed` on cold launch — a fatal alert with NO retry action — and
//  `.synchronizerStartFailed` on foreground retry, a dead end), bricking the wallet. The fix treats
//  the refusal as the send-visit signal it actually is: run the broadcast session and continue
//  exactly as a `.send`-visit would, so the existing resume machinery
//  (`.registerForSynchronizersUpdate`'s gate-stream subscription + `.migrationSyncGateChanged(false)`
//  -> `.retryStart`) picks the wallet back up once the gate reopens.
//
//  `extension Root.State: @retroactive Equatable` already exists, module-wide, at
//  RootInitializeSDKHealTests.swift. This file uses `TestStore` directly against that existing
//  conformance rather than redeclaring it — see that file's header, and
//  RootIronwoodAnnouncementGateTests.swift's header for why a second declaration would be a
//  duplicate-conformance compile error.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized per repo convention for suites driving `.initializeSDK`/`.retryStart` through a real
// TestStore — see RootInitializeSDKHealTests's identical `@Suite(.serialized)` rationale.
@Suite(.serialized) @MainActor struct RootMigrationGateRefusalTests {
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

    private static let seededWallet = StoredWallet.placeholder

    private struct OtherStartError: Error, Equatable { }

    /// Builds a `Root` `TestStore` wired for both `.initializeSDK` (cold launch) and `.retryStart`
    /// (foreground). `startError`, when non-nil, is thrown by every `sdkSynchronizer.start` call —
    /// `ZcashError.migrationSyncBlocked` exercises the gate-refusal path this suite is about;
    /// `OtherStartError` exercises the regression pin (every OTHER error must keep flowing to the
    /// existing failure handling, unchanged). `visitKind` defaults to `.sync` so the reducer takes
    /// the `sdkSynchronizer.start` branch rather than the already-covered `.send`-visit branch —
    /// the gate refusing `start()` while `visitKind()` still reads `.sync` is exactly the lagging-
    /// classifier scenario B2 fixes (see the file header). `runBroadcastSession` calls are recorded
    /// into `calls` so a test can assert the refusal was actually treated as a broadcast session.
    private func makeStore(
        calls: LockIsolated<[String]>,
        startError: Error?,
        visitKind: MigrationVisit = .sync,
        lastMigrationSyncGateBlocked: Bool = false,
        syncDeferredByMigrationGate: Bool = false,
        // (#12): the not-prepared-guard test drives `.retryStart`'s `isPrepared` guard, which
        // reads this mocked status; `SDKSynchronizerClient`'s members are `let`, so the variation
        // has to enter here rather than by post-construction override.
        latestSyncStatus: SyncStatus = .upToDate
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
        initialState.syncDeferredByMigrationGate = syncDeferredByMigrationGate

        // Resolved here, in the suite's `@MainActor` context, rather than inside the `@Sendable`
        // dependency closures below — `seedDerivedAccount` is `@MainActor`-isolated (a static
        // member of this `@MainActor` suite), and a `@Sendable` closure literal cannot reach across
        // that isolation boundary to read it directly.
        let seedDerivedAccount = RootMigrationGateRefusalTests.seedDerivedAccount

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            // (#7) `.synchronizerStartFailed` now schedules a delayed retry on this clock; an
            // unstubbed (unimplemented) test clock records an issue the moment that effect runs.
            // A quiet, never-advanced TestClock parks the retry instead — tests that want it to
            // fire advance their own clock.
            $0.continuousClock = TestClock()

            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { },
                reset: { }
            )

            $0.mnemonic = .noOp

            $0.databaseFiles = .noOp

            let seededWallet = RootMigrationGateRefusalTests.seededWallet
            $0.walletStorage = .noOp
            $0.walletStorage.exportWallet = { _ in seededWallet }

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

            $0.migrationManager.visitKind = { visitKind }
            // MOB-1466 (2026-08-02): the refusal handlers discharge the engine's step through the
            // DRIVER now, not by calling `runBroadcastSession` directly — the broadcast is what the
            // driver does when the engine's answer is `.broadcast`. Recording the driver keeps every
            // claim below intact and adds the phase, which is the ZIP 318 property.
            //
            // Counts matter here, not just presence: the sync branch calls the driver ONCE before
            // `start()` on every open, so "the refusal ran a broadcast session" is now "the driver
            // ran a SECOND time, from the catch" — see `advanceCalls` at each assertion.
            $0.migrationManager.advance = { phase in
                calls.withValue { $0.append("advance:\(phase)") }
                return .broadcast(id: 1)
            }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: {
                    var syncState = SynchronizerState.zero
                    syncState.syncStatus = latestSyncStatus
                    return syncState
                },
                prepareWith: { _, _, _, _ in .success },
                start: { _ in
                    if let startError {
                        throw startError
                    }
                },
                getAllTransactions: { _ in [] },
                isSeedRelevantToAnyDerivedAccount: { _ in true },
                walletAccounts: { [seedDerivedAccount] }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Lets the rest of the cascade past the assertion point (SmartBanner evaluation, contacts,
    /// user metadata, the battery-state subscription, the migration gate stream, …) settle without
    /// asserting on any of it — identical rationale to RootInitializeSDKHealTests's `drain`.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// How many times the driver ran at `.beforeSync`. The sync branch calls it once before
    /// `start()` on EVERY open, so a gate refusal — which discharges the engine's step from the
    /// catch — shows up as at least a second call (the gate's own reopen->retryStart resume can
    /// legitimately drive several more), while a non-gate error shows EXACTLY the first.
    private func advanceCalls(_ calls: LockIsolated<[String]>) -> Int {
        calls.value.filter { $0 == "advance:beforeSync" }.count
    }

    // MARK: - Cold launch: gate refusal is treated as the broadcast-session signal, not a fatal error

    @Test func coldLaunchGateRefusalRunsBroadcastSessionInsteadOfFailingInit() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: ZcashError.migrationSyncBlocked, visitKind: .sync)

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        // Mutually exclusive with `.initializationFailed` — both are the ONLY two outcomes of the
        // same do/catch, so successfully receiving this one also proves the other was never sent.
        await store.receive(
            { action in
                guard case .initialization(.initializationSuccessfullyDone) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(
            advanceCalls(calls) >= 2,
            "the refusal must discharge the engine step, on top of the unconditional pre-start driver call"
        )
        #expect(store.state.alert == nil, "a gate refusal must not surface the fatal init alert")
        #expect(store.state.appInitializationState != .failed, "a gate refusal must not mark initialization failed")

        await drain(store)
    }

    // MARK: - Cold launch: a DIFFERENT error still fails init (regression pin)

    @Test func coldLaunchOtherStartErrorStillFailsInitialization() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: OtherStartError(), visitKind: .sync)

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.initializationFailed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(advanceCalls(calls) == 1, "a non-gate error must not be treated as a broadcast session — only the pre-start call")
        #expect(store.state.appInitializationState == .failed)
        #expect(store.state.alert != nil)

        await drain(store)
    }

    // MARK: - Resume: the gate reopening (`.migrationSyncGateChanged(false)`) triggers `.retryStart`
    //
    // This is what makes the refusal path above actually recover the wallet instead of just quietly
    // broadcasting once: `syncDeferredByMigrationGate`/`lastMigrationSyncGateBlocked` are the flags
    // a blocked start leaves behind (see their doc comments in RootStore.swift), and this is the
    // transition that reads them once the gate clears. No existing test in the suite drives
    // `.migrationSyncGateChanged` at all (verified via `grep -rl migrationSyncGateChanged
    // zodlTests/`), so this is not a duplicate of existing coverage.
    @Test func migrationSyncGateChangedToUnblockedTriggersRetryStart() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(
            calls: calls,
            startError: nil,
            visitKind: .sync,
            lastMigrationSyncGateBlocked: true,
            syncDeferredByMigrationGate: true
        )

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

        // Audit 2026-08-03 (#12): the arming flag is consumed by `.retryStart` PAST its guards,
        // no longer by the gate-resume reducer — clearing before the guards meant a disk-space or
        // not-prepared early return swallowed the resume with the flags already gone.
        #expect(!store.state.syncDeferredByMigrationGate, "retryStart consumed the arming flag once past its guards")

        await drain(store)
    }

    /// Audit 2026-08-03 (#12): the swallowed-resume shape, pinned. A gate-clear that lands while
    /// the SDK is momentarily NOT prepared reaches `.retryStart`'s guard and returns — and the
    /// arming flags must SURVIVE that, so the gate's next emission can retry the whole resume.
    @Test func notPreparedGuardLeavesTheResumeFlagsArmed() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(
            calls: calls,
            startError: nil,
            visitKind: .sync,
            lastMigrationSyncGateBlocked: true,
            syncDeferredByMigrationGate: true,
            latestSyncStatus: .unprepared
        )

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

        #expect(
            store.state.syncDeferredByMigrationGate,
            "a not-prepared early return must leave the resume flag armed for the next emission"
        )

        await drain(store)
    }

    /// Audit 2026-08-03 (#7): a NON-gate start failure must not strand the foreground — the catch
    /// re-arms the subscriptions (state stream + gate feed keep flowing) and schedules exactly one
    /// delayed retry per foreground.
    @Test func startFailureStillRegistersSubscriptionsAndArmsOneRetry() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: OtherStartError(), visitKind: .sync)

        await store.send(.initialization(.retryStart))

        await store.receive(
            { action in
                guard case .initialization(.registerForSynchronizersUpdate) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        await store.receive(
            { action in
                guard case .initialization(.synchronizerStartFailed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(store.state.didScheduleStartFailureRetry, "the failure must arm its one-shot delayed retry")

        await drain(store)
    }

    // MARK: - Buffer-shape refusal: the refusal itself must arm the resume
    //
    // A relaunch inside the post-broadcast privacy buffer is refused by the gate while NOTHING is
    // due to broadcast: `runBroadcastSession()` finds no `.broadcast` step, so it never stops sync
    // and never sets `migrationStoppedSyncForBroadcast`. If the refusal path did not arm
    // `syncDeferredByMigrationGate` itself, the gate's clearing edge would compute
    // `shouldResume == false` and sync would stay off for the whole session (rescued only by the
    // next foreground). The flag's own doc in RootStore.swift always promised this arming; nothing
    // in production ever set it before this fix.
    @Test func bufferShapeRefusalArmsTheResumeItself() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: ZcashError.migrationSyncBlocked, visitKind: .sync)

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.initializationSuccessfullyDone) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(store.state.syncDeferredByMigrationGate, "the refusal itself must arm the deferred-start flag")

        // Quiesce the post-init cascade so the resume below is driven by THIS test, not by the
        // register-time seed read racing it.
        await drain(store)

        await store.send(.migrationSyncGateChanged(false))

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        // (#12) Cleared by `.retryStart` past its guards, not by the gate-resume reducer.
        #expect(!store.state.syncDeferredByMigrationGate, "retryStart consumed the flag the refusal armed")

        await drain(store)
    }

    // MARK: - .retryStart: gate refusal also runs the broadcast session instead of failing the retry

    @Test func retryStartGateRefusalRunsBroadcastSessionInsteadOfFailingStart() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: ZcashError.migrationSyncBlocked, visitKind: .sync)

        await store.send(.initialization(.retryStart))

        // Mutually exclusive with `.synchronizerStartFailed` — both are the ONLY two outcomes of
        // the same do/catch, so successfully receiving this one also proves the other was never
        // sent.
        await store.receive(
            { action in
                guard case .initialization(.registerForSynchronizersUpdate) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(
            advanceCalls(calls) >= 2,
            "the refusal must discharge the engine step, on top of the unconditional pre-start driver call"
        )

        await drain(store)
    }

    // MARK: - .retryStart: a DIFFERENT error still routes to synchronizerStartFailed (regression pin)

    @Test func retryStartOtherErrorStillRoutesToSynchronizerStartFailed() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: OtherStartError(), visitKind: .sync)

        await store.send(.initialization(.retryStart))

        await store.receive(
            { action in
                guard case .initialization(.synchronizerStartFailed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(advanceCalls(calls) == 1, "a non-gate error must not be treated as a broadcast session — only the pre-start call")

        await drain(store)
    }

    // MARK: - The spin cut: a broadcast-only pass must not re-register the synchronizer streams

    /// MOB-1466 (Lukas, 2026-08-07). A device log caught 1,297 iterations of one cycle at ~10.7/s,
    /// still running when the log was captured, and STILL running after the app backgrounded — 816
    /// of them with no live trace session, each re-arming a local notification.
    ///
    /// The cycle closes entirely inside `.retryStart`'s broadcast branch:
    ///   `visitKind() == .send` → skip sync → `.migrationGateDeferredSyncStart` re-arms
    ///   `syncDeferredByMigrationGate` → `.registerForSynchronizersUpdate` re-subscribes →
    ///   `migrationSyncGateFeed()`'s self-healing SEED (audit 2026-08-03 #9) emits the current gate
    ///   value → `.migrationSyncGateChanged(false)` finds `isGenuineChange == false` but
    ///   `shouldResume == true` → `.retryStart`. No state changes anywhere on the way round.
    ///
    /// It only sustains while `visitKind()` keeps answering `.send`, which is why it hid for four
    /// days: a broadcast that SUCCEEDS stops answering `.send` after a turn or two. It took a
    /// broadcast that could never succeed in-session (`migrationBroadcastDuringSync`, then the R0
    /// once-credit refusing any retry) to turn two turns into forever.
    ///
    /// This pins the cut: a pass that never touched the synchronizer has nothing to re-register.
    /// Asserted as ORDER — the register is sent immediately before `.refreshAutomaticServer` in
    /// that same block, so if it were still there the predicate would meet it first.
    @Test func broadcastOnlyPassDoesNotReRegisterSynchronizerStreams() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: nil, visitKind: .send)

        await store.send(.initialization(.retryStart))

        await store.receive(
            { action in
                if case .initialization(.registerForSynchronizersUpdate) = action {
                    Issue.record("a broadcast-only pass re-registered the streams — the ~10 Hz spin is back")
                    return true
                }
                guard case .refreshAutomaticServer = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        await drain(store)
    }

    /// The complement, so the cut can never widen into "sync passes stop re-registering either":
    /// a pass that DID start the synchronizer still re-registers, which is what keeps the state
    /// stream and both gate feeds alive after a start.
    @Test func syncPassStillReRegistersSynchronizerStreams() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: nil, visitKind: .sync)

        await store.send(.initialization(.retryStart))

        await store.receive(
            { action in
                guard case .initialization(.registerForSynchronizersUpdate) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        await drain(store)
    }
}
