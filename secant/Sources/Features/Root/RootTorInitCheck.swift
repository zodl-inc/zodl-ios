//
//  RootTorInitCheck.swift
//  Zashi
//
//  Created by Lukáš Korba on 18.07.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func torInitCheckReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .observeTorInit:
                if let torEnabled = walletStorage.exportTorSetupFlag(), torEnabled {
                    return .run { send in
                        let isTorSuccessfullyInitialized = await sdkSynchronizer.isTorSuccessfullyInitialized()
                        
                        if let isTorSuccessfullyInitialized {
                            if !isTorSuccessfullyInitialized {
                                await send(.torInitFailed)
                            }
                        } else {
                            try? await mainQueue.sleep(for: .seconds(5))
                            await send(.observeTorInit)
                        }
                    }
                }
                return .none

            case .settings(.path(.element(id: _, action: .currencyConversionSetup(.torInitFailed)))):
                return .send(.torInitFailed)
                
            case .settings(.path(.element(id: _, action: .torSetup(.torInitFailed)))):
                return .send(.torInitFailed)

            case .torInitFailed:
                state.alert = AlertState.torInitFailedRequest()
                return .none
                
            case .torDisableTapped:
                try? walletStorage.importTorSetupFlag(false)
                try? userStoredPreferences.setExchangeRate(.init(manual: false, automatic: false))
                state.$currencyConversion.withLock { $0 = nil }
                state.homeState.walletBalancesState.isExchangeRateFeatureOn = false
                return .run { [state] send in
                    await send(.home(.smartBanner(.closeAndCleanupBanner)))
                    //try? await sdkSynchronizer.torEnabled(false)
                    
                    for (id, element) in zip(state.settingsState.path.ids, state.settingsState.path) {
                        if element.is(\.torSetup) {
                            await send(.settings(.path(.element(id: id, action: .torSetup(.settingsOptionTapped(.optOut))))))
                        }
                        if element.is(\.currencyConversionSetup) {
                            await send(.settings(.path(.element(id: id, action: .currencyConversionSetup(.settingsOptionTapped(.optOut))))))
                        }
                    }
                }

            case .torDontDisableTapped:
                return .none
                
            default: return .none
            }
        }
    }
}
