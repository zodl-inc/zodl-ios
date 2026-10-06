//
//  GiftCardPasteLinkView.swift
//  Zodl
//
//  Created by Zodl on 2026-10-06.
//

import SwiftUI
import ComposableArchitecture

struct GiftCardPasteLinkView: View {
    @Perception.Bindable var store: StoreOf<GiftCardPasteLink>

    init(store: StoreOf<GiftCardPasteLink>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        Asset.Assets.Illustrations.giftClosed.image
                            .zImage(
                                width: GiftCardRedeemView.Constants.closedGiftSize,
                                height: GiftCardRedeemView.Constants.closedGiftSize,
                                style: Design.Text.primary
                            )
                            .padding(.top, 24)

                        Text(localizable: .giftCardPasteTitle)
                            .zFont(.semiBold, size: 20, style: Design.Text.primary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 16)

                        Text(localizable: .giftCardPasteDesc)
                            .zFont(size: 14, style: Design.Text.primary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(1.5)
                            .padding(.top, 8)

                        ZashiTextField(
                            text: Binding(
                                get: { store.text.data },
                                set: { store.send(.textChanged($0.redacted)) }
                            ),
                            placeholder: String(localizable: .giftCardPastePlaceholder),
                            title: String(localizable: .giftCardPasteFieldTitle),
                            error: store.isInvalid ? String(localizable: .giftCardPasteInvalid) : nil,
                            inputAccessibilityIdentifier: AccessibilityID.GiftCard.pasteLinkField,
                            accessoryView: fieldButton()
                        )
                        .padding(.top, 32)
                    }
                }
                .padding(.vertical, 1)

                Spacer()

                ZashiButton(String(localizable: .generalContinue)) {
                    store.send(.continueTapped)
                }
                .disabled(!store.isValid)
                .accessibilityIdentifier(AccessibilityID.GiftCard.pasteLinkContinue)
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .screenTitle(String(localizable: .giftCardTitle))
            .zashiBack { store.send(.backTapped) }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
            .applyScreenBackground()
        }
    }

    /// Paste while the field is empty, Clear once it holds anything.
    @ViewBuilder private func fieldButton() -> some View {
        if store.text.data.isEmpty {
            Button {
                store.send(.pasteTapped)
            } label: {
                HStack(spacing: 4) {
                    Asset.Assets.copy.image
                        .zImage(size: 16, style: Design.Text.primary)

                    Text(localizable: .giftCardPastePaste)
                        .zFont(.semiBold, size: 14, style: Design.Text.primary)
                }
            }
            .accessibilityIdentifier(AccessibilityID.GiftCard.pasteLinkPaste)
        } else {
            Button {
                store.send(.clearTapped)
            } label: {
                Text(localizable: .giftCardPasteClear)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
            }
            .accessibilityIdentifier(AccessibilityID.GiftCard.pasteLinkClear)
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    NavigationView {
        GiftCardPasteLinkView(store: GiftCardPasteLink.preview(text: ""))
    }
}

#Preview("Pasted") {
    NavigationView {
        GiftCardPasteLinkView(store: GiftCardPasteLink.preview(text: GiftCardRedeem.State.previewLink.data))
    }
}

#Preview("Invalid") {
    NavigationView {
        GiftCardPasteLinkView(store: GiftCardPasteLink.preview(text: "zodl.com/gift/8f2k"))
    }
}

// MARK: - Placeholders

extension GiftCardPasteLink {
    @MainActor static func preview(text: String) -> StoreOf<GiftCardPasteLink> {
        let store = StoreOf<GiftCardPasteLink>(initialState: State()) {
            GiftCardPasteLink()
        } withDependencies: {
            $0.giftCard = .mock()
        }
        store.send(.textChanged(text.redacted))
        return store
    }
}
