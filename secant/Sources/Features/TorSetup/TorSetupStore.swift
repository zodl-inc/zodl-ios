//
//  TorSetupStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-07-10.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct TorSetup {
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
                case .optIn: return String(localizable: .torSetupEnableDesc)
                case .optOut: return String(localizable: .torSetupDisableDesc)
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
            case currencyConversion
            case transactions
            case integrations

            func title() -> String {
                switch self {
                case .currencyConversion: return String(localizable: .torSetupOption1Title)
                case .transactions: return String(localizable: .torSetupOption2Title)
                case .integrations: return String(localizable: .torSetupOption3Title)
                }
            }

            func subtitle() -> String {
                switch self {
                case .currencyConversion: return String(localizable: .torSetupOption1Desc)
                case .transactions: return String(localizable: .torSetupOption2Desc)
                case .integrations: return String(localizable: .torSetupOption3Desc)
                }
            }

            func icon() -> ImageAsset {
                switch self {
                case .currencyConversion: return Asset.Assets.Icons.currencyDollar
                case .transactions: return Asset.Assets.Icons.sent
                case .integrations: return Asset.Assets.Icons.integrations
                }
            }
        }

        var activeSettingsOption: SettingsOptions?
        var currentSettingsOption = SettingsOptions.optOut
        var isSettingsView: Bool = false

        var isSaveButtonDisabled: Bool {
            currentSettingsOption == activeSettingsOption
        }
        
        init(
            activeSettingsOption: SettingsOptions? = nil,
            currentSettingsOption: SettingsOptions = .optOut,
            isSettingsView: Bool = false
        ) {
            self.activeSettingsOption = activeSettingsOption
            self.currentSettingsOption = currentSettingsOption
            self.isSettingsView = isSettingsView
        }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<TorSetup.State>)
        case backToHomeTapped
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

    init() { }

    var body: some Reducer<State, Action> {
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
                
            case .backToHomeTapped:
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
                    
                    await send(.backToHomeTapped)
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
