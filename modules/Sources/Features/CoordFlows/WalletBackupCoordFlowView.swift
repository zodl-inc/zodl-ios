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
                .navigationBarHidden(true)
            } destination: { store in
                switch store.case {
                case let .phrase(store):
                    RecoveryPhraseDisplayView(store: store)
                }
            }
            .navigationBarHidden(!store.path.isEmpty)
            .navigationBarItems(
                trailing:
                    Button {
                        store.send(.helpSheetRequested)
                    } label: {
                        Asset.Assets.Icons.help.image
                            .zImage(size: 24, style: Design.Text.primary)
                            .padding(Design.Spacing.navBarButtonPadding)
                    }
            )
            .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                helpSheetContent()
            }
        }
        .padding(.horizontal, 4)
        .applyScreenBackground()
        .zashiBack()
        .screenTitle(L10n.RecoveryPhraseDisplay.screenTitle.uppercased())
    }
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(spacing: 0) {
            Text(L10n.RestoreWallet.Help.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)
            
            infoContent(text: L10n.RestoreWallet.Help.phrase)
                .padding(.bottom, 12)
            
            infoContent(text: L10n.RestoreWallet.Help.birthday)
                .padding(.bottom, 32)
            
            ZashiButton(L10n.General.ok.uppercased()) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func infoContent(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoCircle.image
                .zImage(size: 20, style: Design.Text.primary)
            
            if let attrText = try? AttributedString(
                markdown: text,
                including: \.zashiApp
            ) {
                ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
