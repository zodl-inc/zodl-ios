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
// arrives) as a failure instead of hanging the run.
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

    /// Builds a `Root` `TestStore` wired for a full, successful sync-branch `.retryStart` pass —
    /// the same dependency shape as `RootMigrationGateRefusalTests.syncPassStillReRegistersSynchronizerStreams`.
    /// Every `sdkSynchronizer.start` call is recorded into `startCalls` and then suspends on `gate`
    /// until the test releases it, holding the pipeline "in flight" for as long as the race needs
    /// the window held open.
    private func makeStore(
        startCalls: SignalledRecords<Void>,
        gate: ResumableGate
    ) -> TestStore<Root.State, Root.Action> {
        let seedDerivedAccount = RootRetryStartReentrancyTests.seedDerivedAccount
        let initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .home),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )

        let store = TestStore(
            initialState: initialState
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
                    startCalls.recordCall()
                    await gate.wait()
                },
                getAllTransactions: { _ in [] },
                isSeedRelevantToAnyDerivedAccount: { _ in true },
                walletAccounts: { [seedDerivedAccount] }
            )
        }
        store.exhaustivity = .off
        return store
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
        let gate = ResumableGate()
        let store = makeStore(startCalls: startCalls, gate: gate)

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(1)

        // Background WITHOUT releasing the gate — the first pipeline's `.run` effect carries no
        // `.cancellable` id of its own, so it stays parked, and its finishing send never arrives.
        // This is exactly the "dropped by cancellation (store teardown)" scenario the background
        // reset exists to guard against — reproduced here directly via a pipeline that simply never
        // completes.
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        #expect(!store.state.isRetryStartInFlight, "backgrounding must reset the latch even though the in-flight pipeline never finished")

        await store.send(.initialization(.retryStart)) {
            $0.isRetryStartInFlight = true
        }
        await startCalls.countReached(2)
        #expect(startCalls.count == 2, "a retryStart after backgrounding must proceed even though the previous pipeline never finished")

        gate.open()
        await drain(store)
    }
}
