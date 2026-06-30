//
//  CurrencyConversionSetupTests.swift
//  zodlTests
//
//  More reducers — covers CurrencyConversionSetup opt-in/opt-out preference loading,
//  option changes, and the §6.2 Tor-routing gap (MOB-1364)
//  (Features/CurrencyConversionSetup/CurrencyConversionSetupStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct CurrencyConversionSetupTests {
    // MARK: - isSaveButtonDisabled

    @Test func isSaveButtonDisabledWhenCurrentMatchesActive() {
        var state = CurrencyConversionSetup.State(activeSettingsOption: .optIn, currentSettingsOption: .optIn)
        #expect(state.isSaveButtonDisabled)

        state.currentSettingsOption = .optOut
        #expect(!state.isSaveButtonDisabled)
    }

    // MARK: - onAppear

    @MainActor @Test func onAppearOptInWhenPreferenceAutomatic() async {
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.walletStorage.exportTorSetupFlag = { true }
            $0.userStoredPreferences.exchangeRate = { UserPreferencesStorage.ExchangeRate(manual: true, automatic: true) }
        }

        await store.send(.onAppear) {
            $0.isTorOn = true
            $0.activeSettingsOption = .optIn
            $0.currentSettingsOption = .optIn
        }
    }

    @MainActor @Test func onAppearOptOutWhenNoPreference() async {
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.walletStorage.exportTorSetupFlag = { false }
            $0.userStoredPreferences.exchangeRate = { nil }
        }

        await store.send(.onAppear) {
            $0.activeSettingsOption = .optOut
        }
    }

    // MARK: - Option changes

    @MainActor @Test func settingsOptionTappedUpdatesCurrentOption() async {
        let store = TestStore(initialState: CurrencyConversionSetup.State()) { CurrencyConversionSetup() }

        await store.send(.settingsOptionTapped(.optIn)) {
            $0.currentSettingsOption = .optIn
        }
    }

    @MainActor @Test func settingsOptionChangedOptOutClearsConversion() async {
        var state = CurrencyConversionSetup.State()
        state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0) }
        let store = TestStore(initialState: state) { CurrencyConversionSetup() }

        await store.send(.settingsOptionChanged(.optOut)) {
            $0.$currencyConversion.withLock { $0 = nil }
        }
    }

    @MainActor @Test func skipTappedPersistsDisabledPreference() async {
        let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
        }

        await store.send(.skipTapped)

        #expect(saved.value == UserPreferencesStorage.ExchangeRate(manual: false, automatic: false))
    }

    // MARK: - Bug §6.2 (MOB-1364 gap)

    /// Enabling Tor from the currency-conversion sheet must route swap/exchange/voting
    /// through the protected path immediately, exactly like `TorSetup` does on every
    /// enable path. Today `enableTorTapped` never touches `swapAPIAccess`, so it stays
    /// `.direct` until the next launch — a privacy gap. Pinned as a known issue until fixed.
    @MainActor @Test func enableTorTappedShouldRouteSwapAccessProtected() async {
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
        $swapAPIAccess.withLock { $0 = .direct }

        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.walletStorage.importTorSetupFlag = { _ in }
            $0.userStoredPreferences.setExchangeRate = { _ in }
            $0.sdkSynchronizer.exchangeRateEnabled = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.enableTorTapped)
        await store.finish()

        withKnownIssue("Bug §6.2: enableTorTapped never routes swapAPIAccess to .protected (MOB-1364 gap)") {
            #expect(swapAPIAccess == .protected)
        }
    }
}
