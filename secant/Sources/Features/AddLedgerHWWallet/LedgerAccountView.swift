//
//  LedgerAccountView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3. Mirrors AccountsSelectionView (Keystone's account-confirmation screen):
//  one row for the single paired account, a selection toggle, and Next.
//

import SwiftUI
import ComposableArchitecture

struct LedgerAccountView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.ledgerTitleLogo.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .padding(.top, 16)

                Text(localizable: .keystoneAddHWWalletTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: .keystoneAddHWWalletDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                accountView()
                    .padding(.top, 48)

                Spacer()

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.nextTapped)
                }
                .padding(.bottom, 24)
                .disabled(!store.isAccountSelected)
            }
            .screenHorizontalPadding()
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
        }
        .applyScreenBackground()
    }

    @ViewBuilder private func accountView() -> some View {
        WithPerceptionTracking {
            Button {
                store.send(.accountTapped)
            } label: {
                HStack(spacing: 0) {
                    Asset.Assets.Partners.ledgerMark.image
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(8)
                        .background {
                            Circle()
                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        }
                        .padding(.trailing, 8)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizable: .accountsLedger)
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)

                        Text(store.pairedAddress.zip316)
                            .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
                    }

                    Spacer()

                    ZashiToggle(
                        isOn: $store.isAccountSelected
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
            }
        }
    }
}
