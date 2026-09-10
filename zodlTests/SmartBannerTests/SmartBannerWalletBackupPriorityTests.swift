//
//  SmartBannerWalletBackupPriorityTests.swift
//  zodlTests
//
//  MOB-1786 (approved 2026-09-09): a wallet that has received funds while its seed is still
//  unbacked shows the backup prompt ahead of every other banner. Three users lost funds because
//  the rung sat at 6 — bottom half of the ladder — and the walk short-circuits at the first
//  match, so migration or an error state holding the seat meant the prompt was never even asked.
//
//  Two things had to change together and this suite pins both: the rung is now asked FIRST
//  (straight after the ladder's account guard, as `.evaluatePriorityWalletBackup`), and it seats
//  at rank -1 so it also wins in the displacement direction. Changing only one leaves the other
//  ordering wrong.
//
//  What did NOT change: the gates. A new wallet cannot spend, so any transaction is a receive —
//  which is why `transactions.isEmpty` is the "has received funds" test, and why spending back
//  down to zero must not retract the prompt. The keychain's `hasUserPassedPhraseBackupTest` ends
//  it for good, and the user's own "Remind me later" is still honoured (reminder cadence belongs
//  to PRO-276).
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerWalletBackupPriorityTests {
    private static func walletAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 9, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Currency conversion (rung 8) claims the slot whenever it is unconfigured, which would end
    /// any walk before the rungs under test.
    private static func preferencesWithCurrencyConversionSetUp() -> UserPreferencesStorageClient {
        var preferences = UserPreferencesStorageClient()
        preferences.exchangeRate = { UserPreferencesStorage.ExchangeRate(manual: true, automatic: true) }
        return preferences
    }

    /// The backup rung's own conditions: a Zcash account, at least one transaction (i.e. funds
    /// were received), and `.noOp` wallet storage, whose `StoredWallet.placeholder` has not
    /// passed the phrase backup test and has no reminder on record — so it claims at phase 1.
    private static func backupOwedState() -> SmartBanner.State {
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount() }
        state.$transactions.withLock { $0 = [TransactionState.mockedReceived] }
        return state
    }

    private static func store(_ state: SmartBanner.State) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = .noOp
            $0.sdkSynchronizer = .mocked()
            $0.walletStorage = .noOp
            $0.userStoredPreferences = preferencesWithCurrencyConversionSetUp()
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off
        return store
    }

    // MARK: - Rank

    // Rank is the single ordering authority for displacement. -1 has to beat every other rung,
    // including the residual (1.75, 2026-08-25) this ticket knowingly supersedes.
    @Test func backupOutranksEveryOtherRung() {
        let backup = SmartBanner.State.PriorityContent.priority6.rank
        for other in [
            SmartBanner.State.PriorityContent.priority1,       // disconnected, 0
            .priority2,                                        // sync error, 1
            .priorityMigration,                                // 1.5
            .priorityResidual,                                 // 1.75, MOB-1749
            .priority3, .priority4, .priority5, .priority7, .priority8, .priority9
        ] {
            #expect(backup < other.rank, "wallet backup must outrank \(other)")
        }
    }

    // The walk-down helper reads `rawValue`, which deliberately did NOT move — only `rank` did.
    @Test func rawValueIsUnchangedSoTheWalkDownHelperIsUntouched() {
        #expect(SmartBanner.State.PriorityContent.priority6.rawValue == 6)
        #expect(SmartBanner.State.PriorityContent.priority7.next() == .priority6)
    }

    // MARK: - Walk order

    // The ladder asks backup straight after the account guard, ahead of the migration and
    // residual rungs. Rank alone would not save it: the walk stops at the first match.
    @Test func theLadderAsksBackupFirst() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Self.store(Self.backupOwedState())

            await store.send(.evaluatePriority1)
            await store.receive(\.evaluatePriorityWalletBackup)
            await store.receive(\.triggerPriority)
            // `.triggerPriority` only records the request; `.openBannerRequest` applies the rank
            // guard and assigns the seat.
            await store.receive(\.openBannerRequest)
            await store.finish()

            #expect(store.state.priorityContent == .priority6)
        }
    }

    // The reported bug, from the displacement side: a banner already seated must give the slot up.
    @Test func backupDisplacesASeatedMigrationBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Self.backupOwedState()
            state.priorityContent = .priorityMigration
            let store = Self.store(state)

            await store.send(.evaluatePriority1)
            await store.receive(\.evaluatePriorityWalletBackup)
            await store.receive(\.triggerPriority)
            // `.triggerPriority` only records the request; `.openBannerRequest` applies the rank
            // guard and assigns the seat.
            await store.receive(\.openBannerRequest)
            await store.finish()

            #expect(store.state.priorityContent == .priority6, "migration held the seat for days in the field report")
        }
    }

    // The production path. `featureFlags.migration` gates only the ladder's PULL rung; in a
    // production build (flag off) the migration banner arrives by PUSH — the manager's state
    // stream funnels into `.migrationVariantUpdated`, which seats `priorityMigration` with no
    // flag check at all. So the displacement test above is not enough: backup must also HOLD
    // when a `.required` variant is pushed at it while it owns the slot. The R3 claim branch
    // still fires `triggerPriority(.priorityMigration)`; the rank guard in `.openBannerRequest`
    // (1.5 >= -1) has to be what rejects it.
    @Test func aPushedMigrationVariantCannotDisplaceASeatedWalletBackup() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Self.backupOwedState()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: false) }
            state.priorityContent = .priority6

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.bannerVariant = { _ in .required }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked()
                $0.walletStorage = .noOp
                $0.userStoredPreferences = Self.preferencesWithCurrencyConversionSetUp()
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(.required))
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            await store.finish()

            #expect(
                store.state.priorityContent == .priority6,
                "a pushed migration variant (the production path, flag off) must not take the seat from backup"
            )
        }
    }

    // MARK: - The first-receive hook (rung 6)

    // `RootTransactions` re-enters the ladder at `.evaluatePriority6` whenever the transactions
    // array changes. That hook is how a NEW wallet gets the prompt: at init-done the head rung
    // walked past an empty history, so the first receive is the first time backup can claim.
    // The first cut of MOB-1786 made rung 6 a pass-through and the hook landed on the shielding
    // rung instead -- a transparent first receive seated the shielding offer and backup was never
    // asked again (field-caught 2026-09-10). Both directions are pinned here.
    @Test func theFirstReceiveReasksBackupAtRungSixAndDisplacesShielding() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Self.backupOwedState()
            // The transparent-receive shielding offer already holds the slot.
            state.priorityContent = .priority7
            let store = Self.store(state)

            await store.send(.evaluatePriority6)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            await store.finish()

            #expect(store.state.priorityContent == .priority6, "the first receive must surface backup even over a seated shielding offer")
        }
    }

    @Test func theFirstReceiveReasksBackupAtRungSixOnAnEmptySlot() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Self.store(Self.backupOwedState())

            await store.send(.evaluatePriority6)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            await store.finish()

            #expect(store.state.priorityContent == .priority6)
        }
    }

    // With nothing owed, rung 6 walks on exactly as it always did.
    @Test func rungSixStillWalksOnWhenNoBackupIsOwed() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Self.backupOwedState()
            state.$transactions.withLock { $0 = [] }
            let store = Self.store(state)

            await store.send(.evaluatePriority6)
            await store.receive(\.evaluatePriority7)
            await store.finish()

            #expect(store.state.priorityContent != .priority6)
        }
    }

    // MARK: - Gates that did not change

    // A wallet with no transactions has received nothing — nothing is at risk yet, so the walk
    // must fall through to the rest of the ladder rather than claim the top slot.
    @Test func noTransactionsMeansNoPrompt() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Self.backupOwedState()
            state.$transactions.withLock { $0 = [] }
            let store = Self.store(state)

            await store.send(.evaluatePriority1)
            await store.receive(\.evaluatePriorityWalletBackup)
            await store.receive(\.evaluatePriority2)
            await store.finish()

            #expect(store.state.priorityContent != .priority6)
        }
    }

    // The ladder refuses to walk at all without an account — backup is asked after that guard,
    // never before it.
    @Test func noAccountHoldsTheLadderBeforeBackupIsAsked() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Self.backupOwedState()
            state.$selectedWalletAccount.withLock { $0 = nil }
            let store = Self.store(state)

            await store.send(.evaluatePriority1)
            await store.finish()

            #expect(store.state.priorityContent == nil)
        }
    }
}
