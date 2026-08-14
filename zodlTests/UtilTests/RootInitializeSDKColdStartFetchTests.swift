//
//  RootInitializeSDKColdStartFetchTests.swift
//  zodlTests
//
//  Cold-start ordering pin for `.initialization(.initializeSDK)`'s first transaction fetch
//  (Features/Root/RootInitialization.swift).
//
//  THE BUG this pins: `.fetchTransactionsForTheSelectedAccount` silently no-ops when
//  `selectedWalletAccount` is nil (RootTransactions.swift's guard), and that shared value is
//  `.inMemory` — nil on every cold launch until `.loadedWalletAccounts` selects the Zashi
//  account. The init effect used to dispatch the fetch BEFORE loading wallet accounts, so the
//  dispatch was a guaranteed no-op and the first effective fetch waited for the post-gate
//  `.observeTransactions` subscription — behind the whole migration gate (and, on send-visit
//  opens, a 10-20s no-sync delivery session). The list sat empty the whole time.
//
//  The pin: by the time the init effect's fetch dispatch is processed, an account IS selected
//  (so the guard passes), and the fetch effect reaches `getAllTransactions` with that account.
//
//  `extension Root.State: @retroactive Equatable` already exists, module-wide, at
//  RootInitializeSDKHealTests.swift — this file must NOT redeclare it (duplicate-conformance
//  compile error; see that file's header).
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized per repo convention for suites driving `.initializeSDK` through a real TestStore —
// see RootInitializeSDKHealTests's identical `@Suite(.serialized)` rationale.
@Suite(.serialized) @MainActor struct RootInitializeSDKColdStartFetchTests {
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

    private func makeStore(
        fetchedAccountIds: LockIsolated<[AccountUUID?]>
    ) -> TestStore<Root.State, Root.Action> {
        let initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )

        let seedDerivedAccount = RootInitializeSDKColdStartFetchTests.seedDerivedAccount

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
                shieldFunds: { },
                reset: { }
            )

            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp

            let seededWallet = RootInitializeSDKColdStartFetchTests.seededWallet
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
            // `.fetchedTransactions` resolves swaps unconditionally before its unchanged-list
            // early-out — this suite (unlike the siblings, which drain before any fetch
            // completes) waits for that reducer to run, so the member must be stubbed.
            $0.userMetadataProvider.allSwaps = { [] }

            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }

            $0.migrationManager.visitKind = { .sync }
            $0.migrationManager.advance = { _ in .broadcast(id: 1) }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                prepareWith: { _, _, _, _ in .success },
                start: { _ in },
                getAllTransactions: { accountUUID in
                    fetchedAccountIds.withValue { $0.append(accountUUID) }
                    return []
                },
                isSeedRelevantToAnyDerivedAccount: { _ in true },
                walletAccounts: { [seedDerivedAccount] }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Same rationale as RootInitializeSDKHealTests.drain: let the `.initializeSDK` cascade
    /// settle without asserting on it, then silence the store's bookkeeping.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - Cold launch: the init effect's fetch dispatch must land AFTER account selection

    @Test func coldStartFetchDispatchLandsAfterAccountSelection() async throws {
        let fetchedAccountIds = LockIsolated<[AccountUUID?]>([])
        let store = makeStore(fetchedAccountIds: fetchedAccountIds)

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        // The FIRST `.fetchTransactionsForTheSelectedAccount` the store receives is the init
        // effect's own dispatch — nothing else dispatches it this early on a cold start. With
        // exhaustivity off, earlier received actions (`.loadedWalletAccounts` included, in the
        // fixed ordering) are still processed while being skipped, so the state read below sees
        // exactly what the fetch's reducer guard saw.
        await store.receive(
            { action in
                guard case .fetchTransactionsForTheSelectedAccount = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(
            store.state.selectedWalletAccount != nil,
            "the init effect's fetch dispatch must be processed only after `.loadedWalletAccounts` selected an account — with a nil account the dispatch is a silent no-op and the list stays empty until the post-gate refetch"
        )

        // And the dispatch must be EFFECTIVE: the fetch effect reaches getAllTransactions with
        // the selected account (the guard's early `.none` return would never get here).
        await store.receive(
            { action in
                guard case .fetchedTransactions = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(
            fetchedAccountIds.value.first == RootInitializeSDKColdStartFetchTests.seedDerivedAccount.id,
            "the first getAllTransactions call must query the account `.loadedWalletAccounts` selected"
        )

        await drain(store)
    }
}
