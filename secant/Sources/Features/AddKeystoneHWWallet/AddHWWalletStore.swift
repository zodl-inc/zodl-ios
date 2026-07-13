//
//  AddKeystoneHWWalletStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-26.
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import KeystoneSDK
@preconcurrency import ZcashLightClientKit

@Reducer
struct AddKeystoneHWWallet {
    @ObservableState
    struct State: Equatable {
        var isHelpSheetPresented = false
        var isInAppBrowserOn = false
        var isKSAccountSelected = false
        var randomSuccessIconIndex = 0
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        var zcashAccounts: ZcashAccounts?

        var inAppBrowserURL: String {
            "https://www.youtube.com/watch?v=pyN4UPwFIrM"
        }

        var keystoneAddress: String {
            @Dependency(\.derivationTool) var derivationTool
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

            if let zcashAccount = zcashAccounts?.accounts.first {
                do {
                    return try derivationTool.deriveUnifiedAddressFrom(zcashAccount.ufvk, zcashSDKEnvironment.network().networkType).stringEncoded
                } catch {
                    return ""
                }
            }
            
            return ""
        }
        
        var keystoneName: String {
            @Dependency(\.derivationTool) var derivationTool
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            
            if let zcashAccount = zcashAccounts?.accounts.first {
                return zcashAccount.name ?? String(localizable: .keystoneWallet)
            }
            
            return String(localizable: .keystoneWallet)
        }
        
        var successIlustration: Image {
            switch randomSuccessIconIndex {
            case 1: return Asset.Assets.Illustrations.success1.image
            default: return Asset.Assets.Illustrations.success2.image
            }
            
        }
        
        // [B4-4] `importAccount` can legitimately block for a long time while a restore is
        // syncing (the import write waits on the shared data.db behind the scan pass, and the
        // SDK restarts the sync pass afterwards). Surface the wait instead of a dead button.
        var isImportInFlight = false

        init() { }
    }

    enum Action: BindableAction, Equatable {
        case accountImported(AccountUUID)
        case accountImportFailed
        case accountImportSucceeded
        case accountTapped
        case backToHomeTapped
        case binding(BindingAction<AddKeystoneHWWallet.State>)
        case closeTapped
        case forgetThisDeviceTapped
        case helpSheetRequested
        case loadedWalletAccounts([WalletAccount], AccountUUID)
        case nextTapped
        case onAppear
        case readyToScanTapped
        case setBirthdayTapped
        case unlockTapped(BlockHeight?)
        case viewTutorialTapped
    }

    init() { }

    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.isKSAccountSelected = false
                state.zcashAccounts = nil
                state.randomSuccessIconIndex = Int.random(in: 1...2)
                state.isImportInFlight = false
                return .none
            
            case .backToHomeTapped:
                return .none

            case .closeTapped:
                return .none
                
            case .binding:
                return .none
                
            case .helpSheetRequested:
                state.isHelpSheetPresented.toggle()
                return .none

            case .accountTapped:
                state.isKSAccountSelected.toggle()
                return .none
                
            case .forgetThisDeviceTapped:
                return .none

            case .unlockTapped(let birthday):
                // [B4-4] Re-entry guard: repeated clicks while the import is waiting on the
                // busy data.db must not queue additional imports.
                guard !state.isImportInFlight else { return .none }
                guard let account = state.zcashAccounts, let firstAccount = account.accounts.first else {
                    return .none
                }
                state.isImportInFlight = true
                return .run { send in
                    do {
                        let uuid = try await sdkSynchronizer.importAccount(
                            firstAccount.ufvk,
                            AddKeystoneHWWallet.hexStringToBytes(account.seedFingerprint),
                            Zip32AccountIndex(firstAccount.index),
                            AccountPurpose.spending,
                            String(localizable: .accountsKeystone),
                            String(localizable: .accountsKeystone).lowercased(),
                            birthday
                        )
                        if let uuid {
                            await send(.accountImported(uuid))
                        }
                    } catch {
                        // TODO: error handling
                        await send(.accountImportFailed)
                    }
                }
                
            case .accountImported(let uuid):
                return .run { send in
                    let walletAccounts = try await sdkSynchronizer.walletAccounts()
                    await send(.loadedWalletAccounts(walletAccounts, uuid))
                    await send(.accountImportSucceeded)
                }
                
            case .accountImportFailed:
                state.isImportInFlight = false
                return .none

            case .accountImportSucceeded:
                state.isImportInFlight = false
                return .none

            case let .loadedWalletAccounts(walletAccounts, uuid):
                state.$walletAccounts.withLock { $0 = walletAccounts }
                for walletAccount in walletAccounts {
                    if walletAccount.id == uuid {
                        state.$selectedWalletAccount.withLock { $0 = walletAccount }
                        break
                    }
                }
                return .none
                
            case .nextTapped:
                return .none

            case .setBirthdayTapped:
                return .none

            case .readyToScanTapped:
                keystoneHandler.resetQRDecoder()
                return .none
                
            case .viewTutorialTapped:
                state.isInAppBrowserOn = true
                return .none
            }
        }
    }
}

extension AddKeystoneHWWallet {
    static func hexStringToBytes(_ hex: String) -> [UInt8]? {
        // Ensure the hex string has an even number of characters
        guard hex.count % 2 == 0 else { return nil }

        // Map pairs of hex characters to UInt8
        var byteArray = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            byteArray.append(byte)
            index = nextIndex
        }
        return byteArray
    }
}
