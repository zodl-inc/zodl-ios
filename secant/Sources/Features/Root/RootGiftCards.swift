//
//  RootGiftCards.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import ComposableArchitecture
import Foundation

/// Routing for the "Redeem gift card" flow: Home's entry point, gift card links found by the
/// scanners of the Scan and Send flows, and gift card links the app was opened with.
extension Root {
    func giftCardsReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .home(.redeemGiftCardTapped):
                return openGiftCardFlow(link: nil, state: &state)

            case .scanCoordFlow(.scan(.foundGiftCard(let link))),
                    .scanCoordFlow(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))),
                    .sendCoordFlow(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))):
                // The user scanned a gift card where they expected an address: take them to the
                // redeem flow instead. Nothing has been sent from these flows at scan time.
                return openGiftCardFlow(link: link, state: &state)

            case .giftCardCoordFlow(.redeem(.opened(_))):
                // The card wallet and the main wallet share one database queue, so the main
                // wallet's sync (and everything it triggers) would slow the card's check and sweep.
                // Pause it while a card is open; it resumes when the flow closes.
                return .run { _ in sdkSynchronizer.stop() }

            case .giftCardCoordFlow(.scan(.cancelTapped)),
                    .giftCardCoordFlow(.redeem(.delegate(.dismiss))):
                state.path = nil
                return .merge(
                    .send(.giftCardCoordFlow(.cleanUp)),
                    .run { _ in try? await sdkSynchronizer.start(true) }
                )

            case .giftCardCoordFlow(.redeem(.delegate(.redeemed))):
                return .send(.fetchTransactionsForTheSelectedAccount)

            default:
                return .none
            }
        }
    }

    /// Handles a gift card link the app was opened with: opens the flow now if nothing on screen
    /// stands in the way, otherwise keeps the link until it can (`canOpenGiftCardFlow`).
    func receiveGiftCardLink(_ link: RedactableString, state: inout Root.State) -> Effect<Root.Action> {
        LoggerProxy.event("[GiftCard] link received")
        guard state.canOpenGiftCardFlow else {
            state.pendingGiftCardLink = link
            return .none
        }
        return openGiftCardFlow(link: link, state: &state)
    }

    /// Presents a fresh gift card flow: on the card behind `link`, or on the scanner when `link`
    /// is `nil`. A card still open from a previous visit is closed first.
    func openGiftCardFlow(link: RedactableString?, state: inout Root.State) -> Effect<Root.Action> {
        let staleHandles = state.giftCardCoordFlowState.openHandles
        state.pendingGiftCardLink = nil
        state.giftCardCoordFlowState = link.map { GiftCardCoordFlow.State(link: $0) } ?? .initial
        state.path = .giftCardCoordFlow
        exchangeRate.refreshExchangeRateUSD()
        guard !staleHandles.isEmpty else {
            return .none
        }
        return .run { _ in
            for handle in staleHandles {
                await giftCard.cleanup(handle)
            }
        }
    }
}
