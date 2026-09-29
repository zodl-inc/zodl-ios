//
//  CurrencyConversionPickerTests.swift
//  zodlTests
//

import ComposableArchitecture
import Testing
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CurrencyConversionPickerTests {
    @Test
    func openingPickerStartsCatalogWithoutOptingIntoCurrencyConversion() async {
        let (stream, continuation) = AsyncStream<FiatCurrencyCatalogState>.makeStream()
        let loadCalls = SignalledRecords<Void>()
        let savedPreferences = LockIsolated<[UserPreferencesStorage.ExchangeRate]>([])
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.fiatCurrencyCatalog.observe = { stream }
            $0.fiatCurrencyCatalog.ensureLoaded = { loadCalls.recordCall() }
            $0.userStoredPreferences.setExchangeRate = { preference in
                savedPreferences.withValue { $0.append(preference) }
            }
        }

        await store.send(.currencyPickerTapped) {
            $0.isCurrencyPickerSheetPresented = true
        }
        let observation = await store.send(.currencyPickerTask)
        await loadCalls.countReached(1)

        let loaded = FiatCurrencyCatalogState(currencies: [.eur, .usd])
        continuation.yield(loaded)
        await store.receive(.currencyCatalogUpdated(loaded)) {
            $0.catalog = loaded
        }

        #expect(loadCalls.count == 1)
        #expect(savedPreferences.value.isEmpty)
        #expect(store.state.currentSettingsOption == CurrencyConversionSetup.State.SettingsOptions.optOut)
        await store.send(.currencyPickerDismissed) {
            $0.isCurrencyPickerSheetPresented = false
        }
        await observation.finish()
    }

    @Test
    func pickerTracksLoadingErrorAndSuccessSnapshots() async {
        let (stream, continuation) = AsyncStream<FiatCurrencyCatalogState>.makeStream()
        let loadCalls = SignalledRecords<Void>()
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.fiatCurrencyCatalog.observe = { stream }
            $0.fiatCurrencyCatalog.ensureLoaded = { loadCalls.recordCall() }
        }

        let observation = await store.send(.currencyPickerTask)
        await loadCalls.countReached(1)

        let loading = FiatCurrencyCatalogState(isLoading: true)
        continuation.yield(loading)
        await store.receive(.currencyCatalogUpdated(loading)) {
            $0.catalog = loading
        }

        let failed = FiatCurrencyCatalogState(hasError: true)
        continuation.yield(failed)
        await store.receive(.currencyCatalogUpdated(failed)) {
            $0.catalog = failed
        }

        let loaded = FiatCurrencyCatalogState(currencies: [.usd, .eur])
        continuation.yield(loaded)
        await store.receive(.currencyCatalogUpdated(loaded)) {
            $0.catalog = loaded
        }

        await store.send(.currencyPickerDismissed)
        await observation.finish()
    }

    @Test
    func retryRefreshesCatalogWithoutStartingAnotherObserver() async {
        let observeCalls = SignalledRecords<Void>()
        let refreshCalls = SignalledRecords<Void>()
        let (stream, _) = AsyncStream<FiatCurrencyCatalogState>.makeStream()
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.fiatCurrencyCatalog.observe = {
                observeCalls.recordCall()
                return stream
            }
            $0.fiatCurrencyCatalog.ensureLoaded = {}
            $0.fiatCurrencyCatalog.refresh = { refreshCalls.recordCall() }
        }

        let observation = await store.send(.currencyPickerTask)
        await observeCalls.countReached(1)
        let retry = await store.send(.retryCurrenciesTapped)
        await refreshCalls.countReached(1)
        await retry.finish()

        #expect(observeCalls.count == 1)
        #expect(refreshCalls.count == 1)
        await store.send(.currencyPickerDismissed)
        await observation.finish()
    }

    @Test
    func swipeDismissalCancelsCatalogObservation() async {
        let (stream, continuation) = Self.observedStream()
        let started = SignalledRecords<Void>()
        let cancelled = SignalledRecords<Void>()
        continuation.onTermination = { _ in cancelled.recordCall() }
        var state = CurrencyConversionSetup.State()
        state.isCurrencyPickerSheetPresented = true
        let store = Self.store(state: state, stream: stream, started: started)

        let observation = await store.send(.currencyPickerTask)
        await started.countReached(1)
        await store.send(.binding(.set(\.isCurrencyPickerSheetPresented, false))) {
            $0.isCurrencyPickerSheetPresented = false
        }
        await cancelled.countReached(1)
        await observation.finish()
    }

    @Test
    func closeActionCancelsCatalogObservation() async {
        let (stream, continuation) = Self.observedStream()
        let started = SignalledRecords<Void>()
        let cancelled = SignalledRecords<Void>()
        continuation.onTermination = { _ in cancelled.recordCall() }
        var state = CurrencyConversionSetup.State()
        state.isCurrencyPickerSheetPresented = true
        let store = Self.store(state: state, stream: stream, started: started)

        let observation = await store.send(.currencyPickerTask)
        await started.countReached(1)
        await store.send(.currencyPickerDismissed) {
            $0.isCurrencyPickerSheetPresented = false
        }
        await cancelled.countReached(1)
        await observation.finish()
    }

    @Test
    func selectingCurrencyCancelsCatalogObservationAndChangesOnlyDraft() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let (stream, continuation) = Self.observedStream()
        let started = SignalledRecords<Void>()
        let cancelled = SignalledRecords<Void>()
        let writes = LockIsolated<[UserPreferencesStorage.ExchangeRate]>([])
        continuation.onTermination = { _ in cancelled.recordCall() }
        var state = CurrencyConversionSetup.State(selectedCurrency: .usd)
        state.isCurrencyPickerSheetPresented = true
        let store = TestStore(initialState: state) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.fiatCurrencyCatalog.observe = { stream }
            $0.fiatCurrencyCatalog.ensureLoaded = { started.recordCall() }
            $0.userStoredPreferences.setExchangeRate = { preference in
                writes.withValue { $0.append(preference) }
            }
        }

        let observation = await store.send(.currencyPickerTask)
        await started.countReached(1)
        await store.send(.currencyChanged(czk)) {
            $0.selectedCurrency = czk
            $0.isCurrencyPickerSheetPresented = false
        }
        await cancelled.countReached(1)
        await observation.finish()

        #expect(store.state.initialCurrency == CurrencyISO4217.usd)
        #expect(writes.value.isEmpty)
    }

    @Test
    func cachedSnapshotIsConsumedAfterObservationStartsBeforeEnsureLoaded() async {
        let events = SignalledRecords<String>()
        let cached = FiatCurrencyCatalogState(currencies: [.eur, .usd])
        let stream = AsyncStream<FiatCurrencyCatalogState> { continuation in
            continuation.yield(cached)
            continuation.finish()
        }
        let store = TestStore(initialState: CurrencyConversionSetup.State()) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.fiatCurrencyCatalog.observe = {
                events.record("observe")
                return stream
            }
            $0.fiatCurrencyCatalog.ensureLoaded = { events.record("load") }
        }

        let observation = await store.send(.currencyPickerTask)
        await store.receive(.currencyCatalogUpdated(cached)) {
            $0.catalog = cached
        }
        await observation.finish()

        #expect(events.values == ["observe", "load"])
    }

    @Test
    func catalogWithoutSavedCurrencyPreservesSelectionAndPreferences() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let writes = LockIsolated<[UserPreferencesStorage.ExchangeRate]>([])
        let state = CurrencyConversionSetup.State(
            activeSettingsOption: .optIn,
            currentSettingsOption: .optIn,
            isSettingsView: true,
            selectedCurrency: czk
        )
        let store = TestStore(initialState: state) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.userStoredPreferences.setExchangeRate = { preference in
                writes.withValue { $0.append(preference) }
            }
        }
        let loaded = FiatCurrencyCatalogState(currencies: [.usd, .eur])

        await store.send(.currencyCatalogUpdated(loaded)) {
            $0.catalog = loaded
        }

        #expect(store.state.selectedCurrency == czk)
        #expect(store.state.initialCurrency == czk)
        #expect(store.state.activeSettingsOption == CurrencyConversionSetup.State.SettingsOptions.optIn)
        #expect(store.state.currentSettingsOption == CurrencyConversionSetup.State.SettingsOptions.optIn)
        #expect(writes.value.isEmpty)
    }

    @Test
    func savePersistsDraftCurrencyOnlyWhenSaveIsTappedWithTorOff() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let writes = LockIsolated<[UserPreferencesStorage.ExchangeRate]>([])
        let sdkValues = LockIsolated<[Bool]>([])
        let store = TestStore(
            initialState: CurrencyConversionSetup.State(
                activeSettingsOption: .optIn,
                currentSettingsOption: .optIn,
                isSettingsView: true,
                selectedCurrency: .usd
            )
        ) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.exchangeRate.refreshExchangeRateUSD = {}
            $0.sdkSynchronizer.exchangeRateEnabled = { isEnabled in
                sdkValues.withValue { $0.append(isEnabled) }
            }
            $0.userStoredPreferences.setExchangeRate = { preference in
                writes.withValue { $0.append(preference) }
            }
        }

        await store.send(.currencyChanged(czk)) {
            $0.selectedCurrency = czk
        }
        #expect(writes.value.isEmpty)

        await store.send(.saveChangesTapped) {
            $0.activeSettingsOption = CurrencyConversionSetup.State.SettingsOptions.optIn
            $0.initialCurrency = czk
        }
        await store.receive(.settingsOptionChanged(.optIn))
        await store.receive(.torInitSucceeded)
        await store.receive(.backToHomeTapped)

        #expect(writes.value == [UserPreferencesStorage.ExchangeRate(manual: true, automatic: true, currency: czk)])
        #expect(sdkValues.value == [true])
        #expect(!store.state.isTorSheetPresented)
    }

    @Test
    func enablePersistsDraftCurrencyWithTorOffWithoutPrompt() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let writes = LockIsolated<[UserPreferencesStorage.ExchangeRate]>([])
        let sdkValues = LockIsolated<[Bool]>([])
        let store = TestStore(initialState: CurrencyConversionSetup.State(selectedCurrency: czk)) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.exchangeRate.refreshExchangeRateUSD = {}
            $0.sdkSynchronizer.exchangeRateEnabled = { isEnabled in
                sdkValues.withValue { $0.append(isEnabled) }
            }
            $0.userStoredPreferences.setExchangeRate = { preference in
                writes.withValue { $0.append(preference) }
            }
        }

        await store.send(.enableTapped)
        await store.receive(.torInitSucceeded)

        #expect(writes.value == [UserPreferencesStorage.ExchangeRate(manual: true, automatic: true, currency: czk)])
        #expect(sdkValues.value == [true])
        #expect(!store.state.isTorSheetPresented)
    }

    private static func observedStream() -> (
        AsyncStream<FiatCurrencyCatalogState>,
        AsyncStream<FiatCurrencyCatalogState>.Continuation
    ) {
        AsyncStream<FiatCurrencyCatalogState>.makeStream()
    }

    private static func store(
        state: CurrencyConversionSetup.State,
        stream: AsyncStream<FiatCurrencyCatalogState>,
        started: SignalledRecords<Void>
    ) -> TestStore<CurrencyConversionSetup.State, CurrencyConversionSetup.Action> {
        TestStore(initialState: state) {
            CurrencyConversionSetup()
        } withDependencies: {
            $0.fiatCurrencyCatalog.observe = { stream }
            $0.fiatCurrencyCatalog.ensureLoaded = { started.recordCall() }
        }
    }
}
