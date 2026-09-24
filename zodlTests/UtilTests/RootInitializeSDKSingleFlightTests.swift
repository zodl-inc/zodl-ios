//
//  RootInitializeSDKSingleFlightTests.swift
//  zodlTests
//
//  Regression test for [#1943]: wallet initialization must be single-flight.
//
//  `.initialization(.initializeSDK)` runs `sdkSynchronizer.prepareWith` in an effect, and
//  the SDK reports an unprepared status until `prepare` fully returns, so
//  `.appDelegate(.willEnterForeground)` re-enters
//  `.initialSetups → .checkWalletInitialization → .initializeSDK` while a first prepare is
//  still in flight. The `isInitializingSDK` latch makes the first prepare win and drops
//  re-entries until the in-flight effect signals completion. This test holds the first
//  `prepareWith` open on a gate, fires the foreground re-entry, and asserts no second
//  `prepareWith` is dispatched.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

// `Root.State: Equatable` is provided test-target-wide by RootInitializeSDKHealTests.swift.
//
// `.initialSetups` logs through the process-global `LoggerProxy`, and the effects under test
// mutate TCA `@Shared` in-memory state (`walletStatus`, `walletAccounts`), so this suite is
// serialized per repo convention. `.timeLimit` records a genuinely-never-arriving prepare as a
// failure — the event-driven wait below has no deadline of its own (see
// MigrationSweepBannerFreshnessTests' header for why wall-clock budgets were retired).
@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct RootInitializeSDKSingleFlightTests {
    /// Resumable gate the mocked `prepareWith` suspends on, keeping the first prepare
    /// "in flight" for as long as the test needs the race window held open.
    private final class PrepareGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                continuations.append(continuation)
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            let waiting = continuations
            continuations = []
            lock.unlock()
            waiting.forEach { $0.resume() }
        }
    }

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

    /// Wires a `Root` `TestStore` so the full launch chain
    /// (`didFinishLaunching → initialSetups → checkWalletInitialization →
    /// respondToWalletInitializationState(.initialized) → initializeSDK(.restoreWallet)`)
    /// runs against recorded fakes. `udIsRestoringWallet == true` routes `.initialized` into
    /// `.restoreWallet` mode — the mid-restore situation the race needs — and the mocked
    /// synchronizer's `latestState` stays `.zero` (`.unprepared`) throughout, exactly as the
    /// real SDK reports while a `prepare` call is still in flight. Every `prepareWith` call
    /// suspends on `gate` until the test opens it.
    private func makeStore(
        prepareModes: SignalledRecords<String>,
        gate: PrepareGate
    ) -> TestStore<Root.State, Root.Action> {
        let seedDerivedAccount = Self.seedDerivedAccount
        let initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
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

            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )

            $0.mnemonic = .noOp

            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }

            $0.databaseFiles = .noOp
            $0.databaseFiles.areDbFilesPresentFor = { _ in true }

            $0.walletStorage = .noOp
            $0.walletStorage.areKeysPresent = { true }
            $0.walletStorage.exportWallet = { .placeholder }

            $0.userDefaults.objectForKey = { key in
                key == Root.Constants.udIsRestoringWallet ? true : nil
            }
            $0.userDefaults.setValue = { _, _ in }
            $0.userDefaults.remove = { _ in }

            $0.readTransactionsStorage = .noOp

            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }

            $0.userMetadataProvider.load = { _ in }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                prepareWith: { _, _, _, _ in
                    // The SDK derives the init flow itself now, so there is no mode to record; what this
                    // test asserts is that exactly ONE prepare is dispatched per launch.
                    prepareModes.record("prepare")
                    await gate.wait()
                    return .success
                },
                getAllTransactions: { _ in [] },
                isSeedRelevantToAnyDerivedAccount: { _ in true },
                walletAccounts: { [seedDerivedAccount] }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Bounded SETTLE WINDOW for the negative check only ("a second prepare does NOT arrive") —
    /// a non-event has no completion signal to await, so a window is the honest shape; under
    /// load its failure mode is a false PASS (the late second dispatch lands after the window),
    /// never a spurious red. Positive waits in this suite are event-driven
    /// (`SignalledRecords.countReached`) and must not come back to this helper.
    private func settleWindow(iterations: Int = 50, _ condition: @escaping @Sendable () -> Bool) async {
        for _ in 0..<iterations where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Same rationale as RootInitializeSDKHealTests.drain: let the `.initializeSDK` cascade
    /// settle without asserting on it, then silence the store's bookkeeping.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    @Test func foregroundWhileUnpreparedDoesNotDispatchSecondPrepare() async throws {
        let prepareModes = SignalledRecords<String>()
        let gate = PrepareGate()
        let store = makeStore(prepareModes: prepareModes, gate: gate)

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        await prepareModes.countReached(1)
        #expect(prepareModes.values == ["prepare"], "launch must reach exactly one prepareWith")

        // The first prepare is now suspended on the gate and the synchronizer still reports
        // `.unprepared` — as it does for the entire duration of a real in-flight prepare — so
        // foregrounding takes the `.initialSetups` branch and re-enters the initialization
        // chain. The single-flight latch must swallow the re-entry's `.initializeSDK`.
        await store.send(.initialization(.appDelegate(.willEnterForeground)))

        // Bounded settle window: before the fix the second prepareWith arrived within a few
        // milliseconds of the re-entry, so a second dispatch would be observed here.
        await settleWindow { prepareModes.count >= 2 }
        #expect(
            prepareModes.values == ["prepare"],
            "a foreground re-entry must not dispatch another prepareWith while one is in flight"
        )

        gate.open()
        await drain(store)
    }
}
