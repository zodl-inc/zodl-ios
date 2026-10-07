//
//  GiftCardPasteLinkStore.swift
//  Zodl
//
//  Created by Zodl on 2026-10-06.
//

import Foundation
import ComposableArchitecture

/// "Paste your gift card link": the way into the redeem flow for a card whose link the user has
/// as text. The field takes a paste (from its own Paste button or the keyboard) or typing, and
/// Continue is enabled only for text the gift card client accepts as a card link.
///
/// The link is a bearer secret: it lives only in `state.text` (redacted) and is never logged.
/// On Clear or leaving the screen (Continue, back, or the flow's cleanup), the clipboard is cleared only
/// while it still holds the same text: what the Paste button took when it holds a card's link or
/// key anywhere in it, even when it is not a link Continue accepts, and the field's text when it
/// holds one, which covers a paste from the keyboard or a long press.
@Reducer
struct GiftCardPasteLink {
    @ObservableState
    struct State: Equatable {
        /// The field's text, as entered.
        var text: RedactableString = .empty
        /// Sensitive text this screen took from the clipboard; forgotten on Clear or leaving.
        var pastedLink: RedactableString?
        /// Whether `text` is a gift card link that can be opened (enables Continue).
        var isValid = false
        /// Whether `text` cannot be a gift card link (marks the field and shows the error).
        var isInvalid = false

        init() { }
    }

    enum Action: Equatable {
        case backTapped
        case clearTapped
        case continueTapped
        case delegate(Delegate)
        case pasteTapped
        case textChanged(RedactableString)

        @CasePathable
        enum Delegate: Equatable {
            /// Back to the scanner.
            case back
            /// Open the card behind this link.
            case open(RedactableString)
        }
    }

    @Dependency(\.giftCard) var giftCard
    @Dependency(\.pasteboard) var pasteboard

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .pasteTapped:
                guard let pasted = pasteboard.getString(), !pasted.data.isEmpty else {
                    return .none
                }
                let text = pasted.data.trimmingCharacters(in: .whitespacesAndNewlines)
                // Anything pasted that holds a card's secret, even inside other text, is cleared
                // from the clipboard on Clear or leaving. The clipboard is matched against the original,
                // untrimmed value.
                if giftCard.isGiftCardLink(text) || GiftCardSecretDetector.mayContainGiftCardSecret(text) {
                    state.pastedLink = pasted
                }
                update(&state, text: text)
                return .none

            case .textChanged(let text):
                update(&state, text: text.data)
                return .none

            case .clearTapped:
                clearClipboard(&state)
                update(&state, text: "")
                return .none

            case .continueTapped:
                guard state.isValid else {
                    return .none
                }
                let link = state.text.data.trimmingCharacters(in: .whitespacesAndNewlines).redacted
                clearClipboard(&state)
                update(&state, text: "")
                return .send(.delegate(.open(link)))

            case .backTapped:
                clearClipboard(&state)
                update(&state, text: "")
                return .send(.delegate(.back))

            case .delegate:
                return .none
            }
        }
    }
}

extension GiftCardPasteLink {
    private func update(_ state: inout State, text: String) {
        state.text = text.redacted
        let isValid = isOpenable(text)
        state.isValid = isValid
        state.isInvalid = !isValid && !GiftCardLink.isCandidatePrefix(text)
    }

    /// A link Continue can open: recognized by the gift card client and not rejected by its parser
    /// as damaged. A newer link format or a card for another network still opens, so the redeem
    /// screen can explain why it cannot be redeemed here.
    private func isOpenable(_ text: String) -> Bool {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard giftCard.isGiftCardLink(link) else {
            return false
        }
        do {
            _ = try giftCard.parse(link)
            return true
        } catch GiftCardClientError.notAGiftCardLink, GiftCardClientError.invalidLink {
            return false
        } catch {
            return true
        }
    }

    private func clearClipboard(_ state: inout State) {
        for value in state.clipboardValuesToClear {
            pasteboard.clearIfMatches(value)
        }
        state.pastedLink = nil
    }
}

extension GiftCardPasteLink.State {
    /// What Clear or leaving the screen clears from the clipboard, if it still holds it: the
    /// text the Paste button took, and the field's text when it holds a card's link or key.
    var clipboardValuesToClear: [RedactableString] {
        var values: [RedactableString] = []
        if let pastedLink {
            values.append(pastedLink)
        }
        if !values.contains(text), GiftCardSecretDetector.mayContainGiftCardSecret(text.data) {
            values.append(text)
        }
        return values
    }
}
