//
//  SendFormView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04/25/2022.
//

import SwiftUI
import ComposableArchitecture
import Generated
//import Scan
import UIComponents
import BalanceFormatter
import WalletBalances

public struct SendFormView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    private enum InputID: Hashable {
        case message
        case addressBookHint
    }
    
    @State private var keyboardVisible: Bool = false

    @Perception.Bindable var store: StoreOf<SendForm>
    let tokenName: String

    @FocusState private var isAddressFocused
    @FocusState private var isAmountFocused
    @FocusState private var isCurrencyFocused
    @FocusState private var isMemoFocused

    public init(store: StoreOf<SendForm>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            ZStack {
                WithPerceptionTracking {
                    ScrollView {
                        ScrollViewReader { value in
                            WithPerceptionTracking {
                                VStack(alignment: .center) {
                                    WithPerceptionTracking {
                                        WalletBalancesView(
                                            store: store.scope(
                                                state: \.walletBalancesState,
                                                action: \.walletBalances
                                            ),
                                            tokenName: tokenName,
                                            couldBeHidden: true
                                        )
                                        
                                        VStack(alignment: .leading) {
                                            ZashiTextField(
                                                addressFont: true,
                                                text: store.bindingForAddress,
                                                placeholder: L10n.Send.addressPlaceholder,
                                                title: L10n.Send.to,
                                                error: store.invalidAddressErrorText,
                                                accessoryView:
                                                    HStack(spacing: 4) {
                                                        WithPerceptionTracking {
                                                            fieldButton(
                                                                icon: store.isNotAddressInAddressBook
                                                                ? Asset.Assets.Icons.userPlus.image
                                                                : Asset.Assets.Icons.user.image
                                                            ) {
                                                                if store.isNotAddressInAddressBook {
                                                                    store.send(.addNewContactTapped(store.address))
                                                                } else {
                                                                    store.send(.addressBookTapped)
                                                                }
                                                            }
                                                            
                                                            fieldButton(icon: Asset.Assets.Icons.qr.image) {
                                                                store.send(.scanTapped)
                                                            }
                                                        }
                                                    }
                                                    .frame(height: 20)
                                                    .offset(x: 8)
                                            )
                                            .id(InputID.addressBookHint)
                                            .keyboardType(.alphabet)
                                            .focused($isAddressFocused)
                                            .submitLabel(.next)
                                            .onSubmit {
                                                isAmountFocused = true
                                            }
                                            .padding(.bottom, 20)
                                            .anchorPreference(
                                                key: UnknownAddressPreferenceKey.self,
                                                value: .bounds
                                            ) { $0 }
                                            
                                            VStack(alignment: .leading) {
                                                HStack(alignment: .top, spacing: 4) {
                                                    ZashiTextField(
                                                        text: store.bindingForZecAmount,
                                                        placeholder: tokenName.uppercased(),
                                                        title: L10n.Send.amount,
                                                        error: store.invalidZecAmountErrorText,
                                                        prefixView:
                                                            Asset.Assets.Icons.currencyZec.image
                                                                .zImage(size: 20, style: Design.Inputs.Default.text)
                                                    )
                                                    .keyboardType(.decimalPad)
                                                    .focused($isAmountFocused)
                                                    
                                                    if store.isCurrencyConversionEnabled {
                                                        Asset.Assets.Icons.switchHorizontal.image
                                                            .zImage(size: 24, style: Design.Btns.Ghost.fg)
                                                            .padding(8)
                                                            .padding(.top, 24)
                                                        
                                                        ZashiTextField(
                                                            text: store.bindingForCurrency,
                                                            placeholder: L10n.Send.currencyPlaceholder,
                                                            error: store.invalidCurrencyAmountErrorText,
                                                            prefixView:
                                                                Asset.Assets.Icons.currencyDollar.image
                                                                .zImage(size: 20, style: Design.Inputs.Default.text)
                                                        )
                                                        .keyboardType(.decimalPad)
                                                        .focused($isCurrencyFocused)
                                                        .padding(.top, 23)
                                                        .disabled(store.currencyConversion == nil)
                                                        .opacity(store.currencyConversion == nil ? 0.5 : 1.0)
                                                    }
                                                }
                                            }
                                            .padding(.bottom, 20)
                                        }
                                        
                                        if store.isMemoInputEnabled {
                                            MessageEditorView(store: store.memoStore(), isAddUAtoMemoActive: true)
                                                .frame(minHeight: 155)
                                                .frame(maxHeight: 300)
                                                .id(InputID.message)
                                                .focused($isMemoFocused)
                                        } else {
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(L10n.Send.message)
                                                    .zFont(.medium, size: 14, style: Design.Inputs.Filled.label)
                                                    .padding(.bottom, 6)
                                                
                                                HStack(spacing: 0) {
                                                    VStack {
                                                        Asset.Assets.infoOutline.image
                                                            .zImage(size: 20, style: Design.Utility.Gray._500)
                                                            .padding(.trailing, 12)
                                                        
                                                        Spacer(minLength: 0)
                                                    }
                                                    
                                                    Text(L10n.Send.Info.memo)
                                                        .zFont(size: 12, style: Design.Utility.Gray._700)
                                                    
                                                    Spacer()
                                                }
                                                .padding(10)
                                                .background {
                                                    RoundedRectangle(cornerRadius: Design.Radius._md)
                                                        .fill(Design.Utility.Gray._50.color(colorScheme))
                                                }
                                            }
                                        }
                                        
                                        ZashiButton(L10n.Send.review) {
                                            store.send(.reviewTapped)
                                        }
                                        .disabled(!store.isValidForm)
                                        .padding(.top, 40)
                                    }
                                }
                                .screenHorizontalPadding()
                                .onChange(of: store.isNotAddressInAddressBook) { update in
                                    withAnimation {
                                        if update {
                                            value.scrollTo(InputID.addressBookHint, anchor: .top)
                                        }
                                    }
                                }
                                .onChange(of: isAddressFocused) { update in
                                    withAnimation {
                                        if update && store.isNotAddressInAddressBook {
                                            value.scrollTo(InputID.addressBookHint, anchor: .top)
                                        }
                                    }
                                }
                            }
                        }
                        .onAppear {
                            store.send(.onAppear)
                            observeKeyboardNotifications()
                            if store.requestsAddressFocus {
                                isAddressFocused = true
                                store.send(.requestsAddressFocusResolved)
                            }
                        }
                        .applyScreenBackground()
                    }
                }
            }
            .padding(.vertical, 1)
            .applyScreenBackground()
            .zashiBack() { store.send(.dismissRequired) }
            .zashiSheet(isPresented: $store.isSheetTexAddressVisible) {
                helpSheetContent()
            }
            .insufficientFundsSheet(isPresented: $store.isInsufficientBalance)
            .alert(store: store.scope(
                state: \.$alert,
                action: \.alert
            ))
            .zashiSheet(isPresented: $store.balancesBinding) {
                balancesContent()
            }
            .overlayPreferenceValue(UnknownAddressPreferenceKey.self) { preferences in
                if isAddressFocused && store.isAddressBookHintVisible {
                    GeometryReader { geometry in
                        preferences.map {
                            HStack(alignment: .top, spacing: 0) {
                                Asset.Assets.Icons.userPlus.image
                                    .zImage(size: 20, style: Design.HintTooltips.titleText)
                                    .padding(.trailing, 12)
                                
                                Text(L10n.Send.addressNotInBook)
                                    .zFont(.medium, size: 14, style: Design.HintTooltips.titleText)
                                    .padding(.top, 2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 40)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._md)
                                    .fill(Design.HintTooltips.surfacePrimary.color(colorScheme))
                            }
                            .frame(width: geometry.size.width - 48)
                            .offset(x: 24, y: geometry[$0].minY + geometry[$0].height - 16)
                        }
                    }
                }
            }
            .overlay {
                if keyboardVisible {
                    VStack(spacing: 0) {
                        Spacer()
                        
                        Asset.Colors.primary.color
                            .frame(height: 1)
                            .opacity(0.1)
                        
                        HStack(alignment: .center) {
                            Spacer()
                            
                            Button {
                                isAmountFocused = false
                                isAddressFocused = false
                                isCurrencyFocused = false
                                isMemoFocused = false
                            } label: {
                                Text(L10n.General.done.uppercased())
                                    .zFont(.regular, size: 14, style: Design.Text.primary)
                            }
                            .padding(.bottom, 4)
                        }
                        .applyScreenBackground()
                        .padding(.horizontal, 20)
                        .frame(height: keyboardVisible ? 38 : 0)
                        .frame(maxWidth: .infinity)
                        .opacity(keyboardVisible ? 1 : 0)
                    }
                }
            }
        }
    }
    
    private func fieldButton(icon: Image, _ action: @escaping () -> Void) -> some View {
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

    private func observeKeyboardNotifications() {
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
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .padding(12)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(L10n.TexKeystone.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 8)

            Group {
                Text(L10n.TexKeystone.warn1).bold()
                + Text(L10n.TexKeystone.warn2)
            }
            .zFont(size: 14, style: Design.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
            .padding(.bottom, 24)

            Text(L10n.TexKeystone.workaround)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .padding(.bottom, 16)

            texSupportPoint(0)
            texSupportPoint(1)
                .padding(.bottom, 8)

            ZashiButton(L10n.TexKeystone.gotIt) {
                store.send(.gotTexSupportTapped)
            }
            .padding(.top, 32)
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func texSupportPoint(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Asset.Assets.Icons.trIn.image
                    .zImage(size: 20, style: index == 0 ? Design.Text.opposite : Design.Text.primary)
                    .padding(12)
                    .rotationEffect(.degrees(225 * Double(index)))
                    .background {
                        Circle()
                            .fill(index == 0 ? Design.Surfaces.bgAlt.color(colorScheme) : Design.Surfaces.bgQuaternary.color(colorScheme))
                            .frame(width: 44, height: 44)
                    }

                if index == 0 {
                    Color.white
                        .frame(width: 3)
                        .overlay {
                            LinearGradient(
                                stops: [
                                    Gradient.Stop(color: Design.Utility.Gray._950.color(colorScheme), location: 0.00),
                                    Gradient.Stop(color: Design.Surfaces.bgQuaternary.color(colorScheme), location: 1.00),
                                ],
                                startPoint: UnitPoint(x: 0.5, y: 0),
                                endPoint: UnitPoint(x: 0.5, y: 1)
                            )
                        }
                        .padding(.vertical, 4)
                }
            }
            .padding(.trailing, Design.Spacing._xl)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.TexKeystone.step("\(index + 1)"))
                    .zFont(.medium, size: 12, style: Design.Utility.Gray._700)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius._sm)
                            .fill(Design.Utility.Gray._50.color(colorScheme))
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Radius._sm)
                                    .stroke(Design.Utility.Gray._200.color(colorScheme))
                            }
                    )
                    .padding(.vertical, 4)
                
                Text(index == 0 ? L10n.TexKeystone.Step1.title : L10n.TexKeystone.Step2.title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(index == 0 ? L10n.TexKeystone.Step1.desc : L10n.TexKeystone.Step2.desc)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        SendFormView(
            store: .init(
                initialState: .init(
                    addMemoState: true,
                    memoState: .initial,
                    walletBalancesState: .initial
                )
            ) {
                SendForm()
            },
            tokenName: "ZEC"
        )
    }
    .navigationViewStyle(.stack)
}

// MARK: - Store

extension StoreOf<SendForm> {
    func memoStore() -> StoreOf<MessageEditor> {
        self.scope(
            state: \.memoState,
            action: \.memo
        )
    }
}

// MARK: - ViewStore

extension StoreOf<SendForm> {
    var bindingForAddress: Binding<String> {
        Binding(
            get: { self.address.data },
            set: { self.send(.addressUpdated($0.redacted)) }
        )
    }

    var bindingForCurrency: Binding<String> {
        Binding(
            get: { self.currencyText.data },
            set: { self.send(.currencyUpdated($0.redacted)) }
        )
    }
    
    var bindingForZecAmount: Binding<String> {
        Binding(
            get: { self.zecAmountText.data },
            set: { self.send(.zecAmountUpdated($0.redacted)) }
        )
    }
}

// MARK: Placeholders

extension SendForm.State {
    public static var initial: Self {
        .init(
            addMemoState: true,
            memoState: .initial,
            walletBalancesState: .initial
        )
    }
}

// #if DEBUG // FIX: Issue #306 - Release build is broken
extension StoreOf<SendForm> {
    public static var placeholder: StoreOf<SendForm> {
        StoreOf<SendForm>(
            initialState: .initial
        ) {
            SendForm()
        }
    }
}
// #endif
