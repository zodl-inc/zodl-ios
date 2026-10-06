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

            case .scan(.pasteTapped):
                guard state.redeemState == nil else {
                    return .none
                }
                state.pasteLinkState = GiftCardPasteLink.State()
                return .none

            case .pasteLink(.delegate(.back)):
                state.pasteLinkState = nil
                return .none

            case .pasteLink(.delegate(.open(let link))):
                state.pasteLinkState = nil
                state.redeemState = GiftCardRedeem.State(link: link)
                return .none

            case .cleanUp:
                state.pasteLinkState = nil
                // Nothing open: the scanner is already fresh, and `.giftCardScanner` would mint a
                // new cancel ID for no reason.
                guard state.redeemState != nil else {
                    return .none
                }
                state.redeemState = nil
                state.scanState = .giftCardScanner
                return .none

            case .scan, .pasteLink, .redeem:
                // Exits (`.scan(.cancelTapped)`, `.redeem(.delegate(.dismiss))`) are handled by
                // Root, whose outer lifecycle boundary owns parent exits.
                return .none
            }
        }
    }
}
