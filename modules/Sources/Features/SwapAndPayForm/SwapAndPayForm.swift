//
//  SwapAndPayForm.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-26.
//

import SwiftUI
import ComposableArchitecture
import Generated
import SwapAndPay
import Models

import UIComponents

public struct SwapAndPayForm: View {
    @Environment(\.colorScheme) private var colorScheme

    private enum InputID: Hashable {
        case addressBookHint
    }
    
    enum Constants {
        static let maxAllowedSlippage = "30%"
    }

    @State var keyboardVisible: Bool = false
    
    @FocusState var isAddressFocused
    @FocusState var isAmountFocused
    @FocusState var isUsdFocused
    @State var isSlippageFocused: Bool = false
    
    @State var safeAreaHeight: CGFloat = 0

    @Perception.Bindable var store: StoreOf<SwapAndPay>
    let tokenName: String
    
    public init(store: StoreOf<SwapAndPay>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            if store.isSwapExperienceEnabled || store.isSwapToZecExperienceEnabled {
                swapFormView(colorScheme)
                    .insufficientFundsSheet(isPresented: $store.isInsufficientBalance)
            } else {
                crossPayFormView(colorScheme)
                    .insufficientFundsSheet(isPresented: $store.isInsufficientBalance)
            }
        }
    }

    @ViewBuilder func addressView() -> some View {
        VStack(spacing: 0) {
            Button {
                store.send(.refundAddressTapped)
            } label: {
                HStack(spacing: 0) {
                    Text(store.isSwapToZecExperienceEnabled
                         ? L10n.SwapToZec.refundAddress
                         : store.isSwapExperienceEnabled ? L10n.SwapAndPay.address : ""
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.custom(FontFamily.Inter.medium.name, size: 14))
                    .zForegroundColor(Design.Inputs.Filled.label)

                    if store.isSwapToZecExperienceEnabled {
                        Asset.Assets.infoCircle.image
                            .zImage(size: 13, style: Design.Text.primary)
                            .padding(8)
                    }
                    
                    Spacer()
                }
            }
            .disabled(!store.isSwapToZecExperienceEnabled)

            ZashiTextField(
                addressFont: true,
                text: $store.address,
                placeholder: L10n.SwapToZec.address(store.selectedAsset?.chainName ?? ""),
                accessoryView:
                    HStack(spacing: 4) {
                        WithPerceptionTracking {
                            fieldButton(
                                icon: store.isNotAddressInAddressBook
                                ? Asset.Assets.Icons.userPlus.image
                                : Asset.Assets.Icons.user.image
                            ) {
                                if store.isNotAddressInAddressBook {
                                    store.send(.notInAddressBookButtonTapped(store.address))
                                } else {
                                    store.send(.addressBookRequested)
                                }
                            }
                            
                            fieldButton(icon: Asset.Assets.Icons.qr.image) {
                                store.send(.scanTapped)
                            }
                        }
                    }
                    .frame(height: 20)
                    .offset(x: 8),
                inputReplacementView:
                    store.selectedContact != nil
                ? HStack(spacing: 0) {
                    Text(store.selectedContact?.name ?? "")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                        .padding(.trailing, 3)
                    
                    Button {
                        store.send(.selectedContactClearTapped)
                    } label: {
                        Asset.Assets.buttonCloseX.image
                            .zImage(size: 14, style: Design.Tags.tcHoverFg)
                            .padding(3)
                            .background {
                                Circle()
                                    .fill(Design.Tags.tcHoverBg.color(colorScheme))
                            }
                    }
                }
                    .padding(4)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._sm)
                            .fill(Design.Tags.surfacePrimary.color(colorScheme))
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Radius._sm)
                                    .stroke(Design.Tags.surfaceStroke.color(colorScheme))
                                
                            }
                    }
                : nil
            )
            .frame(minHeight: 44)
            .disabled(store.isQuoteRequestInFlight)
            .id(InputID.addressBookHint)
            .keyboardType(.alphabet)
            .focused($isAddressFocused)
            .padding(.top, 8)
            .anchorPreference(
                key: UnknownAddressPreferenceKey.self,
                value: .bounds
            ) { $0 }
        }
    }
    
    @ViewBuilder func slippageView() -> some View {
        HStack(spacing: 0) {
            Text(L10n.SwapAndPay.slippageTolerance)
                .zFont(.medium, size: 14, style: Design.Text.secondary)
            
            Spacer()

            Button {
                isAmountFocused = false
                store.send(.slippageTapped)
            } label: {
                HStack(spacing: 4) {
                    Text(store.currentSlippageString)
                        .zFont(.semiBold, size: 14, style: Design.Btns.Tertiary.fg)

                    Asset.Assets.Icons.settings2.image
                        .zImage(size: 16, style: Design.Btns.Tertiary.fg)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .disabled(store.isQuoteRequestInFlight)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._md)
                    .fill(Design.Btns.Tertiary.bg.color(colorScheme))
            }
        }
    }

    func fieldButton(icon: Image, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            icon
                .zImage(size: 20, style: Design.Inputs.Default.label)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._md)
                .fill(Design.Btns.Secondary.bg.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._md)
                        .stroke(Design.Btns.Secondary.border.color(colorScheme))
                }
        }
    }
    
    func observeKeyboardNotifications() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            withAnimation {
                keyboardVisible = true
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            withAnimation {
                keyboardVisible = false
            }
        }
    }
    
    @ViewBuilder func zecTicker(_ colorScheme: ColorScheme, shield: Bool = true) -> some View {
        HStack(spacing: 0) {
            zecTickerLogo(colorScheme, shield: shield)
            
            Text(tokenName)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
            
            Spacer()
        }
    }
    
    @ViewBuilder func zecTickerLogo(_ colorScheme: ColorScheme, shield: Bool = true) -> some View {
        Asset.Assets.Brandmarks.brandmarkMax.image
            .zImage(size: 24, style: Design.Text.primary)
            .padding(.trailing, 12)
            .overlay {
                if shield {
                    Asset.Assets.Icons.shieldBcg.image
                        .zImage(size: 15, color: Design.screenBackground.color(colorScheme))
                        .offset(x: 4, y: 8)
                        .overlay {
                            Asset.Assets.Icons.shieldTickFilled.image
                                .zImage(size: 13, color: Design.Text.primary.color(colorScheme))
                                .offset(x: 4, y: 8)
                        }
                } else {
                    Asset.Assets.Icons.shieldOffSolid.image
                        .resizable()
                        .frame(width: 15, height: 15)
                        .offset(x: 4, y: 8)
                }
            }
    }
    
    @ViewBuilder func zecTickerBadge(_ colorScheme: ColorScheme, shield: Bool = true) -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Brandmarks.brandmarkMax.image
                .zImage(size: 24, style: Design.Text.primary)
                .padding(.trailing, 6)
                .overlay {
                    if shield {
                        Asset.Assets.Icons.shieldBcg.image
                            .zImage(size: 15, color: Design.screenBackground.color(colorScheme))
                            .offset(x: 4, y: 8)
                            .overlay {
                                Asset.Assets.Icons.shieldTickFilled.image
                                    .zImage(size: 13, color: Design.Text.primary.color(colorScheme))
                                    .offset(x: 4, y: 8)
                            }
                    } else {
                        Asset.Assets.Icons.shieldOffSolid.image
                            .resizable()
                            .frame(width: 15, height: 15)
                            .offset(x: 4, y: 8)
                    }
                }
                .scaleEffect(0.8)
        }
    }
    
    public func slippageWarnBcgColor(_ colorScheme: ColorScheme) -> Color {
        if store.slippageInSheet <= 1.0 {
            return Design.Utility.Gray._100.color(colorScheme)
        } else if store.slippageInSheet > 1.0 && store.slippageInSheet <= 2.0 {
            return Design.Utility.WarningYellow._50.color(colorScheme)
        } else {
            return Design.Utility.ErrorRed._100.color(colorScheme)
        }
    }

    public func slippageWarnTextStyle() -> Colorable {
        if store.slippageInSheet <= 1.0 {
            return Design.Utility.Gray._900
        } else if store.slippageInSheet > 1.0 && store.slippageInSheet <= 2.0 {
            return Design.Utility.WarningYellow._900
        } else {
            return Design.Utility.ErrorRed._900
        }
    }
}

extension View {
    @ViewBuilder func noBcgTicker(asset: SwapAsset?, crosspay: Bool, _ colorScheme: ColorScheme) -> some View {
        HStack(spacing: 0) {
            if let asset {
                tokenTicker(asset: asset, colorScheme)
                
                if crosspay {
                    HStack(spacing: 4) {
                        Text(asset.token)
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)
                        
                        Text(L10n.tokenOnChain)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)

                        Text(asset.chainName)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    }
                    .padding(.horizontal, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(asset.token)
                            .zFont(.semiBold, size: 12, style: Design.Text.primary)
                        
                        Text(asset.chainName)
                            .zFont(.medium, size: 12, style: Design.Text.tertiary)
                    }
                    .padding(.horizontal, 4)
                    .fixedSize()
                    .minimumScaleFactor(0.7)
                }
            } else {
                Circle()
                    .shimmer(true).clipShape(Circle())
                    .frame(width: 24, height: 24)
                    .zForegroundColor(Design.Surfaces.bgSecondary)
                    .padding(.trailing, 4)

                RoundedRectangle(cornerRadius: Design.Radius._sm)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(true).clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 50, height: 18)
                    .padding(.trailing, 4)
            }
            
            Asset.Assets.chevronDown.image
                .zImage(size: 16, style: Design.Text.primary)
                .padding(.trailing, 4)
        }
        .padding(4)
    }
    
    @ViewBuilder func tokenTicker(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
        if let asset {
            asset.tokenIcon
                .resizable()
                .frame(width: 24, height: 24)
                .padding(.trailing, 8)
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                            .frame(width: 16, height: 16)
                            .offset(x: 6, y: 6)
                        
                        asset.chainIcon
                            .resizable()
                            .frame(width: 14, height: 14)
                            .offset(x: 6, y: 6)
                    }
                }
        }
    }
    
    @ViewBuilder func tokenTickerSelector(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
        if let asset {
            HStack(spacing: 0) {
                asset.tokenIcon
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(.trailing, 8)
                    .overlay {
                        ZStack {
                            Circle()
                                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                                .frame(width: 16, height: 16)
                                .offset(x: 6, y: 6)
                            
                            asset.chainIcon
                                .resizable()
                                .frame(width: 14, height: 14)
                                .offset(x: 6, y: 6)
                        }
                    }
                    .scaleEffect(0.8)
            }
        }
    }
    
    @ViewBuilder func ticker(asset: SwapAsset?, crosspay: Bool, _ colorScheme: ColorScheme) -> some View {
        noBcgTicker(asset: asset, crosspay: crosspay, colorScheme)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._full)
                    .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._full)
                            .stroke(Design.Surfaces.strokeTertiary.color(colorScheme))
                    }
            }
            .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
            .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
    }
}

#Preview {
    NavigationView {
        SwapAndPayForm(store: SwapAndPay.initial, tokenName: "ZEC")
    }
}

// MARK: Placeholders

extension SwapAndPay.State {
    public static var initial: Self {
        .init(
            walletBalancesState: .initial
        )
    }
}

extension SwapAndPay {
    public static var initial = StoreOf<SwapAndPay>(
        initialState: .initial
    ) {
        SwapAndPay()
    }
}
