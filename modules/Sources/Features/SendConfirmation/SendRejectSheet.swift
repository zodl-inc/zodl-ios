//
//  SendRejectSheet.swift
//  modules
//
//  Created by Lukáš Korba on 11.02.2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

extension SignWithKeystoneView {
    @ViewBuilder func rejectSendContent(colorScheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.arrowUp.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)
                .padding(.bottom, 20)

            Text(L10n.KeystoneTransactionReject.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.bottom, 8)

            Text(L10n.KeystoneTransactionReject.msg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)

            ZashiButton(L10n.KeystoneTransactionReject.goBack) {
                store.send(.rejectRequestCanceled)
            }
            .padding(.bottom, 8)
            
            ZashiButton(
                L10n.KeystoneTransactionReject.rejectSig,
                type: .destructive2
            ) {
                store.send(.rejectTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}
