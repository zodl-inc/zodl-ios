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

            // WalletBalances renders the fiat row only when `isExchangeRateFeatureOn` is true, and that
            // flag is a one-shot snapshot taken in WalletBalances.onAppear. In the split-view layout the
            // sidebar balance is always visible and never re-appears, so onAppear can't pick up a change
            // made on the Settings screen — the value is fetched and stored but stays hidden behind the
            // stale gate. Mirror the disable poke in `.torDisableTapped` below: push the flag straight onto
            // homeState when currency conversion is enabled, from either the root-level setup (smart-banner
            // path) or the Settings stack. Both emit `.torInitSucceeded` once the rate fetch is armed.
            case .currencyConversionSetup(.torInitSucceeded):
                state.homeState.walletBalancesState.isExchangeRateFeatureOn = true
                return .none

            // [B4-10] Same split-view stale-gate class: on macOS the SmartBanner host is always
            // visible, so a banner currently OFFERING currency conversion stays open after the user
            // enables it in SETTINGS instead (iOS re-derives on Home onAppear; macOS never does).
            // Close-and-cleanup re-runs the banner priority chain, so the stale offer dismisses and
            // any other due banner re-surfaces. Mirrors the `.torDisableTapped` poke below.
            case .settings(.path(.element(id: _, action: .currencyConversionSetup(.torInitSucceeded)))):
                state.homeState.walletBalancesState.isExchangeRateFeatureOn = true
                return .send(.home(.smartBanner(.closeAndCleanupBanner)))

            // [B4-10 sweep] Tor variant of the same class: enabling Tor from Settings must also
            // dismiss a Tor-offer banner left open behind the Settings screen.
            case .settings(.path(.element(id: _, action: .torSetup(.torInitSucceeded)))):
                return .send(.home(.smartBanner(.closeAndCleanupBanner)))

            // Symmetric opt-out. Only the Settings layout can disable via `.saveChangesTapped` (the
            // root-level setup uses skip/enable and never emits `.settingsOptionChanged`), so without this
            // the gate would stay true after a Settings opt-out and the row would spin on "Loading…"
            // forever instead of disappearing.
            case .settings(.path(.element(id: _, action: .currencyConversionSetup(.settingsOptionChanged(.optOut))))):
                state.homeState.walletBalancesState.isExchangeRateFeatureOn = false
                return .none

            case .torInitFailed:
                state.alert = AlertState.torInitFailedRequest()
                return .none
                
            case .torDisableTapped:
                try? walletStorage.importTorSetupFlag(false)
                try? userStoredPreferences.setExchangeRate(.init(manual: false, automatic: false))
                state.$currencyConversion.withLock { $0 = nil }
                state.$swapAPIAccess.withLock { $0 = .direct }
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
