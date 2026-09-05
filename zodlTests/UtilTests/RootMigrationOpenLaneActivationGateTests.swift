//
//  RootMigrationOpenLaneActivationGateTests.swift
//  zodlTests
//
//  MOB-1861: the OPEN LANES' activation gate, and the predicate that must NOT be used to build it.
//
//  Root's two open lanes — `.initialization(.initializeSDK)` (cold launch) and
//  `.initialization(.retryStart)` (foreground / gate resume) — each ask `migrationManager
//  .visitKind()` whether this session may sync and then drive `migrationManager.advance(.beforeSync)`.
//  On a wallet where Ironwood has not activated, neither call can produce anything: `visitKind()`
//  returns `.sync` from its own first-statement activation guard
//  (`MigrationManagerLiveKey.visitKind()`) and `advance(phase:)` returns `.notApplicable` from its
//  own (`MigrationStepDriver.advance(phase:)`). This suite pins that Root now declines to make the
//  round trip at all, and — much more importantly — that it declines for the RIGHT reason.
//
//  THE PREDICATE THIS SUITE FORBIDS. The tick loop spawns on "Ironwood activated AND some candidate
//  account has a device-local `migrationMode`" (`migrationTickLoopEffect`). It is tempting to reuse
//  that same committed-run predicate here and skip the engine reads for an activated wallet that has
//  never committed a run. It is not sound, because the implication it would need runs the wrong way:
//
//    * The mode has exactly one writer in the whole app — the entry fork, when the user picks a
//      mode — and nothing ever re-writes it. It is not re-derived from the engine, ever.
//    * Its storage self-heals by DELETING an undecodable blob and reading `nil` thereafter, so a
//      single corrupt (or schema-incompatible) payload makes the mode `nil` permanently while the
//      engine's run carries on existing.
//    * The writer itself is documented to write nowhere when no account resolves.
//
//  So "no stored mode" does not mean "no committed run". And the cost of being wrong is not a slow
//  app-open: `advance(.beforeSync)` is the ONLY delivery lane such a run has left, because the tick
//  lane's mode belt holds every transfer whose mode is not `.privateScheduled` — `nil` included. A
//  run with a lost mode would broadcast nothing, re-arm no notification and never reach `.complete`,
//  for as long as the wallet exists. The two `migrationModeCalls == 0` assertions below are what
//  keep that predicate out of these two call sites.
//
//  `extension Root.State: @retroactive Equatable` already exists module-wide at
//  RootInitializeSDKHealTests.swift; this suite uses it rather than redeclaring it — see
//  RootMigrationGateRefusalTests's header for why a second declaration would not compile.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized per repo convention for suites driving `.initializeSDK`/`.retryStart` through a real
// TestStore — same rationale as RootMigrationGateRefusalTests.
@Suite(.serialized) @MainActor struct RootMigrationOpenLaneActivationGateTests {
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

    /// Records every migration call an open lane makes. `migrationMode` is stubbed — rather than
    /// left to trap — precisely so a reintroduced committed-run gate shows up as a COUNT rather than
    /// as a crash somewhere down the cascade.
    private final class OpenLaneSpy: @unchecked Sendable {
        let calls = LockIsolated<[String]>([])

        private let activated: Bool
        private let mode: MigrationMode?

        init(isIronwoodActivated: Bool, migrationMode: MigrationMode?) {
            self.activated = isIronwoodActivated
            self.mode = migrationMode
        }

        var visitKindCalls: Int { calls.value.filter { $0 == "visitKind" }.count }
        var beforeSyncAdvanceCalls: Int { calls.value.filter { $0 == "advance:beforeSync" }.count }
        var migrationModeCalls: Int { calls.value.filter { $0 == "migrationMode" }.count }

        func install(_ values: inout DependencyValues) {
            var client = MigrationManagerClient.noOp
            let activated = self.activated
            let mode = self.mode
            let calls = self.calls

            client.isIronwoodActivated = { activated }
            client.visitKind = {
                calls.withValue { $0.append("visitKind") }
                return MigrationVisit.sync
            }
            client.advance = { phase in
                calls.withValue { $0.append("advance:\(phase)") }
                return MigrationStepVerdict.idle
            }
            client.migrationMode = { _ in
                calls.withValue { $0.append("migrationMode") }
                return mode
            }
            values.migrationManager = client
        }
    }

    /// Mirrors `RootMigrationGateRefusalTests.makeStore`, minus the start-error variations this
    /// suite has no use for: `sdkSynchronizer.start` always succeeds, so both lanes take their
    /// ordinary sync branch and the only variable is whether Ironwood is activated.
    private func makeStore(spy: OpenLaneSpy) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        initialState.$selectedWalletAccount.withLock { $0 = RootMigrationOpenLaneActivationGateTests.seedDerivedAccount }
        initialState.$walletAccounts.withLock { $0 = [RootMigrationOpenLaneActivationGateTests.seedDerivedAccount] }

        // Resolved in the suite's `@MainActor` context — `seedDerivedAccount` is `@MainActor`
        // isolated and a `@Sendable` dependency closure cannot reach across that boundary.
        let seedDerivedAccount = RootMigrationOpenLaneActivationGateTests.seedDerivedAccount

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.continuousClock = TestClock()
            // The tick lane OFF, deliberately: it is the one other reader of `migrationMode` this
            // cascade can reach (`migrationTickLoopEffect`, and the stop half of
            // `.migrationSyncGateChanged`), and both short-circuit on this interval before the mode
            // is touched. With it at `.zero`, every `migrationMode` call the spy records can only
            // have come from an open lane — which is what makes the `== 0` assertions below mean
            // what they say.
            $0.migrationTickInterval = Swift.Duration.zero

            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )

            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp

            let seededWallet = RootMigrationOpenLaneActivationGateTests.seededWallet
            $0.walletStorage = .noOp
            $0.walletStorage.exportWallet = { seededWallet }

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

            spy.install(&$0)

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: {
                    var syncState = SynchronizerState.zero
                    syncState.syncStatus = .upToDate
                    return syncState
                },
                prepareWith: { _, _, _, _ in .success },
                start: { _ in },
                getAllTransactions: { _ in [] },
                isSeedRelevantToAnyDerivedAccount: { _ in true },
                walletAccounts: { [seedDerivedAccount] }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Lets the rest of the cascade settle without asserting on any of it — identical rationale to
    /// RootMigrationGateRefusalTests's `drain`.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    private func runRetryStart(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.initialization(.retryStart))
        await store.receive(
            { action in
                guard case .initialization(.registerForSynchronizersUpdate) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )
    }

    private func runInitializeSDK(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.initialization(.initializeSDK(.existingWallet)))
        await store.receive(
            { action in
                guard case .initialization(.initializationSuccessfullyDone) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )
    }

    // MARK: - Ironwood NOT activated: neither open lane pays for the round trip

    @Test func retryStartSkipsBothMigrationCallsWhenIronwoodIsNotActivated() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: false, migrationMode: nil)
        let store = makeStore(spy: spy)

        await runRetryStart(store)

        #expect(spy.visitKindCalls == 0, "an unactivated wallet must not ask visitKind() — its answer is a constant .sync")
        #expect(spy.beforeSyncAdvanceCalls == 0, "an unactivated wallet must not drive the step driver — its verdict is a constant .notApplicable")

        await drain(store)
    }

    @Test func initializeSDKSkipsBothMigrationCallsWhenIronwoodIsNotActivated() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: false, migrationMode: nil)
        let store = makeStore(spy: spy)

        await runInitializeSDK(store)

        #expect(spy.visitKindCalls == 0, "an unactivated wallet must not ask visitKind() on a cold launch either")
        #expect(spy.beforeSyncAdvanceCalls == 0, "an unactivated wallet must not drive the step driver on a cold launch either")

        await drain(store)
    }

    /// The gate must read the activation flag and STOP — never fall through to the committed-run
    /// predicate, which traps unstubbed in production's `testValue` and, worse, would be consulted
    /// on a wallet where it cannot mean anything.
    @Test func theActivationGateNeverConsultsTheDeviceLocalMode() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: false, migrationMode: nil)
        let store = makeStore(spy: spy)

        await runRetryStart(store)

        #expect(spy.migrationModeCalls == 0, "the open-lane gate must short-circuit on activation, before any mode read")

        await drain(store)
    }

    // MARK: - Ironwood activated with a committed run: unchanged

    @Test func retryStartStillVisitsAndAdvancesForAnActivatedWallet() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: true, migrationMode: .privateScheduled)
        let store = makeStore(spy: spy)

        await runRetryStart(store)

        #expect(spy.visitKindCalls >= 1, "an activated wallet must still classify the session before starting sync")
        #expect(spy.beforeSyncAdvanceCalls >= 1, "an activated wallet must still discharge the engine's next step")

        await drain(store)
    }

    @Test func initializeSDKStillVisitsAndAdvancesForAnActivatedWallet() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: true, migrationMode: .privateScheduled)
        let store = makeStore(spy: spy)

        await runInitializeSDK(store)

        #expect(spy.visitKindCalls >= 1, "a cold launch on an activated wallet must still classify the session")
        #expect(spy.beforeSyncAdvanceCalls >= 1, "a cold launch on an activated wallet must still discharge the engine's next step")

        await drain(store)
    }

    // MARK: - Ironwood activated, NO device-local mode: still driven, and the mode is never asked
    //
    // The investigation pin. A wallet whose stored mode is `nil` is NOT known to be a wallet without
    // an engine run — the mode has one writer and a storage layer that deletes an undecodable blob
    // — so an open lane must keep driving it. If it did not, a run whose mode was lost would have no
    // delivery lane at all: the tick lane's mode belt already holds every transfer whose mode is not
    // `.privateScheduled`. See this file's header.

    @Test func retryStartStillAdvancesAnActivatedWalletWithNoStoredMode() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: true, migrationMode: nil)
        let store = makeStore(spy: spy)

        await runRetryStart(store)

        #expect(spy.visitKindCalls >= 1, "a missing mode must not suppress the session classification")
        #expect(spy.beforeSyncAdvanceCalls >= 1, "a missing mode must not suppress the only delivery lane an engine run has left")
        #expect(spy.migrationModeCalls == 0, "the open lanes must not consult the device-local mode at all")

        await drain(store)
    }

    @Test func initializeSDKStillAdvancesAnActivatedWalletWithNoStoredMode() async throws {
        let spy = OpenLaneSpy(isIronwoodActivated: true, migrationMode: nil)
        let store = makeStore(spy: spy)

        await runInitializeSDK(store)

        #expect(spy.visitKindCalls >= 1, "a missing mode must not suppress the cold launch's session classification")
        #expect(spy.beforeSyncAdvanceCalls >= 1, "a missing mode must not suppress the cold launch's step discharge")
        #expect(spy.migrationModeCalls == 0, "a cold launch must not consult the device-local mode either")

        await drain(store)
    }
}
