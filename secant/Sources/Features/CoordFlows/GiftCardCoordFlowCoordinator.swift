//
//  GiftCardCoordFlowCoordinator.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import Foundation
import ComposableArchitecture

extension GiftCardCoordFlow {
    func coordinatorReduce() -> Reduce<GiftCardCoordFlow.State, GiftCardCoordFlow.Action> {
        Reduce { state, action in
            switch action {
            case .scan(.foundGiftCard(let link)):
                audioServices.systemSoundVibrate()
                state.redeemState = GiftCardRedeem.State(link: link)
                return .none

            case .cleanUp:
                // Nothing open: the scanner is already fresh, and `.giftCardScanner` would mint a
                // new cancel ID for no reason.
                guard state.redeemState != nil else {
                    return .none
                }
                let handles = state.openHandles
                // Dropping the card's state cancels its in-flight work (`ifLet`); the card's
                // wallet is closed afterwards, outside of it.
                state.redeemState = nil
                state.scanState = .giftCardScanner
                guard !handles.isEmpty else {
                    return .none
                }
                return .run { _ in
                    for handle in handles {
                        await giftCard.cleanup(handle)
                    }
                }

            case .scan, .redeem:
                // Exits (`.scan(.cancelTapped)`, `.redeem(.delegate(.dismiss))`) are handled by
                // Root, which owns the presentation and sends `.cleanUp`.
                return .none
            }
        }
    }
}
