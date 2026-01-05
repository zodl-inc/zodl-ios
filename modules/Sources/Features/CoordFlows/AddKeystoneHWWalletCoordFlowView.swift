//
//  AddKeystoneHWWalletCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-19.
//

import SwiftUI
import ComposableArchitecture

import UIComponents
import Generated

// Path
import AddKeystoneHWWallet
import Scan

public struct AddKeystoneHWWalletCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<AddKeystoneHWWalletCoordFlow>
    let tokenName: String

    public init(store: StoreOf<AddKeystoneHWWalletCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                AddKeystoneHWWalletView(
                    store:
                        store.scope(
                            state: \.addKeystoneHWWalletState,
                            action: \.addKeystoneHWWallet
                        )
                )
//                .navigationBarHidden(true)
            } destination: { store in
                switch store.case {
                case let .accountHWWalletSelection(store):
                    AccountsSelectionView(store: store)
                case let .scan(store):
                    ScanView(store: store)
                }
            }
//            .navigationBarHidden(!store.path.isEmpty)
        }
        .applyScreenBackground()
        .zashiBack()
    }
}

#Preview {
    NavigationView {
        AddKeystoneHWWalletCoordFlowView(store: AddKeystoneHWWalletCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension AddKeystoneHWWalletCoordFlow.State {
    public static let initial = AddKeystoneHWWalletCoordFlow.State()
}

extension AddKeystoneHWWalletCoordFlow {
    public static let placeholder = StoreOf<AddKeystoneHWWalletCoordFlow>(
        initialState: .initial
    ) {
        AddKeystoneHWWalletCoordFlow()
    }
}
