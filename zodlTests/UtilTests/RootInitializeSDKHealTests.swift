//
//  RootInitializeSDKHealTests.swift
//  zodlTests
//
//  TCA TestStore integration tests for the wallet-database heal WIRING inside
//  Root.initializationReduce()'s `.initialization(.initializeSDK)` case
//  (Features/Root/RootInitialization.swift) and the shared clears helper
//  (Root.clearDeviceScopedWalletState in Features/Root/RootStore.swift). The pure
//  reconciliation algorithm itself is covered by WalletDatabaseSeedReconcileTests;
//  this suite drives the REDUCER wiring around it through a real TestStore.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `Root.State` has no `Equatable` conformance in the app, and several of the nested
// feature/CoordFlow states it embeds (RestoreWalletCoordFlow.State, SendCoordFlow.State,
// TransactionsCoordFlow.State, …) aren't `Equatable` either — a synthesized conformance is not
// possible. `TestStore<State: Equatable, Action>` requires one regardless, so this test-scoped
// conformance compares only the handful of fields this suite's assertions actually touch
// (restore/heal flags and the presented alert's rendered content). It intentionally treats
// every other field as equal, so it must never be relied on outside this file, and it lives
// here — not in app sources — precisely so nothing in the shipping app could ever pick it up
// (e.g. an `@ObservableState`/SwiftUI diffing path silently short-circuiting on an untouched
// field).
extension Root.State: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isRestoringWallet == rhs.isRestoringWallet
            && lhs.walletStatus == rhs.walletStatus
            && lhs.appInitializationState == rhs.appInitializationState
            && lhs.alert?.title == rhs.alert?.title
            && lhs.alert?.message == rhs.alert?.message
            && lhs.isStaleWalletHealedAlertPending == rhs.isStaleWalletHealedAlertPending
    }
}

// Healing a stale wallet database calls through to `Root.clearDeviceScopedWalletState`, which
// (by design, see its doc comment in RootStore.swift) reaches past dependency injection into
// `UserDefaults.standard` and the app's Documents directory for a belt-and-suspenders cleanup.
// That is real, process-global state, so this suite is serialized per repo convention rather
// than relying solely on per-test dependency isolation.
@Suite(.serialized) @MainActor struct RootInitializeSDKHealTests {
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

    /// Builds a `Root` `TestStore` wired for the `.initializeSDK` heal path. Every dependency the
    /// effect can reach is either a recorded fake (via `calls` / `removedUserDefaultsKeys` /
    /// `setUserDefaultsBools`) or a benign no-op, so the whole effect — including the
    /// `.initializationSuccessfullyDone` fan-out (SmartBanner priority evaluation, contacts,
    /// user metadata, the battery-state subscription, …) — runs to completion without ever
    /// touching an unimplemented dependency closure. When `firstPrepareError` is non-nil, the
    /// first `prepareWith` call throws it instead of returning `firstPrepareResult`, for
    /// exercising the `ZcashError.initializerSeedMismatch` heal-mapping path. When `reprepareError`
    /// is non-nil, the second (re-prepare, `.restoreWallet`-mode) `prepareWith` call throws it
    /// instead of succeeding, for exercising the `WalletDatabaseHealError.reprepareFailed`
    /// recovery route.
    private func makeStore(
        calls: LockIsolated<[String]>,
        removedUserDefaultsKeys: LockIsolated<[String]>,
        setUserDefaultsBools: LockIsolated<[String: Bool]>,
        firstPrepareResult: Initializer.InitializationResult,
        isSeedRelevant: Bool,
        walletAccountsResult: [WalletAccount] = [RootInitializeSDKHealTests.seedDerivedAccount],
        firstPrepareError: Error? = nil,
        reprepareError: Error? = nil,
        isStaleWalletHealedAlertPending: Bool = false,
        destination: Root.DestinationState.Destination = .welcome
    ) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: destination),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        initialState.isStaleWalletHealedAlertPending = isStaleWalletHealedAlertPending

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { },
                reset: { }
            )

            $0.mnemonic = .noOp

            // Only reached by the F5 recovery route (the `reprepareFailed` catch re-enters
            // `.checkWalletInitialization`, which calls `Root.walletInitializationState`).
            // `DatabaseFilesClient` is `@DependencyClient`-generated, so leaving it
            // unoverridden would make `areDbFilesPresentFor` an "unimplemented" stub that
            // fails the test the moment that route is exercised.
            $0.databaseFiles = .noOp

            let seededWallet = RootInitializeSDKHealTests.seededWallet
            $0.walletStorage = .noOp
            $0.walletStorage.exportWallet = { _ in seededWallet }

            $0.flexaHandler = .noOp
            $0.flexaHandler.signOut = { calls.withValue { $0.append("flexaSignOut") } }

            $0.userStoredPreferences.removeAll = { calls.withValue { $0.append("userPrefsRemoveAll") } }

            $0.readTransactionsStorage = .noOp

            $0.userDefaults.objectForKey = { key in setUserDefaultsBools.value[key] }
            $0.userDefaults.remove = { key in removedUserDefaultsKeys.withValue { $0.append(key) } }
            $0.userDefaults.setValue = { value, key in
                guard let boolValue = value as? Bool else { return }
                setUserDefaultsBools.withValue { $0[key] = boolValue }
            }

            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }

            $0.userMetadataProvider.load = { _ in }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                prepareWith: { _, _, _, _ in
                    // The SDK no longer takes a `WalletInitMode` (it derives the init flow itself), so
                    // this mock discriminates on call ORDER instead of the mode it used to be handed:
                    // the first `prepareWith` is the initial prepare, any later one is the post-wipe
                    // re-prepare the heal path performs.
                    let isReprepare: Bool = calls.withValue { recorded in
                        let priorPrepares = recorded.filter { $0.hasPrefix("prepareWith(") }.count
                        recorded.append("prepareWith(\(priorPrepares == 0 ? "initial" : "reprepare"))")
                        return priorPrepares > 0
                    }
                    if isReprepare {
                        if let reprepareError {
                            throw reprepareError
                        }
                        return .success
                    }
                    if let firstPrepareError {
                        throw firstPrepareError
                    }
                    return firstPrepareResult
                },
                getAllTransactions: { _ in [] },
                wipe: {
                    calls.withValue { $0.append("wipe") }
                    return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                },
                isSeedRelevantToAnyDerivedAccount: { _ in
                    calls.withValue { $0.append("isSeedRelevant") }
                    return isSeedRelevant
                },
                walletAccounts: {
                    calls.withValue { $0.append("walletAccounts") }
                    return walletAccountsResult
                }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Lets the rest of the `.initializeSDK` cascade (SmartBanner evaluation, contacts, user
    /// metadata, the battery-state subscription spun up by `.initializationSuccessfullyDone`, …)
    /// settle without asserting on any of it. `.cancelAllRunningEffects` is a best-effort
    /// cancellation — the battery subscription is spun up by `.initializationSuccessfullyDone`,
    /// which the still-running `.initializeSDK` effect may not have reached yet, so it can race
    /// this call and outlive it — so the `skip` calls unconditionally silence the test store's
    /// own bookkeeping afterward rather than waiting on `finish()`, which would otherwise just
    /// burn its full timeout on that never-completing subscription every time.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// Builds a `Root` `TestStore` for exercising the deferred-presentation wiring
    /// (`.destination(.updateDestination)` / `.initialization(.presentStaleWalletHealedAlert)`)
    /// in isolation, without the full heal-flow dependency wiring `makeStore` provides. That
    /// wiring is irrelevant here — only `mainQueue` is touched by the code path under test — so
    /// `isStaleWalletHealedAlertPending` is seeded directly on the initial state instead of
    /// driving a real heal through `.initializeSDK`.
    private func makeDestinationStore(
        isStaleWalletHealedAlertPending: Bool,
        mainQueue: AnySchedulerOf<DispatchQueue> = .immediate
    ) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State(
            destinationState: Root.DestinationState(),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        initialState.isStaleWalletHealedAlertPending = isStaleWalletHealedAlertPending

        let store = TestStore(initialState: initialState) {
            Root()
        } withDependencies: {
            $0.mainQueue = mainQueue
        }
        store.exhaustivity = .off
        return store
    }

    // MARK: - Scenario 1: probe-false heal

    @Test func probeFalseHealWipesAndRepreparesInOrderThenSignalsRestore() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: false
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.isStaleWalletHealedAlertPending = true
        }

        #expect(store.state.alert == nil, "the heal notice must stay pending, not appear immediately")

        let recordedCalls = calls.value
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        let reprepareIndex = try #require(recordedCalls.firstIndex(of: "prepareWith(reprepare)"))
        #expect(wipeIndex < reprepareIndex, "the stale database must be wiped before it is re-prepared")

        #expect(setBools.value[Root.Constants.udIsRestoringWallet] == true)
        #expect(store.state.isRestoringWallet)
        #expect(store.state.walletStatus == .restoring)

        // This test drives `.initializeSDK` directly, bypassing
        // `.respondToWalletInitializationState`'s concatenation with `.checkBackupPhraseValidation`,
        // so the home destination update that normally follows a successful initialization is
        // never naturally sent here. Drive it explicitly to exercise the deferred-presentation wiring.
        await store.send(.destination(.updateDestination(.home)))

        await store.receive(
            { action in
                guard case .initialization(.presentStaleWalletHealedAlert) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isStaleWalletHealedAlertPending = false
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        await drain(store)
    }

    // MARK: - Scenario 2: .seedNotRelevant heal guards F1

    @Test func seedNotRelevantHealsWithoutProbingRelevanceOrDerivation() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .seedNotRelevant,
            // If the F1 guard regresses and this gets consulted despite the database already
            // being known stale, answering "yes, relevant" makes reconcile bail out with no
            // heal — so a regression fails this test instead of coincidentally passing it.
            isSeedRelevant: true
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.isStaleWalletHealedAlertPending = true
        }

        let recordedCalls = calls.value
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        #expect(
            !recordedCalls[..<wipeIndex].contains("isSeedRelevant"),
            "a database already known stale (.seedNotRelevant) must not be probed for relevance"
        )
        #expect(
            !recordedCalls[..<wipeIndex].contains("walletAccounts"),
            "a database already known stale (.seedNotRelevant) must not be probed for a derived account"
        )

        await drain(store)
    }

    // MARK: - Scenario 2b: prepare() throwing initializerSeedMismatch heals like .seedNotRelevant

    /// SDK 2.6.0 moved the seed/account integrity check inside `Initializer.initialize`, so a
    /// stale database can now surface as a **thrown** `ZcashError.initializerSeedMismatch` from
    /// the first `prepareWith` call instead of (only) a returned `.seedNotRelevant`.
    /// `RootInitialization` must map that throw onto the same `knownStale: true` heal — this is
    /// the throw-based mirror of `seedNotRelevantHealsWithoutProbingRelevanceOrDerivation` above.
    @Test func prepareThrowingSeedMismatchHealsWithoutProbingRelevanceOrDerivation() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            // If the F1 guard regresses and this gets consulted despite the database already
            // being known stale, answering "yes, relevant" makes reconcile bail out with no
            // heal — so a regression fails this test instead of coincidentally passing it.
            isSeedRelevant: true,
            firstPrepareError: ZcashError.initializerSeedMismatch
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.isStaleWalletHealedAlertPending = true
        }

        let recordedCalls = calls.value
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        #expect(
            !recordedCalls[..<wipeIndex].contains("isSeedRelevant"),
            "a mismatch thrown by prepare() is already known stale and must not be probed for relevance"
        )
        #expect(
            !recordedCalls[..<wipeIndex].contains("walletAccounts"),
            "a mismatch thrown by prepare() is already known stale and must not be probed for a derived account"
        )

        // `.initialization(.initializationFailed)` is the only other place the reducer sets
        // these — their absence confirms the thrown mismatch healed instead of dead-ending the
        // user on that alert.
        #expect(store.state.alert == nil, "the mismatch must heal in place, not surface initializationFailed")
        #expect(store.state.appInitializationState != .failed, "the mismatch must heal in place, not surface initializationFailed")

        await drain(store)
    }

    // MARK: - Scenario 3: no-op when the seed is already relevant

    @Test func relevantSeedSkipsHealAndLeavesNoAlert() async {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: true
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.initializationSuccessfullyDone) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(!calls.value.contains("wipe"), "no heal must occur when the seed is already relevant")
        #expect(store.state.alert == nil, "no heal alert should be shown")
        #expect(!store.state.isRestoringWallet)

        await drain(store)
    }

    // MARK: - Scenario 4: device-scoped state is cleared before the wipe (F2)

    @Test func clearsDeviceScopedStateBeforeWipingOnHeal() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: false
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.isStaleWalletHealedAlertPending = true
        }

        let recordedCalls = calls.value
        let signOutIndex = try #require(recordedCalls.firstIndex(of: "flexaSignOut"))
        let userPrefsIndex = try #require(recordedCalls.firstIndex(of: "userPrefsRemoveAll"))
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        #expect(signOutIndex < wipeIndex, "the Flexa session must be cleared before the database is wiped")
        #expect(userPrefsIndex < wipeIndex, "cached preferences must be cleared before the database is wiped")

        #if VOTING_ENABLED
        #expect(
            removedKeys.value.contains(.votingConfigOverrideURL),
            "the voting chain override must be cleared before healing a stale database"
        )
        #endif

        await drain(store)
    }

    // MARK: - Scenario 5: re-prepare failure after a successful wipe (F5)

    /// The heal's `wipe()` can succeed while the follow-up `reprepare()` throws — the stale
    /// database is already gone at that point, so a hard `initializationFailed` alert (which
    /// only ever recovers via app relaunch) would leave the user at a dead end. `initializeSDK`
    /// catches `Root.WalletDatabaseHealError.reprepareFailed` specifically and re-enters
    /// `.checkWalletInitialization` instead — an in-session recovery route. `databaseFiles` and
    /// `walletStorage.areKeysPresent` (via the `.noOp` clients set up in `makeStore`) both
    /// report nothing present, so the recomputed state resolves to `.uninitialized` (terminal:
    /// onboarding) rather than `.filesMissing`, which would re-enter `.initializeSDK` and hit
    /// the same throwing stub again.
    @Test func reprepareFailureAfterWipeRoutesToCheckWalletInitialization() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: false,
            reprepareError: ReprepareStubError()
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.checkWalletInitialization) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        let recordedCalls = calls.value
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        let reprepareIndex = try #require(recordedCalls.firstIndex(of: "prepareWith(reprepare)"))
        #expect(wipeIndex < reprepareIndex, "the database must be wiped before the failing re-prepare is attempted")

        // `.staleWalletDatabaseHealed` and the catch's `.checkWalletInitialization` are
        // mutually exclusive outcomes of the same `do`/`catch` in `initializeSDK` — only the
        // former ever sets these fields, so their absence here confirms it was never sent.
        #expect(!store.state.isRestoringWallet, "a failed re-prepare must not signal a heal")
        #expect(store.state.alert == nil, "no heal alert should be shown when re-prepare fails")

        await drain(store)
    }

    // MARK: - Deferred presentation: alert appears once home settles, consumed exactly once

    @Test func pendingHealAlertPresentsOnceHomeDestinationSettlesAndIsConsumedOnlyOnce() async {
        let store = makeDestinationStore(isStaleWalletHealedAlertPending: true)

        await store.send(.destination(.updateDestination(.home)))

        await store.receive(
            { action in
                guard case .initialization(.presentStaleWalletHealedAlert) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isStaleWalletHealedAlertPending = false
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        #expect(store.state.alert?.title == AlertState.staleWalletDatabaseHealed().title)
        #expect(store.state.alert?.message == AlertState.staleWalletDatabaseHealed().message)
        #expect(!store.state.isStaleWalletHealedAlertPending)

        // A later home entry (e.g. a subsequent settle, background/foreground cycle) must not
        // re-present the notice: the flag was already consumed above.
        await store.send(.destination(.updateDestination(.home)))

        #expect(store.state.alert?.title == AlertState.staleWalletDatabaseHealed().title)
        #expect(store.state.alert?.message == AlertState.staleWalletDatabaseHealed().message)
        #expect(!store.state.isStaleWalletHealedAlertPending)

        await drain(store)
    }

    // MARK: - No pending heal: home destination update never presents an alert

    @Test func noPendingHealLeavesNoAlertOnHomeDestinationUpdate() async {
        let store = makeDestinationStore(isStaleWalletHealedAlertPending: false)

        await store.send(.destination(.updateDestination(.home)))

        #expect(store.state.alert == nil, "no heal alert should appear when nothing is pending")
        #expect(!store.state.isStaleWalletHealedAlertPending)

        await drain(store)
    }

    // MARK: - Destination leaves home before the deferred present lands

    @Test func destinationLeavingHomeBeforeDeferredPresentLandsSkipsThatDeliveryButKeepsPending() async {
        // A controllable scheduler is required here — the `.immediate` scheduler used elsewhere
        // in this suite resolves the 0.5s wait essentially instantly (as soon as the effect's
        // Task gets any turn at all), which can easily land before the next line of the test
        // even runs. That makes it impossible to reliably interleave "leave home" in between
        // scheduling the effect and its delivery. `DispatchQueue.test` holds the deferred send
        // until explicitly advanced, so the race is deterministic instead.
        let testQueue = DispatchQueue.test
        let store = makeDestinationStore(isStaleWalletHealedAlertPending: true, mainQueue: testQueue.eraseToAnyScheduler())

        await store.send(.destination(.updateDestination(.home)))

        // Leave home before the 0.5s deferred effect lands (e.g. a deep link navigates away).
        await store.send(.destination(.updateDestination(.onboarding)))

        await testQueue.advance(by: .seconds(0.5))

        // The effect scheduled while on home still lands (leaving home doesn't itself cancel
        // it — only a fresh entry onto `.home` reschedules on the shared cancel ID), but
        // `.presentStaleWalletHealedAlert` re-checks the destination at delivery time and,
        // finding it's no longer `.home`, bails out without presenting the alert or clearing
        // the pending flag.
        await store.receive(
            { action in
                guard case .initialization(.presentStaleWalletHealedAlert) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )
        #expect(store.state.alert == nil, "must not present over a screen other than home")
        #expect(store.state.isStaleWalletHealedAlertPending, "the flag must survive a delivery that lands off-home")

        // Returning to home re-arms the hook, and the notice is still delivered.
        await store.send(.destination(.updateDestination(.home)))
        await testQueue.advance(by: .seconds(0.5))

        await store.receive(
            { action in
                guard case .initialization(.presentStaleWalletHealedAlert) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isStaleWalletHealedAlertPending = false
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        #expect(store.state.alert?.title == AlertState.staleWalletDatabaseHealed().title)
        #expect(store.state.alert?.message == AlertState.staleWalletDatabaseHealed().message)
        #expect(!store.state.isStaleWalletHealedAlertPending)

        await drain(store)
    }

    // MARK: - Second destination-assignment site: phraseDisplay/newWallet also honors the pending flag

    @Test func pendingHealAlertPresentsAfterNewWalletSuccessfullyCreatedTransitionsToHome() async {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        // `.onboarding(.newWalletSuccessfulyCreated)` is also handled by a second, independent
        // reducer arm (`combinedCore` in RootStore.swift) that kicks off a full
        // `.initializeSDK(.newWallet)` cascade. `isSeedRelevant: true` keeps that cascade on the
        // no-heal path (same config as Scenario 3), so it resolves via `.initializationSuccessfullyDone`
        // without ever touching `destinationState` — avoiding a confound with the destination
        // assertions this test cares about.
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: true,
            isStaleWalletHealedAlertPending: true
        )

        await store.send(.onboarding(.newWalletSuccessfulyCreated))

        await store.receive(
            { action in
                guard case .initialization(.presentStaleWalletHealedAlert) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isStaleWalletHealedAlertPending = false
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        #expect(store.state.alert?.title == AlertState.staleWalletDatabaseHealed().title)
        #expect(store.state.alert?.message == AlertState.staleWalletDatabaseHealed().message)
        #expect(!store.state.isStaleWalletHealedAlertPending)
        #expect(store.state.destinationState.destination == .home)

        await drain(store)
    }

    // MARK: - Heal signal arrives after the destination has already settled on home

    /// Covers the third transition point: unlike the other two tests, the destination is
    /// `.home` *before* `.staleWalletDatabaseHealed` is even sent — e.g. the new-wallet cascade
    /// already transitioned home (via the synchronous `.phraseDisplay(.finishedTapped)` /
    /// `.onboarding(.newWalletSuccessfulyCreated)` arm) while the flag was still false, and
    /// nothing on that path ever re-sends a home transition afterward. With no hook left to
    /// fire, a flag that only gets set post-hoc would sit pending for the rest of the session.
    @Test func staleWalletDatabaseHealedPresentsImmediatelyWhenDestinationIsAlreadyHome() async {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: true,
            destination: .home
        )

        await store.send(.initialization(.staleWalletDatabaseHealed)) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.isStaleWalletHealedAlertPending = true
        }

        await store.receive(
            { action in
                guard case .initialization(.presentStaleWalletHealedAlert) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isStaleWalletHealedAlertPending = false
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        #expect(store.state.alert?.title == AlertState.staleWalletDatabaseHealed().title)
        #expect(store.state.alert?.message == AlertState.staleWalletDatabaseHealed().message)
        #expect(!store.state.isStaleWalletHealedAlertPending)

        await drain(store)
    }
}

private struct ReprepareStubError: Error { }
