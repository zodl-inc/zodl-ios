//
//  GiftCardCoordFlowStore.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// The "Redeem gift card" flow. It starts either on the scanner (from Home, with a "Paste link"
/// option) or directly on the card (a scanned or opened link), and ends when the user closes it.
///
/// Whoever closes the flow must send `.cleanUp`, which closes the card's temporary wallet; Root
/// does that on every exit (see `RootCoordinator`).
@Reducer
struct GiftCardCoordFlow {
    @ObservableState
    struct State: Equatable {
        var scanState = Scan.State.giftCardScanner
        /// The card being redeemed. `nil` while the scanner is showing.
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
        /// Closes the card's temporary wallet and resets the flow. Sent by Root on every exit.
        case cleanUp
        case redeem(GiftCardRedeem.Action)
        case scan(Scan.Action)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.giftCard) var giftCard

    init() { }

    var body: some Reducer<State, Action> {
        Scope(state: \.scanState, action: \.scan) {
            Scan()
        }

        coordinatorReduce()
            .ifLet(\.redeemState, action: \.redeem) {
                GiftCardRedeem()
            }
    }
}

extension Scan.State {
    /// The scanner as the gift card flow uses it: gift card links only, plus "Paste link".
    static var giftCardScanner: Scan.State {
        var state = Scan.State.initial
        state.checkers = [.giftCardScanChecker]
        state.isPasteEnabled = true
        state.instructions = String(localizable: .giftCardScanInstructions)
        return state
    }

    /// The gift card scanner opened for a gift card link that came from outside the app, which is
    /// not used: it explains why the card has to be scanned again.
    static var giftCardRescanner: Scan.State {
        var state = Scan.State.giftCardScanner
        state.instructions = String(localizable: .giftCardRescanInstructions)
        return state
    }
}
