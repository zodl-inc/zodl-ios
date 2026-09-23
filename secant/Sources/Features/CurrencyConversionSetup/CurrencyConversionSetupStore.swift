//
//  CurrencyConversionSetupStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-12-2024
//

import ComposableArchitecture

@Reducer
struct CurrencyConversionSetup {
    @ObservableState
    struct State: Equatable {
        enum SettingsOptions: CaseIterable {
            case optIn
            case optOut
            
            func title() -> String {
                switch self {
                case .optIn: return String(localizable: .currencyConversionEnable)
                case .optOut: return String(localizable: .currencyConversionLearnMoreOptionDisable)
                }
            }

            func subtitle() -> String {
                switch self {
                case .optIn: return String(localizable: .currencyConversionLearnMoreOptionEnableDesc)
                case .optOut: return String(localizable: .currencyConversionLearnMoreOptionDisableDesc)
                }
            }
            
            func icon() -> ImageAsset {
                switch self {
                case .optIn: return Asset.Assets.check
                case .optOut: return Asset.Assets.buttonCloseX
                }
            }
        }
        
        enum LearnMoreOptions: CaseIterable {
            case ipAddress
            case refresh
            
            func title() -> String {
                switch self {
                case .ipAddress: return String(localizable: .currencyConversionIpTitle)
                case .refresh: return String(localizable: .currencyConversionRefresh)
                }
            }

            func subtitle() -> String {
                switch self {
                case .ipAddress: return String(localizable: .currencyConversionIpDesc)
                case .refresh: return String(localizable: .currencyConversionRefreshDesc)
                }
            }

            func icon() -> ImageAsset {
                switch self {
                case .ipAddress: return Asset.Assets.shieldTick
                case .refresh: return Asset.Assets.refreshCCW
                }
            }
        }

        var activeSettingsOption: SettingsOptions?
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion? = nil
        var catalog = FiatCurrencyCatalogState()
        var currentSettingsOption = SettingsOptions.optOut
        var initialCurrency: CurrencyISO4217 = .usd
        var isCurrencyPickerSheetPresented = false
        var isSettingsView: Bool = false
        var isTorOn = false
        var isTorSheetPresented = false
        var selectedCurrency: CurrencyISO4217 = .usd

        var isSaveButtonDisabled: Bool {
            currentSettingsOption == activeSettingsOption && selectedCurrency == initialCurrency
        }

        init(
            activeSettingsOption: SettingsOptions? = nil,
            currentSettingsOption: SettingsOptions = .optOut,
            isSettingsView: Bool = false,
            selectedCurrency: CurrencyISO4217 = .usd
        ) {
            self.activeSettingsOption = activeSettingsOption
            self.currentSettingsOption = currentSettingsOption
            self.isSettingsView = isSettingsView
            self.selectedCurrency = selectedCurrency
            self.initialCurrency = selectedCurrency
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<CurrencyConversionSetup.State>)
        case backToHomeTapped
        case currencyCatalogUpdated(FiatCurrencyCatalogState)
        case currencyChanged(CurrencyISO4217)
        case currencyPickerDismissed
        case currencyPickerTask
        case currencyPickerTapped
        case delayedDismisalRequested
        case enableTapped
        case enableTorTapped
        case laterTapped
        case onAppear
        case retryCurrenciesTapped
        case saveChangesTapped
        case settingsOptionChanged(State.SettingsOptions)
        case settingsOptionTapped(State.SettingsOptions)
        case skipTapped
        case torInitFailed
        case torInitSucceeded
    }

    private enum CancelID {
        case catalogObservation
    }

    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.fiatCurrencyCatalog)
    var fiatCurrencyCatalog
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.isTorOn = walletStorage.exportTorSetupFlag() ?? false
                let savedExchangeRate = userStoredPreferences.exchangeRate()
                if let automatic = savedExchangeRate?.automatic, automatic {
                    state.activeSettingsOption = .optIn
                    state.currentSettingsOption = .optIn
                } else {
                    state.activeSettingsOption = .optOut
                    state.currentSettingsOption = .optOut
                }
                let currency = savedExchangeRate?.currency ?? .usd
                state.selectedCurrency = currency
                state.initialCurrency = currency
                return .none

            case .retryCurrenciesTapped:
                return .run { _ in
                    await fiatCurrencyCatalog.refresh()
                }

            case .backToHomeTapped:
                return .none

            case .binding(\.isCurrencyPickerSheetPresented):
                return state.isCurrencyPickerSheetPresented
                    ? .none
                    : .cancel(id: CancelID.catalogObservation)

            case .binding:
                return .none

            case .currencyCatalogUpdated(let snapshot):
                state.catalog = snapshot
                return .none

            case .currencyChanged(let currency):
                state.selectedCurrency = currency
                state.isCurrencyPickerSheetPresented = false
                return .cancel(id: CancelID.catalogObservation)

            case .currencyPickerDismissed:
                state.isCurrencyPickerSheetPresented = false
                return .cancel(id: CancelID.catalogObservation)

            case .currencyPickerTask:
                return .run { send in
                    let snapshots = await fiatCurrencyCatalog.observe()
                    await fiatCurrencyCatalog.ensureLoaded()
                    for await snapshot in snapshots {
                        await send(.currencyCatalogUpdated(snapshot))
                    }
                }
                .cancellable(id: CancelID.catalogObservation, cancelInFlight: true)

            case .currencyPickerTapped:
                state.isCurrencyPickerSheetPresented = true
                return .none

            case .enableTapped:
                try? userStoredPreferences.setExchangeRate(
                    UserPreferencesStorage.ExchangeRate(manual: true, automatic: true, currency: state.selectedCurrency)
                )
                let update = startExchangeRateUpdate(enabled: true, currency: state.selectedCurrency)
                return .run { send in
                    do {
                        try await update.value
                        guard !Task.isCancelled else { return }
                        await send(.torInitSucceeded)
                    } catch {
                        guard !Task.isCancelled else { return }
                        await send(.torInitFailed)
                    }
                }

            case .settingsOptionChanged(let option):
                if option == .optOut {
                    state.$currencyConversion.withLock { $0 = nil }
                }
                return .none

            case .settingsOptionTapped(let newOption):
                state.currentSettingsOption = newOption
                return .none
                
            case .saveChangesTapped:
                try? userStoredPreferences.setExchangeRate(
                    UserPreferencesStorage.ExchangeRate(manual: true, automatic: state.currentSettingsOption == .optIn, currency: state.selectedCurrency)
                )
                state.activeSettingsOption = state.currentSettingsOption
                state.initialCurrency = state.selectedCurrency
                let option = state.currentSettingsOption
                let enabled = state.currentSettingsOption == .optIn
                let update = startExchangeRateUpdate(enabled: enabled, currency: state.selectedCurrency)
                return .concatenate(.send(.settingsOptionChanged(option)), .run { send in
                    do {
                        try await update.value
                        guard !Task.isCancelled else { return }
                        if enabled {
                            await send(.torInitSucceeded)
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        await send(.torInitFailed)
                    }
                    
                    guard !Task.isCancelled else { return }
                    await send(.backToHomeTapped)
                })

            case .skipTapped:
                try? userStoredPreferences.setExchangeRate(.init(manual: false, automatic: false, currency: state.selectedCurrency))
                return .none
                
            case .enableTorTapped:
                state.isTorSheetPresented = false
                try? walletStorage.importTorSetupFlag(true)
                return .run { send in
                    await send(.saveChangesTapped)
                    do {
                        //try await sdkSynchronizer.torEnabled(true)
                        try? await mainQueue.sleep(for: .seconds(0.2))
                        await send(.delayedDismisalRequested)
                    } catch {
                        await send(.torInitFailed)
                    }
                }

            case .delayedDismisalRequested:
                return .none
                
            case .laterTapped:
                state.isTorSheetPresented = false
                return .none
                
            case .torInitFailed:
                return .none
                
            case .torInitSucceeded:
                return .none
            }
        }
    }

    private func startExchangeRateUpdate(enabled: Bool, currency: CurrencyISO4217) -> Task<Void, Error> {
        @Shared(.inMemory(.swapAPIAccess)) var access: WalletStorage.SwapAPIAccess = .direct
        let waitsForSDK = access != .direct
        let sdkSynchronizer = self.sdkSynchronizer
        let exchangeRate = enabled ? self.exchangeRate : nil
        let userStoredPreferences = enabled ? self.userStoredPreferences : nil

        if enabled && !waitsForSDK {
            exchangeRate?.refreshExchangeRateUSD()
        }

        // The saved update must finish even if the settings screen disappears.
        return Task {
            try await sdkSynchronizer.exchangeRateEnabled(enabled)
            guard enabled,
                  waitsForSDK,
                  let saved = userStoredPreferences?.exchangeRate(),
                  saved.automatic,
                  saved.currency == currency else {
                return
            }
            exchangeRate?.refreshExchangeRateUSD()
        }
    }
}
