//
//  MigrationEntryTests.swift
//  zodlTests
//
//  Covers the MigrationEntry reducer (Features/Migration/MigrationEntry/MigrationEntryStore.swift)
//  for MOB-1460/1466: mode selection, the disclaimer-visibility derivation, the `nextTapped`
//  delegate contract, and (MOB-1466) `onAppear` loading the orchard-balance-to-migrate amount for
//  the selected account via `MigrationManagerClient`. MOB-1513 (W1): also covers `fiatText`,
//  derived from the shared exchange rate. `.serialized`: state mutates the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` and `@Shared(.inMemory(.exchangeRate))`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationEntryTests {
    private func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    @MainActor @Test func defaultStateIsPrivateScheduledWithNoDisclaimer() async {
        let state = MigrationEntry.State()

        #expect(state.selectedMode == MigrationMode.privateScheduled)
        #expect(state.isDisclaimerVisible == false)
        #expect(state.orchardBalance == Zatoshi.zero)
        #expect(state.selectedWalletAccount == nil)
    }

    @MainActor @Test func fiatTextIsConvertedAmountWhenExchangeRateAvailable() async {
        var state = MigrationEntry.State(orchardBalance: Zatoshi(1_245_800_000))
        let conversion = CurrencyConversion(.usd, ratio: 30, timestamp: 0)
        state.$currencyConversion.withLock { $0 = conversion }

        let expected: String = conversion.convert(state.orchardBalance)
        #expect(state.fiatText == expected)
    }

    @MainActor @Test func fiatTextIsNilWhenExchangeRateUnavailable() async {
        var state = MigrationEntry.State(orchardBalance: Zatoshi(1_245_800_000))
        state.$currencyConversion.withLock { $0 = nil }

        #expect(state.fiatText == nil)
    }

    @MainActor @Test func modeTappedImmediateSelectsModeAndRevealsDisclaimer() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.modeTapped(.immediate)) {
            $0.selectedMode = .immediate
        }

        #expect(store.state.isDisclaimerVisible)
    }

    @MainActor @Test func modeTappedPrivateScheduledSelectsModeAndHidesDisclaimer() async {
        let store = TestStore(initialState: MigrationEntry.State(selectedMode: .immediate)) {
            MigrationEntry()
        }

        await store.send(.modeTapped(.privateScheduled)) {
            $0.selectedMode = .privateScheduled
        }

        #expect(store.state.isDisclaimerVisible == false)
    }

    @MainActor @Test func modeTappedWithAlreadySelectedModeIsANoOp() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.modeTapped(.privateScheduled))
    }

    @MainActor @Test func nextTappedEmitsDelegateChoseWithPrivateScheduledMode() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.nextTapped)
        await store.receive(.delegate(.chose(.privateScheduled)))
    }

    @MainActor @Test func nextTappedEmitsDelegateChoseWithImmediateMode() async {
        let store = TestStore(initialState: MigrationEntry.State(selectedMode: .immediate)) {
            MigrationEntry()
        }

        await store.send(.nextTapped)
        await store.receive(.delegate(.chose(.immediate)))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.delegate(.chose(.immediate)))
    }

    @MainActor @Test func onAppearWithNoSelectedAccountLoadsZeroBalance() async {
        var state = MigrationEntry.State()
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) {
            MigrationEntry()
        } withDependencies: {
            $0.migrationManager.orchardBalanceToMigrate = { accountUUID in
                #expect(accountUUID == nil)
                return Zatoshi(999)
            }
        }

        await store.send(.onAppear)
        await store.receive(\.balanceLoaded) {
            $0.orchardBalance = Zatoshi(999)
        }
    }

    @MainActor @Test func onAppearWithSelectedAccountLoadsOrchardBalanceToMigrate() async {
        let account = walletAccount(idByte: 7)
        var state = MigrationEntry.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        let store = TestStore(initialState: state) {
            MigrationEntry()
        } withDependencies: {
            $0.migrationManager.orchardBalanceToMigrate = { accountUUID in
                #expect(accountUUID == account.id)
                return Zatoshi(1_245_800_000)
            }
        }

        await store.send(.onAppear)
        await store.receive(\.balanceLoaded) {
            $0.orchardBalance = Zatoshi(1_245_800_000)
        }
    }

    @MainActor @Test func findOutMoreOpensSupportArticle() async {
        let opened = LockIsolated<[URL]>([])
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        } withDependencies: {
            $0.openURL = OpenURLEffect { url in
                opened.withValue { $0.append(url) }
                return true
            }
        }

        await store.send(.findOutMoreTapped)
        await store.finish()
        #expect(opened.value == [URL(string: "https://support.zodl.com/article/42-moving-your-funds-to-ironwood")])
    }
}
