//
//  FiltersSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-24.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct FilterView: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let active: Bool
    let action: () -> Void
    
    public init(
        title: String,
        active: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.active = active
        self.action = action
    }
    
    public var body: some View {
        Button {
            action()
        } label: {
            if active {
                HStack(spacing: 4) {
                    Text(title)
                        .zFont(.semiBold, size: 14, style: Design.Btns.Secondary.fg)
                        .lineLimit(1)
                    
                    Asset.Assets.buttonCloseX.image
                        .zImage(size: 20, style: Design.Btns.Secondary.fg)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .fill(Design.Btns.Secondary.bg.color(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .stroke(Design.Btns.Secondary.border.color(colorScheme))
                        }
                }
            } else {
                Text(title)
                    .zFont(.semiBold, size: 14, style: Design.Btns.Tertiary.fg)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._3xl)
                            .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                    }
            }
        }
    }
}

extension TransactionsManagerView {
    @ViewBuilder func filtersContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Filter.title)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FilterView(title: L10n.Filter.sent, active: store.isSentFilterActive) { store.send(.toggleFilter(.sent)) }
                    FilterView(title: L10n.Filter.received, active: store.isReceivedFilterActive) { store.send(.toggleFilter(.received)) }
                    FilterView(title: L10n.Filter.memos, active: store.isMemosFilterActive) { store.send(.toggleFilter(.memos)) }
                }
                
                HStack(spacing: 8) {
                    FilterView(title: L10n.Filter.notes, active: store.isNotesFilterActive) { store.send(.toggleFilter(.notes)) }
                    FilterView(title: L10n.Filter.bookmarked, active: store.isBookmarkedFilterActive) { store.send(.toggleFilter(.bookmarked)) }
                    FilterView(title: L10n.Filter.swap, active: store.isSwapFilterActive) { store.send(.toggleFilter(.swap)) }
                }
            }
            .padding(.bottom, 32)
            
            HStack(spacing: 12) {
                ZashiButton(
                    L10n.Filter.reset,
                    type: .secondary
                ) {
                    store.send(.resetFiltersTapped)
                }
                
                ZashiButton(L10n.Filter.apply) {
                    store.send(.applyFiltersTapped)
                }
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}
