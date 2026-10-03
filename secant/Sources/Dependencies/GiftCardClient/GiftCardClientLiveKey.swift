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
                guard let session = await registry.session(for: handle) else {
                    throw GiftCardClientError.unknownHandle
                }
                // Broadcast-sensitive: the sweep must never overlap a server switch, exactly like the
                // wallet's own sends (see AGENTS.md, "Transaction guard"). The guard is taken here,
                // once, and never by callers.
                @Dependency(\.transactionGuard) var transactionGuard
                do {
                    return try await transactionGuard.withSubmission(timeout: submissionGuardTimeout) {
                        try await session.sendAll(to: toAddress)
                    }
                } catch let error as GiftCardClientError {
                    throw error
                } catch {
                    LoggerProxy.error("[GiftCard] redeem failed: \(error.localizedDescription)")
                    throw GiftCardClientError.redeemFailed
                }
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
        let session = GiftCardRedeemerSession(redeemer: redeemer, networkType: network.networkType)

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
    /// Sends everything, minus the fee, to `address` and returns the transaction id.
    func sendAll(to address: String) async throws -> String
    /// Stops the card's synchronizer and deletes its files.
    func close() async
}

/// `GiftCardSession` over the wallet SDK's `GiftCardRedeemer`.
struct GiftCardRedeemerSession: GiftCardSession {
    let redeemer: GiftCardRedeemer
    let networkType: NetworkType

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

        let outcome: GiftCardRedeemer.SubmissionOutcome
        do {
            outcome = try await redeemer.redeemReportingOutcome(to: recipient)
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerCleanedUp {
            throw GiftCardClientError.unknownHandle
        } catch ZcashError.giftCardNothingToRedeem {
            // Checked as ready, but nothing is spendable any more: the card was redeemed elsewhere
            // meanwhile, or an earlier submission of this redeemer failed and the notes are locked
            // until that transaction expires. Nothing was broadcast now.
            LoggerProxy.error("[GiftCard] nothing to redeem")
            throw GiftCardClientError.redeemFailed
        }

        for failure in outcome.failures {
            LoggerProxy.error("[GiftCard] \(failure)")
        }
        guard let txId = outcome.txId else {
            throw GiftCardClientError.redeemFailed
        }
        return txId
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
    func redeemReportingOutcome(to recipient: UnifiedAddress) async throws -> SubmissionOutcome {
        let results = try await redeem(to: recipient)
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
