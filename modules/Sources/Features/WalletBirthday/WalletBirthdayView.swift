//
//  WalletBirthdayView.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-31-2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct WalletBirthdayView: View {
    @Perception.Bindable var store: StoreOf<WalletBirthday>
    
    public init(store: StoreOf<WalletBirthday>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.ImportWallet.Birthday.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)
                    .padding(.bottom, 8)

                Text(L10n.RestoreWallet.Birthday.info)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.bottom, 32)

                ZashiTextField(
                    text: $store.birthday,
                    placeholder: L10n.RestoreWallet.Birthday.placeholder,
                    title: L10n.RestoreWallet.Birthday.title
                )
                .padding(.bottom, 6)
                .keyboardType(.numberPad)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                
                Text(L10n.RestoreWallet.Birthday.fieldInfo)
                    .zFont(size: 12, style: Design.Text.tertiary)

                Spacer()
                
                ZashiButton(
                    L10n.RestoreWallet.Birthday.estimate,
                    type: .ghost
                ) {
                    store.send(.estimateHeightTapped)
                }
                .padding(.bottom, 12)

                ZashiButton(L10n.ImportWallet.Button.restoreWallet) {
                    store.send(.restoreTapped)
                }
                .disabled(!store.isValidBirthday)
                .padding(.bottom, 24)
            }
            .zashiBack()
        }
        .navigationBarTitleDisplayMode(.inline)
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
        .screenHorizontalPadding()
        .applyScreenBackground()
        .screenTitle(L10n.ImportWallet.Button.restoreWallet)
    }
}

// MARK: - Previews

#Preview {
    WalletBirthdayView(store: WalletBirthday.initial)
}

// MARK: - Store

extension WalletBirthday {
    public static var initial = StoreOf<WalletBirthday>(
        initialState: .initial
    ) {
        WalletBirthday()
    }
}

// MARK: - Placeholders

extension WalletBirthday.State {
    public static let initial = WalletBirthday.State()
}
