//
//  DisconnectHWWalletStore.swift
//  Zodl
//
//  Created by Lukáš Korba on 2026-04-02
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import MessageUI

@Reducer
struct DisconnectHWWallet {
    @ObservableState
    struct State: Equatable {
        var isProcessing = false
        var isFailureSheetUp = false
        var isSheetUp = false
        var selectedVendor: WalletAccount.Vendor?
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        // support
        var canSendMail = false
        var errMsg = ""
        var messageToBeShared: String?
        var supportData: SupportData?

        /// The connected hardware vendors, keystone before ledger — the fixed order both the
        /// card list and `onAppear`'s single-vendor preselection rely on. `.zcash` (the default,
        /// non-hardware vendor) never appears here.
        var connectedHWVendors: [WalletAccount.Vendor] {
            var vendors: [WalletAccount.Vendor] = []
            if walletAccounts.contains(where: { $0.vendor == .keystone }) {
                vendors.append(.keystone)
            }
            if walletAccounts.contains(where: { $0.vendor == .ledger }) {
                vendors.append(.ledger)
            }
            return vendors
        }

        init(isProcessing: Bool = false) {
            self.isProcessing = isProcessing
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<DisconnectHWWallet.State>)
        case contactSupport
        case disconnectConfirmed
        case disconnectFailed(String)
        case disconnectFinished
        case disconnectTapped
        case dismissSheet
        case onAppear
        case sendSupportMailFinished
        case shareFinished
        case tryAgain
        case vendorTapped(WalletAccount.Vendor)
    }

    @Dependency(\.ledgerClient) var ledgerClient
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // TCA Store is @MainActor; reducer body always runs on main.
                state.canSendMail = MainActor.assumeIsolated { MFMailComposeViewController.canSendMail() }
                // Only one hardware vendor connected -> nothing to choose, preselect it. With
                // both connected the user picks a card (`vendorTapped`), so nothing is preselected.
                if state.connectedHWVendors.count == 1 {
                    state.selectedVendor = state.connectedHWVendors.first
                }
                return .none

            case .binding:
                return .none

            case .vendorTapped(let vendor):
                state.selectedVendor = vendor
                return .none

            case .disconnectTapped:
                guard state.selectedVendor != nil else {
                    return .none
                }
                state.isSheetUp = true
                state.isProcessing = true
                return .none

            case .disconnectConfirmed:
                state.isSheetUp = false
                guard let selectedVendor = state.selectedVendor else {
                    return .none
                }
                guard let account = state.walletAccounts.first(where: { $0.vendor == selectedVendor }) else {
                    return .none
                }
                return .run { send in
                    do {
                        try await sdkSynchronizer.deleteAccount(account.id)
                        // Ledger carries state Keystone doesn't: the keychain binding (device
                        // identity + ZIP 32 index) and per-account encryption keys, and an open
                        // Bluetooth link. Only unwind those once the account delete itself has
                        // actually gone through -- a failed delete must leave the binding in place
                        // so `tryAgain` still has something to retry against.
                        if selectedVendor == .ledger {
                            try? walletStorage.deleteLedgerBinding(account.id)
                            try? walletStorage.clearEncryptionKeys(account.account)
                            await ledgerClient.disconnect()
                        }
                        await send(.disconnectFinished)
                    } catch {
                        await send(.disconnectFailed(error.localizedDescription))
                    }
                }

            case .disconnectFailed(let errMsg):
                state.isProcessing = false
                state.isFailureSheetUp = true
                state.errMsg = errMsg
                return .none

            case .disconnectFinished:
                state.isProcessing = false
                return .none

            case .dismissSheet:
                state.isSheetUp = false
                state.isProcessing = false
                return .none
                
            case .tryAgain:
                state.isFailureSheetUp = false
                return .run { send in
                    try? await Task.sleep(for: .seconds(0.3))
                    await send(.disconnectConfirmed)
                }

            case .contactSupport:
                state.isFailureSheetUp = false
                let prefixMessage = "\(state.errMsg)\n\n"
                if state.canSendMail {
                    state.supportData = SupportDataGenerator.generate(prefixMessage)
                    return .none
                } else {
                    let sharePrefix =
                    """
                    ===
                    \(String(localizable: .sendFeedbackShareNotAppleMailInfo)) \(SupportDataGenerator.Constants.email)
                    ===
                    
                    \(prefixMessage)
                    """
                    let supportData = SupportDataGenerator.generate(sharePrefix)
                    state.messageToBeShared = supportData.message
                }
                return .none

            case .sendSupportMailFinished:
                state.supportData = nil
                return .none

            case .shareFinished:
                state.messageToBeShared = nil
                return .none
            }
        }
    }
}
