//
//  SmartBannerTests.swift
//  zodlTests
//
//  More reducers — covers SmartBanner priority-ladder state machine, derived display
//  strings, and simple banner/sheet state transitions
//  (Features/SmartBanner/SmartBannerStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct SmartBannerTests {
    // MARK: - PriorityContent.next()

    @Test func priorityContentNextWalksDownAndWrapsAround() {
        typealias Priority = SmartBanner.State.PriorityContent
        #expect(Priority.priority9.next() == .priority8)
        #expect(Priority.priority8.next() == .priority75)
        #expect(Priority.priority75.next() == .priority7)
        #expect(Priority.priority2.next() == .priority1)
        // priority1 is the lowest raw value; stepping past it wraps back to the top.
        #expect(Priority.priority1.next() == .priority9)
    }

    // MARK: - Computed properties

    @Test func syncingPercentageScalesAndFloorsAtZero() {
        var state = SmartBanner.State()
        state.lastKnownSyncPercentage = -1.0
        #expect(state.syncingPercentage == 0)

        state.lastKnownSyncPercentage = 0.5
        #expect(state.syncingPercentage == 0.5 * 0.999)
    }

    @Test func areFundsSpendableRequiresScanCompleteAndPositiveBalance() {
        var state = SmartBanner.State()
        state.spendableBalance = Zatoshi(100)
        state.isScanProgressComplete = false
        #expect(!state.areFundsSpendable)

        state.isScanProgressComplete = true
        #expect(state.areFundsSpendable)

        state.spendableBalance = Zatoshi(0)
        #expect(!state.areFundsSpendable)
    }

    @Test func remindMeShieldedTextAdvancesThroughPhases() {
        var state = SmartBanner.State()
        state.remindMeShieldedPhaseCounter = 0
        #expect(state.remindMeShieldedText == String(localizable: .smartBannerHelpRemindMePhase1))
        state.remindMeShieldedPhaseCounter = 1
        #expect(state.remindMeShieldedText == String(localizable: .smartBannerHelpRemindMePhase2))
        state.remindMeShieldedPhaseCounter = 2
        #expect(state.remindMeShieldedText == String(localizable: .smartBannerHelpRemindMePhase3))
        // Anything past phase 2 stays on the final phase message.
        state.remindMeShieldedPhaseCounter = 9
        #expect(state.remindMeShieldedText == String(localizable: .smartBannerHelpRemindMePhase3))
    }

    // MARK: - Simple reducer transitions

    @MainActor @Test func openBannerOpensAndShortensSubsequentDelay() async {
        let store = TestStore(initialState: SmartBanner.State()) { SmartBanner() }

        await store.send(.openBanner) {
            $0.delay = 1.0
            $0.isOpen = true
        }
    }

    @MainActor @Test func transparentBalanceUpdatedStoresBalance() async {
        let store = TestStore(initialState: SmartBanner.State()) { SmartBanner() }

        await store.send(.transparentBalanceUpdated(Zatoshi(12_345))) {
            $0.transparentBalance = Zatoshi(12_345)
        }
    }

    @MainActor @Test func closeSheetTappedDismissesSheet() async {
        var state = SmartBanner.State()
        state.isSmartBannerSheetPresented = true
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.closeSheetTapped) {
            $0.isSmartBannerSheetPresented = false
        }
    }

    @MainActor @Test func torSettingsRequestedDismissesSyncTimeoutSheet() async {
        var state = SmartBanner.State()
        state.isSyncTimedOutSheetPresented = true
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.torSettingsRequested) {
            $0.isSyncTimedOutSheetPresented = false
        }
    }

    // MARK: - evaluatePriority8 zero-balance check

    /// A wallet holding funds only in the Ironwood pool (sapling and orchard both empty) must not
    /// be treated as an empty balance. Ironwood is a third shielded pool (NU6.3 / Orchard
    /// note-version V3); the reducer must fold it into the zero-balance check via the SDK's
    /// pool-agnostic `shieldedTotal()` rather than a hand-summed sapling+orchard pair, or the
    /// currency-conversion prompt would be skipped for Ironwood-only holders.
    @MainActor @Test func evaluatePriority8TreatsIronwoodOnlyBalanceAsNonZero() async {
        // Pin the process-global `@Shared(.inMemory(.selectedWalletAccount))` storage to a fresh,
        // isolated `InMemoryStorage` for the duration of the test. `@Suite(.serialized)` only
        // serializes tests within this suite - Swift Testing still runs suites in parallel, so a
        // concurrently running suite that nils or overwrites `selectedWalletAccount` (e.g.
        // AddKeystoneHWWalletTests, ExportTransactionHistoryTests) can clobber it between
        // `withLock` and `.evaluatePriority8`. Without the pin, `state.selectedWalletAccount` can
        // read nil, the balance branch's `if let account ... if let accountBalance` falls through
        // with no `else`, and the reducer still reaches `.triggerPriority` via the exchange-rate
        // check below - so the test would pass vacuously, even against the pre-Ironwood
        // orchard+sapling sum it exists to guard.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = WalletAccount(
                Account(
                    id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
                    name: "Zodl",
                    keySource: nil,
                    seedFingerprint: nil,
                    hdAccountIndex: Zip32AccountIndex(0),
                    ufvk: nil,
                    uivk: nil
                )
            )

            let accountBalance = AccountBalance(
                saplingBalance: .zero,
                orchardBalance: .zero,
                ironwoodBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
                unshielded: .zero
            )

            let synchronizerState: SynchronizerState = {
                var value = SynchronizerState.zero
                value.accountsBalances = [account.id: accountBalance]
                return value
            }()

            var state = SmartBanner.State()
            state.$selectedWalletAccount.withLock { $0 = account }

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.sdkSynchronizer = .mocked(latestState: { synchronizerState })
            }
            store.exhaustivity = .off
            store.dependencies.mainQueue = .immediate

            await store.send(.evaluatePriority8)
            // Falls through to the exchange-rate check (and triggers priority8) instead of
            // short-circuiting straight to priority9 as if the balance were empty.
            await store.receive(\.triggerPriority)
        }
    }
}
