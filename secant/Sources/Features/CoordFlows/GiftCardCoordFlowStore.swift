//
//  GiftCardCoordFlowStore.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// The "Redeem gift card" flow. It starts either on the scanner (from Home, whose "Paste link"
/// opens the paste screen) or directly on the card (a scanned or opened link), and ends when the
/// user closes it.
///
/// Root owns cleanup when parent navigation leaves or replaces this flow. This reducer owns
/// internal card replacement and explicit `.cleanUp`, including cancellation of child work.
@Reducer
struct GiftCardCoordFlow {
    @ObservableState
    struct State: Equatable {
        var scanState = Scan.State.giftCardScanner
        /// The paste screen, over the scanner. `nil` while it is not showing.
        var pasteLinkState: GiftCardPasteLink.State?
        /// The card being redeemed. `nil` while the scanner or the paste screen is showing.
        var redeemState: GiftCardRedeem.State?

        /// Every open card this flow knows about, for `.cleanUp`.
        var openHandles: [GiftCardHandle] {
            [redeemState?.handle].compactMap { $0 }
        }

        init() { }

        /// Starts directly on the card behind `link`, skipping the scanner. Only for a link
        /// scanned or pasted inside the app.
        init(link: RedactableString) {
            self.redeemState = GiftCardRedeem.State(link: link)
        }

        /// The scanner, asking the user to scan with the app a card whose link came from outside.
        static var rescanRequested: State {
            var state = State()
            state.scanState = .giftCardRescanner
            return state
        }
    }

    enum Action: Equatable {
        /// Closes the card's temporary wallet and resets the flow.
        case cleanUp
        case pasteLink(GiftCardPasteLink.Action)
        case redeem(GiftCardRedeem.Action)
        case scan(Scan.Action)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.giftCard) var giftCard
    @Dependency(\.pasteboard) var pasteboard

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            if case let .redeem(.response(visit, response)) = action, state.redeemState?.cancelId != visit {
                if case .opened(let handle) = response {
                    return .run { _ in await giftCard.cleanup(handle) }
                }
                return .none
            }
            let previous = state.redeemState
            let effect = core._reduce(into: &state, action: action)
            guard let previous, previous.cancelId != state.redeemState?.cancelId else { return effect }
            return .merge(
                effect,
                .cancel(id: previous.cancelId),
                .cancel(id: previous.autoRetryCancelId),
                .run { _ in
                    if let handle = previous.handle { await giftCard.cleanup(handle) }
                }
            )
        }
    }

    @ReducerBuilder<State, Action>
    private var core: some Reducer<State, Action> {
        Scope(state: \.scanState, action: \.scan) {
            Scan()
        }

        coordinatorReduce()
            .ifLet(\.pasteLinkState, action: \.pasteLink) {
                GiftCardPasteLink()
            }
            .ifLet(\.redeemState, action: \.redeem) {
                GiftCardRedeem()
            }
    }
}

extension Scan.State {
    /// The scanner as the gift card flow uses it: gift card links only, plus "Paste link", which
    /// opens the paste screen.
    static var giftCardScanner: Scan.State {
        var state = Scan.State.initial
        state.checkers = [.giftCardScanChecker]
        state.isPasteEnabled = true
        state.instructions = String(localizable: .giftCardScanInstructions)
        state.invalidCodeInfo = String(localizable: .giftCardScanInvalid)
        return state
    }

    /// The gift card scanner opened for a gift card link that came from outside the app, which is
    /// not used: it says the card was opened from another app and asks to scan it with Zodl.
    static var giftCardRescanner: Scan.State {
        var state = Scan.State.giftCardScanner
        state.instructions = String(localizable: .giftCardRescanInstructions)
        return state
    }
}
