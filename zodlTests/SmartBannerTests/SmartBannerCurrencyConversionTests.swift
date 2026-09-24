//
//  SmartBannerCurrencyConversionTests.swift
//  zodlTests
//
//  The currency-conversion offer (`priority8`) is shown only while the user has never answered
//  it. An answer given anywhere but the banner's own flow — Settings, the Tor opt-out — must not
//  leave the offer on Home.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized)
@MainActor
struct SmartBannerCurrencyConversionTests {
    @Test(arguments: [true, false])
    func seatedOfferRetractsWhenHomeAppearsAfterTheUserAnswered(conversionEnabled: Bool) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                isOpen: true,
                saved: UserPreferencesStorage.ExchangeRate(manual: conversionEnabled, automatic: conversionEnabled)
            )

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == nil)
            #expect(store.state.isOpen == false)
        }
    }

    @Test
    func seatedOfferStaysWhenHomeAppearsWhileUnanswered() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(isOpen: true, saved: nil)

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority8)
            #expect(store.state.isOpen == true)
        }
    }

    /// The seat opens after a delay; an answer that lands in between must not open a stale offer.
    @Test
    func offerAnsweredBeforeItOpensIsNotOpened() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                isOpen: false,
                saved: UserPreferencesStorage.ExchangeRate(manual: true, automatic: true)
            )

            await store.send(.openBanner)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == nil)
            #expect(store.state.isOpen == false)
        }
    }

    /// The reported flow: the offer is on Home, the user turns conversion on (in PEN) from
    /// Settings → Currency Conversion and comes back to Home.
    @Test
    func enablingFromSettingsLeavesNoOfferOnHome() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            var initialState = Root.State.initial
            initialState.path = .settings
            initialState.homeState.smartBannerState.priorityContent = .priority8
            initialState.homeState.smartBannerState.isOpen = true

            let store = TestStore(initialState: initialState) {
                Root()
            } withDependencies: {
                quietBannerDependencies(&$0)
                $0.userStoredPreferences.exchangeRate = { saved.value }
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.exchangeRate.refreshExchangeRateUSD = { }
            }
            store.exhaustivity = .off

            let pen = try #require(CurrencyISO4217(rawValue: "PEN"))
            await store.send(.settings(.currencyConversionTapped))
            let id = try #require(store.state.settingsState.path.ids.last)
            await store.send(.settings(.path(.element(id: id, action: .currencyConversionSetup(.settingsOptionTapped(.optIn))))))
            await store.send(.settings(.path(.element(id: id, action: .currencyConversionSetup(.currencyChanged(pen))))))
            await store.send(.settings(.path(.element(id: id, action: .currencyConversionSetup(.saveChangesTapped)))))
            await store.finish()
            await store.send(.settings(.backToHomeTapped))
            // RootView reports the return to Home as `.home(.onAppear)`, which Home hands on to the
            // banner as its own `.onAppear`.
            await store.send(.home(.smartBanner(.onAppear)))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(saved.value == UserPreferencesStorage.ExchangeRate(manual: true, automatic: true, currency: pen))
            #expect(store.state.path == nil)
            #expect(store.state.homeState.smartBannerState.priorityContent == nil)
            #expect(store.state.homeState.smartBannerState.isOpen == false)
        }
    }

    private func makeStore(
        isOpen: Bool,
        saved: UserPreferencesStorage.ExchangeRate?
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.priorityContent = .priority8
        state.isOpen = isOpen

        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            quietBannerDependencies(&$0)
            $0.userStoredPreferences.exchangeRate = { saved }
        }
        store.exhaustivity = .off
        return store
    }
}

/// Everything the banner's `.onAppear` subscribes to, answering nothing and completing, so an
/// appear leaves no effect running.
@MainActor
private func quietBannerDependencies(_ values: inout DependencyValues) {
    values.mainQueue = .immediate
    values.walletStorage = .noOp
    values.sdkSynchronizer = .noOp
    values.zcashSDKEnvironment = .testnet
    values.networkMonitor = NetworkMonitorClient(
        networkMonitorStream: { Empty().eraseToAnyPublisher() }
    )
    values.shieldingProcessor = ShieldingProcessorClient(
        observe: { Empty().eraseToAnyPublisher() },
        shieldFunds: { }
    )
    values.migrationManager.stateEvents = { _ in Empty().eraseToAnyPublisher() }
    values.migrationManager.migrationSnapshotEvents = { _ in Empty().eraseToAnyPublisher() }
}
