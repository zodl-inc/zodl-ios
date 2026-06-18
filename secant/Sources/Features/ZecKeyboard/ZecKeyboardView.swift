//
//  ZecKeyboardView.swift
//  modules
//
//  Created by Lukáš Korba on 20.09.2024.
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct ZecKeyboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<ZecKeyboard>
    
    let tokenName: String
    
    init(store: StoreOf<ZecKeyboard>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            keyboardBody
        }
        .applyScreenBackground()
        .zashiBack()
        .screenTitle(String(localizable: .generalRequest))
        .zashiSheet(isPresented: $store.isCurrencyUnavailableSheetPresented) {
            currencyUnavailableSheetContent()
        }
    }

    @ViewBuilder private var keyboardBody: some View {
        VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !store.isValidInput {
                        HStack(spacing: 0) {
                            Asset.Assets.infoOutline.image
                                .zImage(size: 20, style: Design.Utility.WarningYellow._500)
                                .padding(.trailing, 12)
                            
                            Text(localizable: .zecKeyboardInvalid)
                                .zFont(.medium, size: 14, style: Design.Utility.WarningYellow._700)
                                .padding(.top, 3)
                        }
                        .padding(.horizontal, 10)
                        .screenHorizontalPadding()
                        .padding(.bottom, 4)
                    }
                    
                    HStack(spacing: 0) {
                        if store.isInputInZec {
                            Text(store.humanReadableMainInput)
                            + Text(" \(tokenName)")
                                .foregroundColor(Design.Text.quaternary.color(colorScheme))
                        } else {
                            if store.isCurrencySymbolPrefix {
                                Text(store.localeCurrencySymbol)
                                    .foregroundColor(Design.Text.quaternary.color(colorScheme))
                                + Text(store.humanReadableMainInput)
                            } else {
                                Text(store.humanReadableMainInput)
                                + Text(" \(store.localeCurrencySymbol)")
                                    .foregroundColor(Design.Text.quaternary.color(colorScheme))
                            }
                        }
                    }
                    .zFont(.semiBold, size: 56, style: Design.Text.primary)
                    .frame(height: 68)
                    .minimumScaleFactor(0.1)
                    .lineLimit(1)
                    .screenHorizontalPadding()
                }
                .padding(.top, 88)
                .onChange(of: store.currencyConversion) { _ in
                    store.send(.validateInputs)
                }

                if store.currencyConversion != nil {
                    HStack(spacing: 0) {
                        Group {
                            if store.isInputInZec {
                                if store.isCurrencySymbolPrefix {
                                    Text(store.localeCurrencySymbol)
                                        .foregroundColor(Design.Text.quaternary.color(colorScheme))
                                    + Text(store.humanReadableConvertedInput)
                                } else {
                                    Text(store.humanReadableConvertedInput)
                                    + Text(" \(store.localeCurrencySymbol)")
                                        .foregroundColor(Design.Text.quaternary.color(colorScheme))
                                }
                            } else {
                                Text(store.humanReadableConvertedInput)
                                + Text(" \(tokenName)")
                                    .foregroundColor(Design.Text.quaternary.color(colorScheme))
                            }
                        }
                        .zFont(.medium, size: 18, style: Design.Text.primary)
                        .padding(.trailing, 9)

                        Button {
                            store.send(.swapCurrenciesTapped)
                        } label: {
                            Asset.Assets.Icons.switchHorizontal.image
                                .zImage(size: 24, style: Design.Btns.Tertiary.fg)
                                .padding(8)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                                }
                                .rotationEffect(Angle(degrees: 90))
                        }
                    }
                    .minimumScaleFactor(0.6)
                    .screenHorizontalPadding()
                }

                Spacer()

                if store.keys.count == 12 {
                    VStack(spacing: 0) {
                        ForEach(0..<4) { column in
                            HStack {
                                Spacer()
                                
                                ForEach(0..<3) { row in
                                    VStack {
                                        WithPerceptionTracking {
                                            Button {
                                                store.send(.keyTapped(column * 3 + row))
                                            } label: {
                                                if store.keys[column * 3 + row] == "x" {
                                                    Asset.Assets.Icons.delete.image
                                                        .zImage(size: 40, style: Design.Text.primary)
                                                } else {
                                                    Text(store.keys[column * 3 + row])
                                                        .zFont(.semiBold, size: 32, style: Design.Text.primary)
                                                        .frame(width: 40, height: 40)
                                                }
                                            }
                                            .padding(10)
                                            .simultaneousGesture(
                                                LongPressGesture().onEnded { _ in
                                                    if store.keys[column * 3 + row] == "x" {
                                                        store.send(.longKeyTapped(column * 3 + row))
                                                    }
                                                }
                                            )
                                        }
                                        
                                        Spacer()
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                    .padding(.bottom, 24)
                }

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.nextTapped)
                }
                .disabled(store.isNextButtonDisabled)
                .padding(.bottom, 24)
                .screenHorizontalPadding()
        }
        .onAppear { store.send(.onAppear) }
    }

    @ViewBuilder private func currencyUnavailableSheetContent() -> some View {
        VStack(alignment: .center, spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .padding(12)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(String(localizable: .sendCurrencyUnavailableTitle(store.selectedCurrency.code)))
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .padding(.bottom, 8)

            Text(String(localizable: .sendCurrencyUnavailableDesc(store.selectedCurrency.displayName)))
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.horizontal, 4)
                .padding(.bottom, 24)

            ZashiButton(String(localizable: .sendCurrencyUnavailableSwitchToUSD)) {
                store.send(.currencyUnavailableSwitchToUSDTapped)
            }
            .padding(.bottom, 8)

            ZashiButton(
                String(localizable: .sendCurrencyUnavailableContinueInZEC),
                type: .ghost
            ) {
                store.send(.currencyUnavailableContinueInZECTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

#Preview {
    NavigationView {
        ZecKeyboardView(store: ZecKeyboard.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension ZecKeyboard.State {
    static var initial: ZecKeyboard.State { ZecKeyboard.State() }
}

extension ZecKeyboard {
    @MainActor static let placeholder = StoreOf<ZecKeyboard>(
        initialState: .initial
    ) {
        ZecKeyboard()
    }
}
