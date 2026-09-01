#if VOTING_ENABLED
@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

/// Delegation recovery has to run when the app opens, with nothing for the
/// user to tap.
///
/// This is the property that keeps the whole feature honest. The carver, the
/// escrow and the guard are all well covered on their own, and every one of
/// them is worthless if nothing calls them: that is exactly the defect this
/// branch was written to fix, where 517 lines of recovery shipped with no
/// caller at all. These tests pin the caller.
///
/// Serialized because `.didFinishLaunching` logs through the process-global
/// `LoggerProxy` and touches TCA `@Shared` in-memory state.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct RootDelegationRecoveryOnLaunchTests {
    /// Records that `run` was called, and how often.
    private final class RunSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock(); count += 1; lock.unlock()
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }


    /// The same shape `RootInitializeSDKSingleFlightTests` uses: enough Root
    /// state to take the launch path, and nothing more.
    private static func launchState() -> Root.State {
        Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
    }

    @Test func openingTheAppRunsDelegationRecovery() async {
        let spy = RunSpy()

        let store = TestStore(initialState: Self.launchState()) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            // The launch chain reaches well past recovery, and TCA refuses
            // live dependencies in tests, so everything it touches is stubbed.
            $0.sdkSynchronizer = .mocked()
            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp
            $0.databaseFiles.areDbFilesPresentFor = { _ in true }
            $0.walletStorage = .noOp
            $0.walletStorage.areKeysPresent = { true }
            $0.walletStorage.exportWallet = { .placeholder }
            $0.readTransactionsStorage = .noOp
            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            $0.userDefaults.objectForKey = { _ in nil }
            $0.userDefaults.setValue = { _, _ in }
            $0.userDefaults.remove = { _ in }
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )
            $0.delegationRecovery = DelegationRecoveryClient(
                run: {
                    spy.record()
                    return DelegationRecoveryReport(outcome: .nothingToRecover)
                }
            )
        }
        // The launch chain fans out well beyond this one effect, and the rest
        // of it is covered elsewhere; only the recovery call is asserted here.
        store.exhaustivity = .off

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        await store.finish()

        #expect(spy.callCount == 1, "recovery must run on cold launch")
    }

    /// The run is FIRE AND FORGET: it sends no action back, so a slow or
    /// failing carve cannot stall or alter launch. If someone later chains it
    /// into the reducer, this fails.
    @Test func recoverySendsNoActionBackIntoTheReducer() async {
        let store = TestStore(initialState: Self.launchState()) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            // The launch chain reaches well past recovery, and TCA refuses
            // live dependencies in tests, so everything it touches is stubbed.
            $0.sdkSynchronizer = .mocked()
            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp
            $0.databaseFiles.areDbFilesPresentFor = { _ in true }
            $0.walletStorage = .noOp
            $0.walletStorage.areKeysPresent = { true }
            $0.walletStorage.exportWallet = { .placeholder }
            $0.readTransactionsStorage = .noOp
            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            $0.userDefaults.objectForKey = { _ in nil }
            $0.userDefaults.setValue = { _, _ in }
            $0.userDefaults.remove = { _ in }
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )
            $0.delegationRecovery = DelegationRecoveryClient(
                run: {
                    // A report that would be very visible if it were ever
                    // surfaced as an action.
                    DelegationRecoveryReport(
                        outcome: .recovered,
                        rounds: 1,
                        bundlesEscrowed: 3
                    )
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        await store.finish()

        // Nothing to assert on state: the point is that `finish()` returns
        // without an unhandled action, which TestStore enforces for us.
    }

    /// A recovery that throws its way to a failure report must not take the
    /// launch with it.
    @Test func aFailedRecoveryDoesNotBreakLaunch() async {
        let spy = RunSpy()

        let store = TestStore(initialState: Self.launchState()) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            // The launch chain reaches well past recovery, and TCA refuses
            // live dependencies in tests, so everything it touches is stubbed.
            $0.sdkSynchronizer = .mocked()
            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp
            $0.databaseFiles.areDbFilesPresentFor = { _ in true }
            $0.walletStorage = .noOp
            $0.walletStorage.areKeysPresent = { true }
            $0.walletStorage.exportWallet = { .placeholder }
            $0.readTransactionsStorage = .noOp
            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            $0.userDefaults.objectForKey = { _ in nil }
            $0.userDefaults.setValue = { _, _ in }
            $0.userDefaults.remove = { _ in }
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )
            $0.delegationRecovery = DelegationRecoveryClient(
                run: {
                    spy.record()
                    return DelegationRecoveryReport(outcome: .failed)
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        await store.finish()

        #expect(spy.callCount == 1)
    }
}
#endif
