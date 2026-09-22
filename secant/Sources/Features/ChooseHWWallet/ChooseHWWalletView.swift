//
//  ChooseHWWalletView.swift
//  Zashi
//
//  MOB-2020.
//

import SwiftUI
import ComposableArchitecture

struct ChooseHWWalletView: View {
    @Perception.Bindable var store: StoreOf<ChooseHWWallet>

    init(store: StoreOf<ChooseHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .keystoneConnect)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: .hwWalletChooserDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                if !store.isKeystoneConnected {
                    cardButton(Asset.Assets.Partners.keystoneCard.image) {
                        store.send(.keystoneTapped)
                    }
                    .padding(.top, 24)
                }

                if !store.isLedgerConnected {
                    cardButton(Asset.Assets.Partners.ledgerCard.image) {
                        store.send(.ledgerTapped)
                    }
                    .padding(.top, 16)
                }

                Spacer()
            }
            .screenHorizontalPadding()
            .zashiBackV2(background: false) {
                store.send(.closeTapped)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }

    @ViewBuilder private func cardButton(_ image: Image, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 148)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius._4xl))
        }
    }
}

// MARK: Placeholders

extension ChooseHWWallet.State {
    static var initial: ChooseHWWallet.State { ChooseHWWallet.State() }
}

extension ChooseHWWallet {
    @MainActor static let initial = StoreOf<ChooseHWWallet>(
        initialState: .initial
    ) {
        ChooseHWWallet()
    }
}

#Preview {
    NavigationView {
        ChooseHWWalletView(store: ChooseHWWallet.initial)
    }
}
