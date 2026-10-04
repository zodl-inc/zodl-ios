//
//  GiftCardClientLiveKey.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension GiftCardClient: DependencyKey {
    static let liveValue = Self.live()

    static func live(registry: GiftCardSessionRegistry = .shared) -> Self {
        Self(
            isGiftCardLink: { GiftCardLink.isCandidate($0) },
            parse: { link in
                guard GiftCardLink.isCandidate(link) else {
                    throw GiftCardClientError.notAGiftCardLink
                }
                return GiftCardSummary(card: try Self.parseCard(link))
            },
            open: { link in
                try await Self.open(link, registry: registry)
            },
            progress: { handle in
                AsyncStream { continuation in
                    let task = Task {
                        guard let session = await registry.session(for: handle) else {
                            continuation.finish()
                            return
                        }
                        for await value in session.progress() {
                            continuation.yield(value)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            check: { handle in
                guard let session = await registry.session(for: handle) else {
                    throw GiftCardClientError.unknownHandle
                }
                do {
                    return try await session.status()
                } catch let error as GiftCardClientError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    LoggerProxy.error("[GiftCard] check failed: \(error.localizedDescription)")
                    throw GiftCardClientError.checkFailed
                }
            },
            redeem: { handle, toAddress in
                try await Self.redeem(handle, to: toAddress, registry: registry)
            },
            cleanup: { handle in
                await registry.close(handle)
            }
        )
    }
}

// MARK: - SDK adapters

extension GiftCardClient {
    /// Reads a link with the wallet SDK. Throws `GiftCardClientError`; the SDK's messages name the
    /// problem and never contain the link.
    static func parseCard(_ link: String) throws -> GiftCard {
        do {
            return try GiftCard(link: link)
        } catch {
            throw Self.parseError(error)
        }
    }

    /// Maps the SDK's parse failure onto `GiftCardClientError`. The SDK reports every parse failure
    /// as `rustParseGiftCardLink` with a fixed message per cause (`rust/src/gift.rs` in the SDK):
    /// not a link at all, an unsupported link version, a card for another network, or a damaged
    /// link (missing, repeated, invalid or oversized fields, or a key that cannot be derived).
    static func parseError(_ error: Error) -> GiftCardClientError {
        guard case ZcashError.rustParseGiftCardLink(let message) = error else {
            return .invalidLink
        }
        let reason = message.lowercased()
        if reason.contains("not a gift card link") {
            return .notAGiftCardLink
        }
        if reason.contains("unsupported gift card link version") {
            return .unsupportedVersion
        }
        if reason.contains("unsupported network") || reason.contains("different network") {
            return .networkMismatch
        }
        return .invalidLink
    }

    /// Opens the card's wallet and registers it. The card wallet is a second synchronizer next to
    /// the wallet's own: same network, and the lightwalletd server the wallet is currently
    /// configured with (the user's manual choice, or the one the automatic selection last
    /// applied). It never uses Tor, so a wallet on protected access syncs and redeems the card
    /// directly.
    private static func open(_ link: String, registry: GiftCardSessionRegistry) async throws -> GiftCardHandle {
        guard GiftCardLink.isCandidate(link) else {
            throw GiftCardClientError.notAGiftCardLink
        }
        let card = try Self.parseCard(link)

        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        let network = zcashSDKEnvironment.network()
        guard card.network == network.networkType else {
            throw GiftCardClientError.networkMismatch
        }
        let endpoint = zcashSDKEnvironment.endpoint()

        let redeemer = try await Self.makeRedeemer(card: card, network: network, endpoint: endpoint, registry: registry)
        let session = GiftCardRedeemerSession(redeemer: redeemer, card: card, network: network, endpoint: endpoint)

        // A screen that went away while the card was being opened must not leave the card's
        // wallet behind: close it instead of registering it.
        guard !Task.isCancelled else {
            await session.close()
            throw CancellationError()
        }
        LoggerProxy.event("[GiftCard] opened card wallet \(redeemer.alias)")
        return await registry.insert(session)
    }

    /// Creates the card's redeemer. The SDK allows one redeemer per card in the process; if one is
    /// still alive (a card opened by a screen that went away before cleaning up), every session
    /// the registry still holds is closed and the creation is retried once.
    private static func makeRedeemer(
        card: GiftCard,
        network: ZcashNetwork,
        endpoint: LightWalletEndpoint,
        registry: GiftCardSessionRegistry
    ) async throws -> GiftCardRedeemer {
        do {
            do {
                return try GiftCardRedeemer(card: card, network: network, endpoint: endpoint)
            } catch ZcashError.giftCardRedeemerAlreadyActive {
                await registry.closeAll()
                return try GiftCardRedeemer(card: card, network: network, endpoint: endpoint)
            }
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerAlreadyActive {
            LoggerProxy.error("[GiftCard] the card is still open elsewhere; try again once it is closed")
            throw GiftCardClientError.checkFailed
        } catch {
            LoggerProxy.error("[GiftCard] could not create the card wallet: \(error.localizedDescription)")
            throw GiftCardClientError.checkFailed
        }
    }

    /// Sweeps the card into `toAddress`. Broadcast-sensitive: the sweep must never overlap a server
    /// switch, exactly like the wallet's own sends (see AGENTS.md, "Transaction guard"). The guard
    /// is taken here, once, and never by callers.
    private static func redeem(_ handle: GiftCardHandle, to toAddress: String, registry: GiftCardSessionRegistry) async throws -> String {
        guard let session = await registry.session(for: handle) else {
            throw GiftCardClientError.unknownHandle
        }
        @Dependency(\.transactionGuard) var transactionGuard
        do {
            return try await transactionGuard.withSubmission(timeout: submissionGuardTimeout) {
                try await session.sendAll(to: toAddress)
            }
        } catch let error as GiftCardClientError {
            throw error
        } catch is GiftCardSubmissionFailed {
            // The card wallet now treats the notes as spent until the transaction expires, so this
            // session cannot sweep again. Swap in a fresh one under the same handle: the screen's
            // Retry re-checks the card through that handle and finds the funds still there (or
            // gone, if the broadcast did land after all).
            await Self.replaceAfterFailedSubmission(handle, session: session, registry: registry)
            throw GiftCardClientError.redeemFailed
        } catch {
            LoggerProxy.error("[GiftCard] redeem failed: \(error.localizedDescription)")
            throw GiftCardClientError.redeemFailed
        }
    }

    /// Replaces `session`, whose last sweep was created but not accepted, with a fresh session for
    /// the same card under the same handle. If the card was closed meanwhile (the flow was left),
    /// the replacement is closed again instead of being registered. If no replacement can be made,
    /// the handle is dropped: the next `check` reports it unknown and the screen starts over.
    private static func replaceAfterFailedSubmission(
        _ handle: GiftCardHandle,
        session: any GiftCardSession,
        registry: GiftCardSessionRegistry
    ) async {
        do {
            let replacement = try await session.reopen()
            if await registry.replace(handle, with: replacement) {
                LoggerProxy.event("[GiftCard] reopened the card wallet after a failed submission")
            }
        } catch {
            LoggerProxy.error("[GiftCard] could not reopen the card wallet after a failed submission: \(error.localizedDescription)")
            await registry.close(handle)
        }
    }
}

extension GiftCardSummary {
    init(card: GiftCard) {
        let origin: Origin
        switch card.origin {
        case .zodl:
            origin = .zodl
        case .vizorV1, .vizorV2, .vizorV3:
            origin = .vizor
        }
        self.init(
            origin: origin,
            networkType: card.network,
            birthdayHeight: card.birthdayHeight,
            statedAmount: card.statedAmount,
            message: card.message
        )
    }
}

/// One opened card, as the app needs it. The live wiring adapts the wallet SDK's gift card
/// redeemer to this protocol, which keeps the SDK surface the app depends on this small.
protocol GiftCardSession: Sendable {
    /// Sync progress in `0...1`; finishes when the sync is done.
    func progress() -> AsyncStream<Double>
    /// Syncs (if needed) and reports what the card holds.
    func status() async throws -> GiftCardStatus
    /// Sends everything, minus the fee, to `address` and returns the transaction id. Throws
    /// `GiftCardSubmissionFailed` when a transaction was created but no server accepted it: the
    /// session is then spent and must be replaced with `reopen()` before another attempt.
    func sendAll(to address: String) async throws -> String
    /// Closes this session and returns a fresh one for the same card, which checks and sweeps the
    /// card anew. Used after a failed submission; see `sendAll`.
    func reopen() async throws -> any GiftCardSession
    /// Stops the card's synchronizer and deletes its files.
    func close() async
}

/// A sweep whose transaction was created but not accepted by any server. The card wallet holds
/// its notes as spent until the transaction expires, so the same redeemer cannot sweep again.
struct GiftCardSubmissionFailed: Error { }

/// `GiftCardSession` over the wallet SDK's `GiftCardRedeemer`.
struct GiftCardRedeemerSession: GiftCardSession {
    let redeemer: GiftCardRedeemer
    /// Kept so that `reopen()` can create a redeemer for the same card, on the same server.
    let card: GiftCard
    let network: ZcashNetwork
    let endpoint: LightWalletEndpoint

    var networkType: NetworkType { network.networkType }

    /// The memo the sweep carries to the user's own wallet: a fixed label, then the sender's
    /// message when the card has one. Trimmed on a character boundary to fit a memo.
    static func redeemMemo(message: String?) -> Memo? {
        let label = String(localizable: .giftCardRedeemMemo)
        var text = label
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            let separator = " · "
            var room = MemoBytes.capacity - label.utf8.count - separator.utf8.count
            var trimmed = message
            while room > 0, trimmed.utf8.count > room {
                trimmed.removeLast()
            }
            if room <= 0 { trimmed = "" }
            if !trimmed.isEmpty {
                text = "\(label)\(separator)\(trimmed)"
            }
        }
        return try? Memo(string: text)
    }

    /// The SDK does not report the card wallet's sync progress (`check()` only returns once the
    /// wallet is up to date), so the stream finishes at once and the screen shows an indeterminate
    /// wait. A card's history is short, so the sync is usually a matter of seconds.
    func progress() -> AsyncStream<Double> {
        AsyncStream { $0.finish() }
    }

    func status() async throws -> GiftCardStatus {
        let status: ZcashLightClientKit.GiftCardStatus
        do {
            status = try await redeemer.check()
        } catch ZcashError.giftCardRedeemerCleanedUp {
            throw GiftCardClientError.unknownHandle
        }
        switch status.state {
        case .ready:
            return .ready(spendable: status.spendable)
        case .pending:
            // The SDK does not say how many confirmations are still missing; funds from another
            // wallet need 10, and the pending screen re-checks on its own.
            return .pending(amount: status.total, confirmationsNeeded: nil)
        case .empty:
            return .empty
        }
    }

    func sendAll(to address: String) async throws -> String {
        guard let recipient = try? UnifiedAddress(encoding: address, network: networkType) else {
            LoggerProxy.error("[GiftCard] the redeem address is not a unified address of this network")
            throw GiftCardClientError.redeemFailed
        }

        // The sweep carries a memo so the incoming transaction explains itself in the user's
        // history: a fixed label plus the sender's message from the card, trimmed to the memo
        // size on a character boundary. The memo is encrypted to the user's own address.
        let memo = Self.redeemMemo(message: card.message)

        let outcome: GiftCardRedeemer.SubmissionOutcome
        do {
            outcome = try await redeemer.redeemReportingOutcome(to: recipient, memo: memo)
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerCleanedUp {
            throw GiftCardClientError.unknownHandle
        } catch ZcashError.giftCardNothingToRedeem {
            // Checked as ready, but nothing is spendable any more: the card was redeemed elsewhere
            // meanwhile. Nothing was created or broadcast now, so the session stays usable.
            LoggerProxy.error("[GiftCard] nothing to redeem")
            throw GiftCardClientError.redeemFailed
        } catch ZcashError.giftCardRedeemerNotReady {
            LoggerProxy.error("[GiftCard] redeem attempted before the card was checked")
            throw GiftCardClientError.redeemFailed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The SDK reports a rejected broadcast as a result, not an error; an error thrown here
            // comes from proposing, creating or submitting the transaction. The transaction may
            // already exist in the card wallet by then, with its notes marked spent, so the
            // session is treated as spent either way: replacing it only costs a short re-sync.
            LoggerProxy.error("[GiftCard] redeem failed: \(error.localizedDescription)")
            throw GiftCardSubmissionFailed()
        }

        for failure in outcome.failures {
            LoggerProxy.error("[GiftCard] \(failure)")
        }
        guard let txId = outcome.txId else {
            throw GiftCardSubmissionFailed()
        }
        return txId
    }

    func reopen() async throws -> any GiftCardSession {
        await close()
        let replacement: GiftCardRedeemer
        do {
            replacement = try GiftCardRedeemer(card: card, network: network, endpoint: endpoint)
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerAlreadyActive {
            throw GiftCardClientError.checkFailed
        }
        return GiftCardRedeemerSession(redeemer: replacement, card: card, network: network, endpoint: endpoint)
    }

    func close() async {
        do {
            try await redeemer.cleanup()
        } catch {
            LoggerProxy.error("[GiftCard] cleanup of \(redeemer.alias) failed: \(error.localizedDescription)")
        }
    }
}

extension GiftCardRedeemer {
    /// What a sweep came to, reduced to values that can leave the redeemer's isolation.
    struct SubmissionOutcome: Sendable {
        /// The id of the first transaction a server accepted, if any.
        let txId: String?
        /// One line per transaction that was not accepted; never contains the link.
        let failures: [String]
    }

    /// `redeem(to:)`, with its results reduced on the actor: the SDK's submit results are not
    /// `Sendable`, so they must not cross back to the caller.
    func redeemReportingOutcome(to recipient: UnifiedAddress, memo: Memo?) async throws -> SubmissionOutcome {
        let results = try await redeem(to: recipient, memo: memo)
        var txId: String?
        var failures: [String] = []
        for result in results {
            switch result {
            case .success(let id):
                txId = txId ?? id.toHexStringTxId()
            case .grpcFailure(_, let error):
                failures.append("submission failed: \(error.localizedDescription)")
            case let .submitFailure(_, code, description):
                failures.append("submission rejected (\(code)): \(description)")
            case .notAttempted:
                failures.append("submission not attempted")
            }
        }
        return SubmissionOutcome(txId: txId, failures: failures)
    }
}

/// Keeps the open cards. At most one card is open at a time: inserting a new session closes the
/// others, so a card whose screen went away without cleaning up cannot linger.
actor GiftCardSessionRegistry {
    static let shared = GiftCardSessionRegistry()

    private var sessions: [GiftCardHandle: any GiftCardSession] = [:]

    func insert(_ session: any GiftCardSession) async -> GiftCardHandle {
        await closeAll()
        let handle = GiftCardHandle()
        sessions[handle] = session
        return handle
    }

    func session(for handle: GiftCardHandle) -> (any GiftCardSession)? {
        sessions[handle]
    }

    /// Swaps the session kept under `handle` for `session`. The previous session is not closed
    /// here: the caller has closed it already. Returns `false`, after closing `session`, when
    /// `handle` is no longer open, so a card closed while its replacement was being made cannot
    /// come back to life.
    func replace(_ handle: GiftCardHandle, with session: any GiftCardSession) async -> Bool {
        guard sessions[handle] != nil else {
            await session.close()
            return false
        }
        sessions[handle] = session
        return true
    }

    func close(_ handle: GiftCardHandle) async {
        guard let session = sessions.removeValue(forKey: handle) else {
            return
        }
        await session.close()
    }

    func closeAll() async {
        let previous = sessions
        sessions.removeAll()
        for (_, old) in previous {
            await old.close()
        }
    }
}
