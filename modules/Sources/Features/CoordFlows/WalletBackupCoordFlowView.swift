//
//  WalletBackupCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-04-18.
//

import SwiftUI
import ComposableArchitecture

import UIComponents
import RecoveryPhraseDisplay
import Generated

// Path

public struct WalletBackupCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<WalletBackupCoordFlow>

    public init(store: StoreOf<WalletBackupCoordFlow>) {
        self.store = store
    }
    
    public var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                RecoveryPhraseSecurityView(
                    store:
                        store.scope(
                            state: \.recoveryPhraseDisplayState,
                            action: \.recoveryPhraseDisplay
                        )
                )
                .zashiBack() { store.send(.backToHomeTapped) }
                .screenTitle(L10n.RecoveryPhraseDisplay.screenTitle.uppercased())
            } destination: { store in
                switch store.case {
                case let .phrase(store):
                    RecoveryPhraseDisplayView(store: store)
                }
            }
        }
        .padding(.horizontal, 4)
        .applyScreenBackground()
    }
}

#Preview {
    NavigationView {
        WalletBackupCoordFlowView(store: WalletBackupCoordFlow.placeholder)
    }
}

// MARK: - Placeholders

extension WalletBackupCoordFlow.State {
    public static let initial = WalletBackupCoordFlow.State()
}

extension WalletBackupCoordFlow {
    public static let placeholder = StoreOf<WalletBackupCoordFlow>(
        initialState: .initial
    ) {
        WalletBackupCoordFlow()
    }
}
