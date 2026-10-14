//
//  ChooseHWWalletStore.swift
//  Zashi
//
//  MOB-2020: which hardware wallet to connect. Home's Connect Hardware Wallet button, in the
//  Wallets & Hardware sheet, opens this chooser instead of jumping straight into the Keystone
//  flow, since a wallet can hold up to one Keystone AND one Ledger account.
//

import SwiftUI
import ComposableArchitecture

@Reducer
struct ChooseHWWallet {
    @ObservableState
    struct State: Equatable {
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        var isKeystoneConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .keystone {
                    return true
                }
            }

            return false
        }

        var isLedgerConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .ledger {
                    return true
                }
            }

            return false
        }

        init() { }
    }

    enum Action: Equatable {
        case closeTapped
        case keystoneTapped
        case ledgerTapped
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .none

            case .keystoneTapped:
                return .none

            case .ledgerTapped:
                return .none
            }
        }
    }
}
