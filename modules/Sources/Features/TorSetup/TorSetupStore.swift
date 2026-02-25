//
//  TorSetupStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-07-10.
//

import ComposableArchitecture
import ZcashLightClientKit

import SDKSynchronizer
import Generated
import WalletStorage
import Models
import UserPreferencesStorage

@Reducer
public struct TorSetup {
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
                case .optIn: return L10n.TorSetup.enableDesc
                case .optOut: return L10n.TorSetup.disableDesc
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
            case currencyConversion
            case transactions
            case integrations

            public func title() -> String {
                switch self {
                case .currencyConversion: return L10n.TorSetup.Option1.title
                case .transactions: return L10n.TorSetup.Option2.title
                case .integrations: return L10n.TorSetup.Option3.title
                }
            }

            public func subtitle() -> String {
                switch self {
                case .currencyConversion: return L10n.TorSetup.Option1.desc
                case .transactions: return L10n.TorSetup.Option2.desc
                case .integrations: return L10n.TorSetup.Option3.desc
                }
            }

            public func icon() -> ImageAsset {
                switch self {
                case .currencyConversion: return Asset.Assets.Icons.currencyDollar
                case .transactions: return Asset.Assets.Icons.sent
                case .integrations: return Asset.Assets.Icons.integrations
                }
            }
        }

        public var activeSettingsOption: SettingsOptions?
        public var currentSettingsOption = SettingsOptions.optOut
        public var isSettingsView: Bool = false

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
        case binding(BindingAction<TorSetup.State>)
        case disableTapped
        case enableTapped
        case onAppear
        case saveChangesTapped
        case settingsOptionChanged(State.SettingsOptions)
        case settingsOptionTapped(State.SettingsOptions)
        case torInitFailed
        case torInitSucceeded
    }

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
                if let torEnabled = walletStorage.exportTorSetupFlag(), torEnabled {
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
                try? walletStorage.importTorSetupFlag(true)
                return .run { send in
                    do {
                        try await sdkSynchronizer.torEnabled(true)
                    } catch {
                        await send(.torInitFailed)
                    }
                }

            case .settingsOptionChanged:
                return .none

            case .settingsOptionTapped(let newOption):
                state.currentSettingsOption = newOption
                return .none
                
            case .saveChangesTapped:
                let newFlag = state.currentSettingsOption == .optIn
                try? walletStorage.importTorSetupFlag(newFlag)
                state.activeSettingsOption = state.currentSettingsOption
                let currentSettingsOption = state.currentSettingsOption
                if state.currentSettingsOption == .optOut {
                    try? userStoredPreferences.setExchangeRate(.init(manual: false, automatic: false))
                }
                return .run { send in
                    await send(.settingsOptionChanged(currentSettingsOption))
                    if newFlag {
                        do {
                            try await sdkSynchronizer.torEnabled(newFlag)
                            await send(.torInitSucceeded)
                        } catch {
                            await send(.torInitFailed)
                        }
                    } else {
                        try? await sdkSynchronizer.torEnabled(newFlag)
                    }
                }

            case .disableTapped:
                try? walletStorage.importTorSetupFlag(false)
                return .run { _ in
                    try? await sdkSynchronizer.torEnabled(false)
                }
                
            case .torInitSucceeded:
                return .none
                
            case .torInitFailed:
                return .none
            }
        }
    }
}
