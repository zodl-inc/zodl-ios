//
//  AddressBookSheets.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-07-03.
//

import UIKit
import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import SwapAndPay
import Models

import BalanceBreakdown

extension AddressBookContactView {
    @ViewBuilder func assetsEmptyComposition(_ colorScheme: ColorScheme) -> some View {
        List {
            WithPerceptionTracking {
                ForEach(0..<15) { _ in
                    NoChainPlaceholder()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Asset.Colors.background.color)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .disabled(true)
        .padding(.vertical, 1)
        .background(Asset.Colors.background.color)
        .listStyle(.plain)
    }
    
    @ViewBuilder func assetsLoadingComposition(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in
                        NoChainPlaceholder(true)
                    }
                    
                    Spacer()
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .clear, location: 0.0),
                            Gradient.Stop(color: Asset.Colors.background.color, location: 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                
                VStack(spacing: 0) {
                    Asset.Assets.Illustrations.emptyState.image
                        .resizable()
                        .frame(width: 164, height: 164)
                        .padding(.bottom, 20)
                    
                    Text(L10n.SwapAndPay.EmptyAssets.title)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .padding(.bottom, 8)
                    
                    Text(L10n.SwapAndPay.EmptyAssets.subtitle)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.bottom, 20)
                }
                .padding(.top, 40)
            }
        }
    }
    
    @ViewBuilder func assetContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    VStack {
                        Text(L10n.SwapAndPay.addressBookSelectChain.uppercased())
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            .fixedSize()
                    }
                    
                    HStack {
                        Button {
                            store.send(.closeChainsSheetTapped)
                        } label: {
                            Asset.Assets.buttonCloseX.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(8)
                        }
                        
                        Spacer()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .padding(.horizontal, 20)
                
                ZashiTextField(
                    text: $store.searchTerm,
                    placeholder: L10n.SwapAndPay.search,
                    eraseAction: { store.send(.eraseSearchTermTapped) },
                    accessoryView: !store.searchTerm.isEmpty ? Asset.Assets.Icons.xClose.image
                        .zImage(size: 16, style: Design.Btns.Tertiary.fg) : nil,
                    prefixView: Asset.Assets.Icons.search.image
                        .zImage(size: 20, style: Design.Dropdowns.Default.text)
                )
                .padding(.trailing, 8)
                .padding(.bottom, 32)
                .padding(.horizontal, 20)
                
                if store.chainsToPresent.isEmpty && !store.searchTerm.isEmpty {
                    assetsLoadingComposition(colorScheme)
                } else if store.chainsToPresent.isEmpty && store.searchTerm.isEmpty {
                    assetsEmptyComposition(colorScheme)
                } else {
                    List {
                        WithPerceptionTracking {
                            ForEach(store.chainsToPresent, id: \.self) { chain in
                                chainView(chain, colorScheme)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Asset.Colors.background.color)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    .background(Asset.Colors.background.color)
                    .listStyle(.plain)
                }
            }
        }
    }
    
    @ViewBuilder private func chainView(_ chain: SwapAsset, _ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            Button {
                store.send(.chainTapped(chain))
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        chain.chainIcon
                            .resizable()
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 12)

                        Text(chain.chainName)
                            .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                            .zForegroundColor(Design.Text.primary)
                            .padding(.trailing, 16)
                        
                        Spacer(minLength: 2)
                        
                        Asset.Assets.chevronRight.image
                            .zImage(size: 20, style: Design.Text.tertiary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    
                    if store.chainsToPresent.last != chain {
                        Design.Surfaces.divider.color(colorScheme)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}
