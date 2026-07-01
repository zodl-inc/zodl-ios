//
//  CurrencyConversionSetupView.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-12-2024
//

import SwiftUI
import Combine
import ComposableArchitecture

struct CurrencyConversionSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<CurrencyConversionSetup>
    
    init(store: StoreOf<CurrencyConversionSetup>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack {
                ScrollView {
                    if store.isSettingsView {
                        settingsLayout()
                    } else {
                        learnMoreLayout()
                    }
                }
                .padding(.vertical, 1)
                
                Spacer()
                
                if store.isSettingsView {
                    settingsFooter()
                } else {
                    learnMoreFooter()
                }
            }
            .onAppear { store.send(.onAppear) }
            .zashiBack() { store.send(.backToHomeTapped) }
            .zashiSheet(isPresented: $store.isTorSheetPresented) {
                torSheetContent()
            }
#if os(macOS)
            .zashiSelectorSheet(isPresented: $store.isCurrencyPickerSheetPresented) {
                currencyPickerSheetContent()
            }
#else
            .sheet(isPresented: $store.isCurrencyPickerSheetPresented) {
                currencyPickerSheetContent()
                    .applySheetBackground()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
#endif
        }
        .zashiNavBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
    
    @ViewBuilder private func torSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: Design.Radius._full)
                .fill(Design.Text.primary.color(colorScheme))
                .frame(width: 40, height: 40)
                .overlay {
                    Asset.Assets.Partners.torLogo.image
                        .zImage(width: 22, height: 15, style: Design.Text.opposite)
                }
                .padding(.top, 32)
                .padding(.bottom, 12)

            Text(localizable: .torSetupCcSheetTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .torSetupCcSheetDesc1)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .torSetupCcSheetDesc2)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)

            ZashiButton(
                String(localizable: .torSetupCcSheetLater),
                type: .ghost
            ) {
                store.send(.laterTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .torSetupCcSheetEnable)) {
                store.send(.enableTorTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    private func settingsLayout() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(String(localizable: .currencyConversionSettingsDesc))
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            ForEach(CurrencyConversionSetup.State.SettingsOptions.allCases, id: \.self) { option in
                Button {
                    store.send(.settingsOptionTapped(option))
                } label: {
                    HStack(alignment: .top, spacing: 0) {
                        optionIcon(option.icon().image)
                        optionVStack(option.title(), subtitle: option.subtitle())
                        
                        Spacer()
                        
                        if option == store.currentSettingsOption {
                            Circle()
                                .fill(Design.Checkboxes.onBg.color(colorScheme))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle()
                                        .fill(Design.Checkboxes.onFg.color(colorScheme))
                                        .frame(width: 10, height: 10)
                                }
                        } else {
                            Circle()
                                .fill(Design.Checkboxes.offBg.color(colorScheme))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle()
                                        .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                                        .frame(width: 20, height: 20)
                                }
                        }
                    }
                    .frame(minHeight: 40)
                    .padding(20)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                    }
                }
            }
            .padding(.bottom, Design.Spacing._3xl)

            if store.currentSettingsOption == .optIn {
                currencyPickerSection()
            }
        }
        .padding(.horizontal, 8)
    }

    private func currencyPickerSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localizable: .currencyConversionSelectCurrencyTitle))
                .zFont(.medium, size: 14, style: Design.Text.primary)

            Button {
                store.send(.currencyPickerTapped)
            } label: {
                HStack {
                    Text("\(store.selectedCurrency.code)")
                        .zFont(.medium, size: 16, style: Design.Dropdowns.Filled.textMain)

                    Text("\(store.selectedCurrency.displayName)")
                        .zFont(size: 16, style: Design.Text.tertiary)

                    Spacer()

                    Asset.Assets.chevronRight.image
                        .zImage(size: 20, style: Design.Background.dark)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Design.Background.input.color(colorScheme))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func currencyPickerSheetContent() -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(String(localizable: .currencyConversionSelectCurrencyTitle).uppercased())
                    .zFont(.semiBold, size: 17, style: Design.Text.primary)

                HStack {
                    Button {
                        store.send(.binding(.set(\.isCurrencyPickerSheetPresented, false)))
                    } label: {
                        if #available(iOS 26.0, macOS 26.0, *) {
                            Asset.Assets.buttonCloseX.image
                                .zImage(size: 20, style: Design.Text.primary)
                                .padding(10)
                                .glassEffect(.regular.interactive(), in: .circle)
                        } else {
                            Asset.Assets.buttonCloseX.image
                                .zImage(size: 20, style: Design.Text.primary)
                                .padding(10)
                                .background {
                                    Circle()
                                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                                }
                        }
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(CurrencyISO4217.allCases.enumerated()), id: \.element) { index, currency in
                        Button {
                            store.send(.currencyChanged(currency))
                        } label: {
                            HStack(spacing: 8) {
                                if store.selectedCurrency.code == currency.code {
                                    Text(currency.code)
                                        .zFont(.semiBold, size: 16, style: Design.Text.primary)

                                    Text(currency.displayName)
                                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                } else {
                                    Text(currency.code)
                                        .zFont(.medium, size: 16, style: Design.Text.primary)

                                    Text(currency.displayName)
                                        .zFont(size: 16, style: Design.Text.primary)
                                }

                                Spacer()

                                Asset.Assets.chevronRight.image
                                    .zImage(size: 20, style: Design.Text.quaternary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 20)
                            .contentShape(Rectangle())
                        }
                        .zashiPlainButtonStyle()

                        if index < CurrencyISO4217.allCases.count - 1 {
                            Design.Surfaces.divider.color(colorScheme)
                                .frame(height: 1)
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func learnMoreLayout() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(String(localizable: .currencyConversionLearnMoreDesc))

            ForEach(CurrencyConversionSetup.State.LearnMoreOptions.allCases, id: \.self) { option in
                HStack(alignment: .top, spacing: 0) {
                    optionIcon(option.icon().image)
                    optionVStack(option.title(), subtitle: option.subtitle())
                }
                .padding(.top, 20)
            }
            .padding(.bottom, Design.Spacing._3xl)

            currencyPickerSection()
        }
        .screenHorizontalPadding()
    }
 
    private func settingsFooter() -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: Design.Text.tertiary)
                    .padding(.trailing, 12)
                
                Text(store.isTorOn
                     ? String(localizable: .currencyConversionTorOnInfo)
                     : String(localizable: .currencyConversionTorOffInfo)
                )
                .zFont(size: 12, style: Design.Text.tertiary)
            }
            .padding(.bottom, 20)
            .screenHorizontalPadding()
            
            primaryButton(String(localizable: .currencyConversionSaveBtn), disabled: store.isSaveButtonDisabled) {
                store.send(.saveChangesTapped)
            }
            .padding(.bottom, 24)
        }
    }
    
    private func learnMoreFooter() -> some View {
        VStack {
            secondaryButton(String(localizable: .currencyConversionSkipBtn)) {
                store.send(.skipTapped)
            }
            
            primaryButton(String(localizable: .currencyConversionEnable)) {
                store.send(.enableTapped)
            }
        }
        .padding(.bottom, 24)
    }
}

// MARK: - UI components

extension CurrencyConversionSetupView {
    private func primaryButton(
        _ title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .zFont(.semiBold, size: 16,
                       style: disabled
                       ? Design.Btns.Primary.fgDisabled
                       : Design.Btns.Primary.fg
                )
                .frame(height: 24)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(
                            disabled
                            ? Design.Btns.Primary.bgDisabled.color(colorScheme)
                            : Design.Btns.Primary.bg.color(colorScheme)
                        )
                }
        }
        .disabled(disabled)
        .screenHorizontalPadding()
    }
    
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .zFont(.semiBold, size: 16, style: Design.Btns.Ghost.fg)
                .frame(height: 24)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .screenHorizontalPadding()
    }

    private func icons() -> some View {
        Asset.Assets.rateIcons.image
            .resizable()
            .frame(width: 195, height: 80)
            .offset(x: -8, y: 0)
    }
    
    private func title() -> some View {
        Text(localizable: .currencyConversionTitle)
            .zFont(.semiBold, size: 24, style: Design.Text.primary)
    }
    
    private func note() -> some View {
        HintBox(String(localizable: .currencyConversionNote))
            .screenHorizontalPadding()
    }
    
    private func optionVStack(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)

            Text(subtitle)
                .zFont(size: 14, style: Design.Text.tertiary)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        }
        .padding(.trailing, 16)
    }
    
    private func optionIcon(_ icon: Image) -> some View {
        icon
            .zImage(size: 20, style: Design.Text.primary)
            .padding(10)
            .background {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            }
            .padding(.trailing, 16)
    }
    
    private func header(_ desc: String, desc2: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                icons()
                    .padding(.vertical, 24)
                
                Spacer()
            }
            
            title()
                .padding(.bottom, 8)
            
            Text(desc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .padding(.bottom, desc2 == nil ? 4 : 16)

            if let desc2 {
                Text(desc2)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        CurrencyConversionSetupView(store: CurrencyConversionSetup.initial)
    }
}

// MARK: - Store

extension CurrencyConversionSetup {
    @MainActor static var initial = StoreOf<CurrencyConversionSetup>(
        initialState: .init(isSettingsView: false)
    ) {
        CurrencyConversionSetup()
    }
}

// MARK: - Placeholders

extension CurrencyConversionSetup.State {
    static var initial: CurrencyConversionSetup.State { CurrencyConversionSetup.State() }
}
