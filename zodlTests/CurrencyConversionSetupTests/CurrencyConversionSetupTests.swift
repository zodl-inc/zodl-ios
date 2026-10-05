//
//  CurrencyConversionSetupTests.swift
//  zodlTests
//
//  More reducers — covers CurrencyConversionSetup opt-in/opt-out preference loading,
//  option changes, and immediate protected routing when enabling Tor (MOB-1364)
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

    // MARK: - Enabling protected access

    @MainActor @Test(arguments: [false, true])
    func enableTorTappedShouldRouteSwapAccessProtected(fails: Bool) async {
        enum TorFailure: Error { case failed }

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
            let torCalls = LockIsolated<[Bool]>([])
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            let store = TestStore(initialState: CurrencyConversionSetup.State()) {
                CurrencyConversionSetup()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage.importTorSetupFlag = { enabled in #expect(enabled) }
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.sdkSynchronizer.exchangeRateEnabled = { _ in }
                $0.sdkSynchronizer.torEnabled = { [sharedAccess = $swapAPIAccess] enabled in
                    #expect(sharedAccess.wrappedValue == .protected)
                    torCalls.withValue { $0.append(enabled) }
                    if fails { throw TorFailure.failed }
                }
            }
            store.exhaustivity = .off

            await store.send(.enableTorTapped)
            #expect(swapAPIAccess == .protected)
            if fails {
                await store.receive(.torInitFailed)
            }
            await store.finish()

            #expect(torCalls.value == [true])
            #expect(swapAPIAccess == .protected)
            if fails {
                #expect(saved.value == nil)
            } else {
                #expect(saved.value == UserPreferencesStorage.ExchangeRate(manual: true, automatic: false))
            }
        }
    }
}
