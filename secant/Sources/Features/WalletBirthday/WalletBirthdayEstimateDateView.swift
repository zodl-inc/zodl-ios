//
//  WalletBirthdayEstimateDateView.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-31-2025.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct WalletBirthdayEstimateDateView: View {
    @PlatformBindable var store: StoreOf<WalletBirthday>

    @State private var selectedMonth: String = ""
    @State private var selectedYear: Int = WalletBirthday.Constants.startYear

    init(store: StoreOf<WalletBirthday>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if store.isKeystoneFlow {
                    Asset.Assets.Partners.keystoneTitleLogo.image
                        .resizable()
                        .frame(width: 193, height: 32)
                        .padding(.top, 16)
                }

                Text(localizable: .restoreWalletBirthdayEstimateDateTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)
                    .padding(.bottom, 8)

                Text(
                    localizable:
                        store.isResyncFlow
                    ? .firstWalletTransactionSubtitleResync
                    : store.isKeystoneFlow
                    ? .firstWalletTransactionSubtitleHWWallet
                    : .firstWalletTransactionSubtitleRestore
                )
                .zFont(size: 14, style: Design.Text.primary)
                .padding(.bottom, 32)

                HStack {
                    Picker("", selection: $selectedMonth) {
                        ForEach(store.months, id: \.self) { month in
                            Text(month)
                                .zFont(size: 23, style: Design.Text.primary)
                        }
                    }
#if os(iOS)
                    .pickerStyle(.wheel)
#endif
                    .onChange(of: selectedYear) { _ in
                        store.send(.binding(.set(\.selectedYear, selectedYear)))
                        // sync month in case it went out of range
                        if !store.months.contains(selectedMonth) {
                            selectedMonth = store.months.last ?? selectedMonth
                        }
                    }

                    Picker("", selection: $selectedYear) {
                        ForEach(store.years, id: \.self) { year in
                            Text("\(String(year))")
                                .zFont(size: 23, style: Design.Text.primary)
                        }
                    }
#if os(iOS)
                    .pickerStyle(.wheel)
#endif
                }
                
                Spacer()

                if store.isKeystoneFlow || store.isResyncFlow {
                    ZashiButton(
                        String(localizable: .keystoneAddHWWalletEnterManually),
                        type: .ghost
                    ) {
                        store.send(.enterManuallyTapped)
                    }
                    .padding(.bottom, 12)
                }

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.binding(.set(\.selectedMonth, selectedMonth)))
                    store.send(.binding(.set(\.selectedYear, selectedYear)))
                    store.send(.estimateHeightRequested)
                }
                .padding(.bottom, 24)
            }
            .onAppear {
                store.send(.onAppear)
                selectedMonth = store.selectedMonth
                selectedYear = store.selectedYear
            }
            .onChange(of: store.selectedMonth) { newMonth in
                selectedMonth = newMonth
            }
            .zashiBack()
            .zashiNavBarTitleDisplayMode(.inline)
            .zashiNavigationBarItems(
                trailing:
                    Button {
                        store.send(.helpSheetRequested)
                    } label: {
#if os(macOS)
                        // macOS 26 sizes the glass capsule to the icon's WIDTH — a bare SF symbol is narrow
                        // → tall capsule. zashiToolbarIconPadding() widens it to circular (matches the back).
                        Image(systemName: "info.circle")
                            .zashiToolbarIconPadding()
#else
                        Asset.Assets.Icons.help.image
                            .zImage(size: 24, style: Design.Text.primary)
                            .padding(Design.Spacing.navBarButtonPadding)
#endif
                    }
            )
            .screenHorizontalPadding()
            .applyScreenBackground()
            .screenTitle(
                store.isKeystoneFlow ? ""
                : store.isResyncFlow
                ? String(localizable: .resyncWalletTitle)
                : String(localizable: .importWalletButtonRestoreWallet)
            )
        }
    }
}

// MARK: - Previews

#Preview {
    WalletBirthdayEstimateDateView(store: WalletBirthday.initial)
}
