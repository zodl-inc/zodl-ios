//
//  AddKeystoneHWWalletStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-26.
//

import SwiftUI
import ComposableArchitecture
import Generated
import KeystoneSDK
import Models
import SDKSynchronizer
import ZcashLightClientKit
import DerivationTool
import ZcashSDKEnvironment
import KeystoneHandler

@Reducer
public struct AddKeystoneHWWallet {
    @ObservableState
    public struct State: Equatable {
        public var isInAppBrowserOn = false
        public var isKSAccountSelected = false
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) public var walletAccounts: [WalletAccount] = []
        public var zcashAccounts: ZcashAccounts?

        public var inAppBrowserURL: String {
            "https://www.youtube.com/watch?v=pyN4UPwFIrM"
        }

        public var keystoneAddress: String {
            @Dependency(\.derivationTool) var derivationTool
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

            if let zcashAccount = zcashAccounts?.accounts.first {
                do {
                    return try derivationTool.deriveUnifiedAddressFrom(zcashAccount.ufvk, zcashSDKEnvironment.network.networkType).stringEncoded
                } catch {
                    return ""
                }
            }
            
            return ""
        }
        
        public init(
        ) {
        }
    }

    public enum Action: BindableAction, Equatable {
        case accountImported(AccountUUID)
        case accountImportFailed
        case accountImportSucceeded
        case accountTapped
        case backToHomeTapped
        case binding(BindingAction<AddKeystoneHWWallet.State>)
        case forgetThisDeviceTapped
        case loadedWalletAccounts([WalletAccount], AccountUUID)
        case onAppear
        case readyToScanTapped
        case unlockTapped
        case viewTutorialTapped
    }

    public init() { }

    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    public var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isKSAccountSelected = false
                state.zcashAccounts = nil
                return .none
            
            case .backToHomeTapped:
                return .none
                
            case .binding:
                return .none
                
            case .accountTapped:
                state.isKSAccountSelected.toggle()
                return .none
                
            case .forgetThisDeviceTapped:
                return .none

            case .unlockTapped:
                guard let account = state.zcashAccounts, let firstAccount = account.accounts.first else {
                    return .none
                }
                return .run { send in
                    do {
                        let uuid = try await sdkSynchronizer.importAccount(
                            firstAccount.ufvk,
                            AddKeystoneHWWallet.hexStringToBytes(account.seedFingerprint),
                            Zip32AccountIndex(firstAccount.index),
                            AccountPurpose.spending,
                            L10n.Accounts.keystone,
                            L10n.Accounts.keystone.lowercased()
                        )
                        if let uuid {
                            await send(.accountImported(uuid))
                            await send(.accountImportSucceeded)
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
                }
                
            case .accountImportFailed:
                return .none
                
            case .accountImportSucceeded:
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
