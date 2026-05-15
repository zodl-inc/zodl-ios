//
//  RequestPaymentConfirmationView.swift
//  Zashi
//
//  Created by Lukáš Korba on 28.11.2023.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct RequestPaymentConfirmationView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<SendConfirmation>
    let tokenName: String
    
    init(store: StoreOf<SendConfirmation>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    // requested amount
                    VStack(spacing: 0) {
                        BalanceWithIconView(balance: store.amount)
                        
                        Text(store.currencyAmount.data)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            .padding(.top, 10)
                    }
                    .screenHorizontalPadding()
                    .padding(.top, 40)
                    .padding(.bottom, 24)

                    // requested by
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(localizable: .sendRequestPaymentRequestedBy)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)

                            if let alias = store.alias {
                                Text(alias)
                                    .zFont(.medium, size: 14, style: Design.Inputs.Filled.label)
                            }
                            
                            Text(store.addressToShow)
                                .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.primary)
                        }
                        
                        Spacer()
                    }
                    .screenHorizontalPadding()
                    .padding(.bottom, 16)

                    if !store.isTransparentAddress || store.alias == nil {
                        HStack(spacing: 0) {
                            if !store.isTransparentAddress {
                                if store.isAddressExpanded {
                                    ZashiButton(
                                        String(localizable: .generalHide),
                                        type: .tertiary,
                                        infinityWidth: false,
                                        prefixView:
                                            Asset.Assets.chevronDown.image
                                            .zImage(size: 20, style: Design.Btns.Tertiary.fg)
                                            .rotationEffect(Angle(degrees: 180))
                                    ) {
                                        store.send(.showHideButtonTapped)
                                    }
                                    .padding(.trailing, 12)
                                } else {
                                    ZashiButton(
                                        String(localizable: .generalShow),
                                        type: .tertiary,
                                        infinityWidth: false,
                                        prefixView:
                                            Asset.Assets.chevronDown.image
                                            .zImage(size: 20, style: Design.Btns.Tertiary.fg)
                                    ) {
                                        store.send(.showHideButtonTapped)
                                    }
                                    .padding(.trailing, 12)
                                }
                            }
                            
                            if store.alias == nil {
                                ZashiButton(
                                    String(localizable: .generalSave),
                                    type: .tertiary,
                                    infinityWidth: false,
                                    prefixView:
                                        Asset.Assets.Icons.userPlus.image
                                        .zImage(size: 20, style: Design.Btns.Tertiary.fg)
                                ) {
                                    store.send(.saveAddressTapped(store.address.redacted))
                                }
                            }
                            
                            Spacer()
                        }
                        .screenHorizontalPadding()
                        .padding(.bottom, 24)
                    }

                    // Sending from
                    if store.walletAccounts.count > 1 {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(localizable: .accountsSendingFrom)
                                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                                
                                if let selectedWalletAccount = store.selectedWalletAccount {
                                    HStack(spacing: 0) {
                                        selectedWalletAccount.vendor.icon()
                                            .resizable()
                                            .frame(width: 24, height: 24)
                                            .background {
                                                Circle()
                                                    .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                                    .frame(width: 32, height: 32)
                                            }
                                        
                                        Text(selectedWalletAccount.vendor.name())
                                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                            .padding(.leading, 16)
                                    }
                                    .padding(.top, 8)
                                }
                            }
                            
                            Spacer()
                        }
                        .screenHorizontalPadding()
                        .padding(.bottom, 20)
                    }
                    
                    if !store.message.isEmpty {
                        VStack(alignment: .leading) {
                            Text(localizable: .sendRequestPaymentFor)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)

                            HStack {
                                Text(store.message)
                                    .zFont(.medium, size: 14, style: Design.Inputs.Filled.text)
                                
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._lg)
                                    .fill(Design.Inputs.Filled.bg.color(colorScheme))
                            }
                        }
                        .screenHorizontalPadding()
                        .padding(.bottom, 40)
                    }
                    
                    HStack {
                        Text(localizable: .sendFeeSummary)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        
                        Spacer()

                        ZatoshiRepresentationView(
                            balance: store.feeRequired,
                            fontName: FontFamily.Inter.semiBold.name,
                            mostSignificantFontSize: 14,
                            leastSignificantFontSize: 7,
                            format: .expanded
                        )
                        .padding(.trailing, 4)
                    }
                    .screenHorizontalPadding()
                    .padding(.bottom, 20)
                    
                    HStack {
                        Text(localizable: .sendRequestPaymentTotal)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        
                        Spacer()

                        ZatoshiRepresentationView(
                            balance: store.amount + store.feeRequired,
                            fontName: FontFamily.Inter.semiBold.name,
                            mostSignificantFontSize: 14,
                            leastSignificantFontSize: 7,
                            format: .expanded
                        )
                        .padding(.trailing, 4)
                    }
                    .screenHorizontalPadding()
                    .padding(.bottom, 20)
                }
                .padding(.vertical, 1)
                .alert($store.scope(state: \.alert, action: \.alert))
                
                Spacer()
                
                if let vendor = store.selectedWalletAccount?.vendor, vendor == .keystone {
                    ZashiButton(String(localizable: .keystoneConfirm)) {
                        store.send(.confirmWithKeystoneTapped)
                    }
                    .screenHorizontalPadding()
                    .padding(.top, 40)
                } else {
                    if store.isSending {
                        ZashiButton(
                            String(localizable: .sendSending),
                            accessoryView:
                                ProgressView()
                                .progressViewStyle(
                                    CircularProgressViewStyle(
                                        tint: Asset.Colors.secondary.color
                                    )
                                )
                        ) { }
                            .screenHorizontalPadding()
                            .padding(.top, 40)
                            .padding(.bottom, 24)
                            .disabled(store.isSending)
                    } else {
                        ZashiButton(String(localizable: .generalSend)) {
                            store.send(.sendTapped)
                        }
                        .screenHorizontalPadding()
                        .padding(.top, 40)
                        .padding(.bottom, 24)
                    }
                }
            }
            .onAppear { store.send(.onAppear) }
            .screenTitle(String(localizable: .sendRequestPaymentTitle).uppercased())
            .zashiBack(store.isSending) {
                store.send(.goBackTappedFromRequestZec)
            }
        }
        .navigationBarBackButtonHidden()
        .padding(.vertical, 1)
        .applyScreenBackground()
        .zashiBack(hidden: true)
    }
}

#Preview {
    NavigationView {
        RequestPaymentConfirmationView(
            store: SendConfirmation.initial,
            tokenName: "ZEC"
        )
    }
}
