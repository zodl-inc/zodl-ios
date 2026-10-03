//
//  GiftCardClientInterface.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var giftCard: GiftCardClient {
        get { self[GiftCardClient.self] }
        set { self[GiftCardClient.self] = newValue }
    }
}

/// Redeems gift cards: links (usually printed as QR codes) whose fragment carries the spending
/// secret of a small, separately funded wallet. Redeeming sweeps that wallet into the user's own.
///
/// The link is a bearer secret. Nothing behind this client ever logs it, and callers must never
/// log it either: keep it in a `RedactableString` and pass it straight to `parse` and `open`.
///
/// Lifecycle: `parse` (pure, cheap) → `open` (creates the card's own isolated wallet) →
/// `progress` / `check` (syncs it and reports what it holds) → `redeem` (sends everything to an
/// address of the user's wallet) → `cleanup` (always, whenever the flow is left).
@DependencyClient
struct GiftCardClient {
    /// A cheap prefix check used by the scanner and the deep-link router. `true` only means the
    /// text looks like a gift card link; `parse` is what validates it.
    var isGiftCardLink: @Sendable (_ link: String) -> Bool = { _ in false }
    /// Reads a link without touching the network or the disk. Throws `GiftCardClientError`.
    var parse: @Sendable (_ link: String) throws -> GiftCardSummary
    /// Creates the card's isolated, temporary wallet and returns the handle used by every later
    /// call. Only one card is open at a time: opening another one closes the previous one.
    var open: @Sendable (_ link: String) async throws -> GiftCardHandle
    /// Sync progress of the card's wallet in `0...1`. Finishes once `check` has an answer, or
    /// immediately when the handle is unknown.
    var progress: @Sendable (_ handle: GiftCardHandle) -> AsyncStream<Double> = { _ in AsyncStream { $0.finish() } }
    /// Syncs the card's wallet and reports what can be redeemed.
    var check: @Sendable (_ handle: GiftCardHandle) async throws -> GiftCardStatus
    /// Sends everything the card holds, minus the network fee, to `toAddress` and returns the
    /// transaction id. This broadcasts, so the live implementation takes the transaction guard.
    var redeem: @Sendable (_ handle: GiftCardHandle, _ toAddress: String) async throws -> String
    /// Stops the card's wallet and deletes everything stored for it. Safe to call more than once
    /// and with a handle that is already gone.
    var cleanup: @Sendable (_ handle: GiftCardHandle) async -> Void
}

/// What a gift card link says about itself, without its secret.
struct GiftCardSummary: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A link in Zodl's own format (`https://gift.zodl.com/#v=1&key=…`).
        case zodl
        /// A Vizor payment link (`https://link.vizor.cash/payment-links/open#v…=…`).
        case vizor
    }

    let origin: Origin
    let networkType: NetworkType
    /// The height the card was funded at, or just before it; syncing the card starts here.
    let birthdayHeight: BlockHeight
    /// The amount the link says the card holds. Informational only: `check` is authoritative.
    let statedAmount: Zatoshi?
    /// Free text written by whoever made the card. Untrusted: show it verbatim, as the sender's.
    let message: String?
}

/// Opaque reference to a card opened with `GiftCardClient.open`.
struct GiftCardHandle: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// What a synced card holds.
enum GiftCardStatus: Equatable, Sendable {
    /// Funds that can be redeemed right now. `spendable` is what the user receives, after the fee.
    case ready(spendable: Zatoshi)
    /// The card has been funded but the funds need more confirmations before they can be spent.
    case pending(amount: Zatoshi, confirmationsNeeded: Int?)
    /// Nothing to redeem: the card was already redeemed, or it has not been funded yet.
    case empty
}

/// Errors from `GiftCardClient`. They never carry any part of the link.
enum GiftCardClientError: Error, Equatable, Sendable {
    /// The text is not a gift card link at all.
    case notAGiftCardLink
    /// A gift card link this version of the app cannot read (newer format).
    case unsupportedVersion
    /// A gift card link that is damaged or incomplete.
    case invalidLink
    /// A card for a network other than the wallet's (e.g. a testnet card in a mainnet wallet).
    case networkMismatch
    /// The handle does not refer to an open card (already cleaned up).
    case unknownHandle
    /// The card's wallet could not be synced, so its balance is unknown.
    case checkFailed
    /// Redeeming failed; nothing is known to have been broadcast.
    case redeemFailed
    /// This build cannot redeem gift cards (the wallet SDK does not provide it yet).
    case unavailable
}

/// Recognizes gift card links by their prefix. This is not validation, only a fast filter that
/// keeps the scanner from handing arbitrary text to the parser.
enum GiftCardLink {
    static let zodlPrefix = "https://gift.zodl.com/"
    static let vizorPrefix = "https://link.vizor.cash/payment-links/open"
    static let zodlHost = "gift.zodl.com"

    static func isCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasPrefix(trimmed, zodlPrefix) || hasPrefix(trimmed, vizorPrefix)
    }

    /// `true` for a URL the app was opened with that belongs to the gift card flow, whatever
    /// else is in it. Used to keep such URLs away from other handlers (e.g. Flexa).
    static func isGiftCardURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return false
        }
        return url.host?.lowercased() == zodlHost || isCandidate(url.absoluteString)
    }

    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }
}
