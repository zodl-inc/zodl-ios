//
//  GiftCardCoordFlowView.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import SwiftUI
import ComposableArchitecture

struct GiftCardCoordFlowView: View {
    @Perception.Bindable var store: StoreOf<GiftCardCoordFlow>
    let tokenName: String

    init(store: StoreOf<GiftCardCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                if let redeemStore = store.scope(state: \.redeemState, action: \.redeem) {
                    GiftCardRedeemView(store: redeemStore, tokenName: tokenName)
                } else {
                    ScanView(
                        store:
                            store.scope(
                                state: \.scanState,
                                action: \.scan
                            )
                    )
                }
            }
            .navigationBarHidden(true)
            .navigationBarBackButtonHidden()
        }
    }
}

#Preview("Scanner") {
    GiftCardCoordFlowView(store: GiftCardCoordFlow.placeholder, tokenName: "ZEC")
}

#Preview("Opened from a link") {
    GiftCardCoordFlowView(
        store: StoreOf<GiftCardCoordFlow>(
            initialState: GiftCardCoordFlow.State(link: GiftCardRedeem.State.previewLink)
        ) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
        },
        tokenName: "ZEC"
    )
}

// MARK: - Placeholders

extension GiftCardCoordFlow.State {
    static var initial: GiftCardCoordFlow.State { GiftCardCoordFlow.State() }
}

extension GiftCardCoordFlow {
    @MainActor static let placeholder = StoreOf<GiftCardCoordFlow>(
        initialState: .initial
    ) {
        GiftCardCoordFlow()
    } withDependencies: {
        $0.giftCard = .mock()
    }
}
