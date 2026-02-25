//
//  TransactionsManagerView.swift
//  Zashi
//
//  Created by Lukáš Korba on 01-22-2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import Models
import ZcashLightClientKit
import AddressBook

public struct TransactionsManagerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<TransactionsManager>
    let tokenName: String
    
    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    @Shared(.inMemory(.walletStatus)) public var walletStatus: WalletStatus = .none

    public init(store: StoreOf<TransactionsManager>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZashiTextField(
                        text: $store.searchTerm,
                        placeholder: L10n.Filter.search,
                        eraseAction: { store.send(.eraseSearchTermTapped) },
                        accessoryView: !store.searchTerm.isEmpty ? Asset.Assets.Icons.xClose.image
                            .zImage(size: 16, style: Design.Btns.Tertiary.fg) : nil,
                        prefixView: Asset.Assets.Icons.search.image
                            .zImage(size: 20, style: Design.Dropdowns.Default.text)
                    )
                    .padding(.trailing, 8)
                    
                    Button {
                        store.send(.filterTapped)
                    } label: {
                        ZStack {
                            Asset.Assets.Icons.filter.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(10)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(Design.Btns.Secondary.bg.color(colorScheme))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                .stroke(store.activeFilters.count > 0
                                                        ? Design.Utility.Gray._900.color(colorScheme)
                                                        : Design.Utility.Gray._100.color(colorScheme),
                                                        style: StrokeStyle(lineWidth: store.activeFilters.count > 0 ? 2.0 : 1.0)
                                                )
                                        }
                                }
                            
                            if store.activeFilters.count > 0 {
                                Text("\(store.activeFilters.count)")
                                    .zFont(.medium, size: 12, style: Design.Text.opposite)
                                    .background {
                                        Circle()
                                            .fill(Design.Utility.Gray._900.color(colorScheme))
                                            .frame(width: 20, height: 20)
                                            .background {
                                                Circle()
                                                    .fill(Asset.Colors.background.color)
                                                    .frame(width: 24, height: 24)
                                            }
                                    }
                                    .offset(x: 22, y: -22)
                            }
                        }
                    }
                }
                .screenHorizontalPadding()
                .padding(.vertical, 12)
                .padding(.top, walletStatus == .restoring ? 24 : 0)
                
                if store.transactionSections.isEmpty && !store.isInvalidated {
                    noTransactionsView()
                    
                    Spacer()
                } else {
                    ScrollViewReader { scrollViewProxy in
                        List {
                            if store.isInvalidated {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(0..<15) { _ in
                                        NoTransactionPlaceholder(true)
                                    }
                                    
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Asset.Colors.background.color)
                                .listRowSeparator(.hidden)
                            } else {
                                ForEach(store.transactionSections) { section in
                                    WithPerceptionTracking {
                                        Section {
                                            ForEach(section.transactions) { transaction in
                                                WithPerceptionTracking {
                                                    Button {
                                                        store.send(.transactionTapped(transaction.id))
                                                    } label: {
                                                        TransactionRowView(
                                                            transaction: transaction,
                                                            isUnread: TransactionsManager.isUnread(transaction),
                                                            isSwap: TransactionsManager.isSwap(transaction),
                                                            divider: section.latestTransactionId != transaction.id
                                                        )
                                                        .onAppear {
                                                            if transaction.requiresAutoUpdate {
                                                                store.send(.transactionOnAppear(transaction.id))
                                                            }
                                                        }
                                                    }
                                                    .listRowInsets(EdgeInsets())
                                                }
                                            }
                                            .listRowBackground(Asset.Colors.background.color)
                                            .listRowSeparator(.hidden)
                                        } header: {
                                            Text(section.id)
                                                .zFont(.medium, size: 16, style: Design.Text.tertiary)
                                                .screenHorizontalPadding()
                                                .listRowInsets(EdgeInsets())
                                                .listRowBackground(Asset.Colors.background.color)
                                                .listRowSeparator(.hidden)
                                                .id(section.id)
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: store.transactionSections) { _ in
                            scrollViewProxy.scrollTo(store.transactionSections.first?.id, anchor: .top)
                        }
                    }
                }
            }
            .disabled(store.transactions.isEmpty)
            .applyScreenBackground()
            .listStyle(.plain)
            .onAppear { store.send(.onAppear) }
            .navigationBarItems(trailing: hideBalancesButton())
            .zashiSheet(isPresented: $store.filtersRequest) {
                filtersContent()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .zashiBack() {
            store.send(.dismissRequired)
        }
        .screenTitle(L10n.General.activity.uppercased())
    }
    
    @ViewBuilder func hideBalancesButton() -> some View {
        Button {
            $isSensitiveContentHidden.withLock { $0.toggle() }
        } label: {
            let image = isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image
            image
                .zImage(size: 24, color: Asset.Colors.primary.color)
                .padding(Design.Spacing.navBarButtonPadding)
        }
    }
    
    @ViewBuilder func noTransactionsView() -> some View {
        WithPerceptionTracking {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in
                        NoTransactionPlaceholder()
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

                    Text(L10n.Filter.noResults)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .padding(.bottom, 8)

                    Text(L10n.Filter.weTried)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.bottom, 20)
                }
                .padding(.top, 40)
            }
        }
    }
}

// MARK: - Previews

#Preview {
    TransactionsManagerView(store: TransactionsManager.initial, tokenName: "ZEC")
}

// MARK: - Store

extension TransactionsManager {
    public static var initial = StoreOf<TransactionsManager>(
        initialState: .initial
    ) {
        TransactionsManager()
    }
}

// MARK: - Placeholders

extension TransactionsManager.State {
    public static let initial = TransactionsManager.State()
}
