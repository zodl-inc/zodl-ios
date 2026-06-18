//
//  WalletBackupCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-04-18.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct WalletBackupCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @PlatformBindable var store: StoreOf<WalletBackupCoordFlow>

    init(store: StoreOf<WalletBackupCoordFlow>) {
        self.store = store
    }
    
    var body: some View {
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
                .screenTitle(String(localizable: .recoveryPhraseDisplayScreenTitle).uppercased())
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
    static var initial: WalletBackupCoordFlow.State { WalletBackupCoordFlow.State() }
}

extension WalletBackupCoordFlow {
    @MainActor static let placeholder = StoreOf<WalletBackupCoordFlow>(
        initialState: .initial
    ) {
        WalletBackupCoordFlow()
    }
}
