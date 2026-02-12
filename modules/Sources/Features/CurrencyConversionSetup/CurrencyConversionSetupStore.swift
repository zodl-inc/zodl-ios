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
                case .optIn: return L10n.CurrencyConversion.enable
                case .optOut: return L10n.CurrencyConversion.learnMoreOptionDisable
                }
            }

            public func subtitle() -> String {
                switch self {
                case .optIn: return L10n.CurrencyConversion.learnMoreOptionEnableDesc
                case .optOut: return L10n.CurrencyConversion.learnMoreOptionDisableDesc
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
                case .ipAddress: return L10n.CurrencyConversion.ipTitle
                case .refresh: return L10n.CurrencyConversion.refresh
                }
            }

            public func subtitle() -> String {
                switch self {
                case .ipAddress: return L10n.CurrencyConversion.ipDesc
                case .refresh: return L10n.CurrencyConversion.refreshDesc
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
        public var isSettingsView: Bool = false
        public var isTorOn = false
        public var isTorSheetPresented = false

        public var isSaveButtonDisabled: Bool {
            currentSettingsOption == activeSettingsOption
        }
        
        public init(
            activeSettingsOption: SettingsOptions? = nil,
            currentSettingsOption: SettingsOptions = .optOut,
            isSettingsView: Bool = false
        ) {
            self.activeSettingsOption = activeSettingsOption
            self.currentSettingsOption = currentSettingsOption
            self.isSettingsView = isSettingsView
        }
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<CurrencyConversionSetup.State>)
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
                if let automatic = userStoredPreferences.exchangeRate()?.automatic, automatic {
                    state.activeSettingsOption = .optIn
                    state.currentSettingsOption = .optIn
                } else {
                    state.activeSettingsOption = .optOut
                    state.currentSettingsOption = .optOut
                }
                return .none
                
            case .binding:
                return .none
                
            case .enableTapped:
                try? userStoredPreferences.setExchangeRate(.init(manual: true, automatic: true))
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
                try? userStoredPreferences.setExchangeRate(UserPreferencesStorage.ExchangeRate(manual: true, automatic: state.currentSettingsOption == .optIn))
                state.activeSettingsOption = state.currentSettingsOption
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
                }

            case .skipTapped:
                try? userStoredPreferences.setExchangeRate(.init(manual: false, automatic: false))
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
