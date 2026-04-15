//
//  CurrencyConversionSetupStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-12-2024
//

import ComposableArchitecture

import Generated
import ExchangeRate
import UserPreferencesStorage
import Models
import WalletStorage
import SDKSynchronizer

@Reducer
public struct CurrencyConversionSetup {
    @ObservableState
    public struct State: Equatable {
        public enum SettingsOptions: CaseIterable {
            case optIn
            case optOut
            
            public func title() -> String {
                switch self {
                case .optIn: return String(localizable: .currencyConversionEnable)
                case .optOut: return String(localizable: .currencyConversionLearnMoreOptionDisable)
                }
            }

            public func subtitle() -> String {
                switch self {
                case .optIn: return String(localizable: .currencyConversionLearnMoreOptionEnableDesc)
                case .optOut: return String(localizable: .currencyConversionLearnMoreOptionDisableDesc)
                }
            }
            
            public func icon() -> ImageAsset {
                switch self {
                case .optIn: return Asset.Assets.check
                case .optOut: return Asset.Assets.buttonCloseX
                }
            }
        }
        
        public enum LearnMoreOptions: CaseIterable {
            case ipAddress
            case refresh
            
            public func title() -> String {
                switch self {
                case .ipAddress: return String(localizable: .currencyConversionIpTitle)
                case .refresh: return String(localizable: .currencyConversionRefresh)
                }
            }

            public func subtitle() -> String {
                switch self {
                case .ipAddress: return String(localizable: .currencyConversionIpDesc)
                case .refresh: return String(localizable: .currencyConversionRefreshDesc)
                }
            }

            public func icon() -> ImageAsset {
                switch self {
                case .ipAddress: return Asset.Assets.shieldTick
                case .refresh: return Asset.Assets.refreshCCW
                }
            }
        }

        public var activeSettingsOption: SettingsOptions?
        @Shared(.inMemory(.exchangeRate)) public var currencyConversion: CurrencyConversion? = nil
        public var currentSettingsOption = SettingsOptions.optOut
        public var initialCurrency: CurrencyISO4217 = .usd
        public var isSettingsView: Bool = false
        public var isTorOn = false
        public var isTorSheetPresented = false
        public var selectedCurrency: CurrencyISO4217 = .usd

        public var isSaveButtonDisabled: Bool {
            currentSettingsOption == activeSettingsOption && selectedCurrency == initialCurrency
        }

        public init(
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
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<CurrencyConversionSetup.State>)
        case backToHomeTapped
        case currencyChanged(CurrencyISO4217)
        case delayedDismisalRequested
        case enableTapped
        case enableTorTapped
        case laterTapped
        case onAppear
        case saveChangesTapped
        case settingsOptionChanged(State.SettingsOptions)
        case settingsOptionTapped(State.SettingsOptions)
        case skipTapped
        case torInitFailed
        case torInitSucceeded
    }

    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage

    public init() { }

    public var body: some Reducer<State, Action> {
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
                
            case .backToHomeTapped:
                return .none

            case .binding:
                return .none

            case .currencyChanged(let currency):
                state.selectedCurrency = currency
                return .none

            case .enableTapped:
                try? userStoredPreferences.setExchangeRate(.init(manual: true, automatic: true, currency: state.selectedCurrency))
                return .run { send in
                    do {
                        try await sdkSynchronizer.exchangeRateEnabled(true)
                        await send(.torInitSucceeded)
                    } catch {
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
                return .run { send in
                    await send(.settingsOptionChanged(option))
                    
                    do {
                        try await sdkSynchronizer.exchangeRateEnabled(enabled)
                        if enabled {
                            await send(.torInitSucceeded)
                        }
                    } catch {
                        await send(.torInitFailed)
                    }
                    
                    await send(.backToHomeTapped)
                }

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
                exchangeRate.refreshExchangeRateUSD()
                return .none
            }
        }
    }
}
