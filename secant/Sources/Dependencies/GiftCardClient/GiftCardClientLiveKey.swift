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
                    LoggerProxy.error("[GiftCard] check failed: \(Self.logDescription(of: error))")
                    throw GiftCardClientError.checkFailed
                }
            },
            redeem: { handle, toAddress in
                try await Self.redeem(handle, to: toAddress, registry: registry)
            },
            cleanup: { handle in
                await registry.close(handle)
            },
            removeLeftoverWallets: {
                Self.removeLeftoverWallets()
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

    /// Maps the SDK's parse failure onto `GiftCardClientError`. The SDK validates the link and
    /// reports each cause as its own error; anything else it might throw counts as a damaged link.
    static func parseError(_ error: Error) -> GiftCardClientError {
        guard let error = error as? ZcashError else {
            return .invalidLink
        }
        switch error {
        case .giftCardLinkNotAGiftCard:
            return .notAGiftCardLink
        case .giftCardLinkUnsupportedVersion:
            return .unsupportedVersion
        case .giftCardLinkUnsupportedNetwork:
            return .networkMismatch
        case .giftCardLinkInvalidBirthday, .giftCardLinkInvalid:
            // A birthday the card cannot have (before the card's pool existed) is a damaged or
            // crafted link: syncing from there would scan the chain for nothing.
            return .invalidLink
        default:
            return .invalidLink
        }
    }

    /// Deletes the card wallets an earlier run left behind. The SDK spares any card open now. A
    /// failure is only logged, without the SDK's message: it names the card's wallet directory.
    static func removeLeftoverWallets() {
        do {
            let removed = try GiftCardRedeemer.removeLeftoverWallets()
            if removed > 0 {
                LoggerProxy.event("[GiftCard] removed \(removed) leftover card wallet(s)")
            }
        } catch {
            LoggerProxy.error("[GiftCard] could not remove every leftover card wallet")
        }
    }

    /// What a log line may say about an SDK error: its code, never its message, which can carry
    /// server-provided text.
    static func logDescription(of error: Error) -> String {
        if let error = error as? ZcashError {
            return error.code.rawValue
        }
        return String(describing: type(of: error))
    }

    /// Opens the card's wallet and registers it. The card wallet is a second synchronizer next to
    /// the wallet's own, set up like it (see `GiftCardRedeemerSettings`): same network, the
    /// lightwalletd server the wallet is currently configured with, and the wallet's Tor choice,
    /// so a wallet on protected access syncs and redeems the card over Tor too.
    private static func open(_ link: String, registry: GiftCardSessionRegistry) async throws -> GiftCardHandle {
        let ownership = await registry.reserve()
        try Task.checkCancellation()
        guard await registry.isCurrent(ownership) else { throw CancellationError() }
        guard GiftCardLink.isCandidate(link) else {
            throw GiftCardClientError.notAGiftCardLink
        }
        let card = try Self.parseCard(link)

        let settings = GiftCardRedeemerSettings.current()
        guard card.network == settings.network.networkType else {
            throw GiftCardClientError.networkMismatch
        }

        let redeemer = try await Self.makeRedeemer(card: card, settings: settings, registry: registry, ownership: ownership)
        let session = GiftCardRedeemerSession(redeemer: redeemer, card: card, settings: settings)

        // A screen that went away while the card was being opened must not leave the card's
        // wallet behind: close it instead of registering it.
        guard !Task.isCancelled else {
            await session.close()
            throw CancellationError()
        }
        LoggerProxy.event("[GiftCard] opened the card wallet")
        let handle = await registry.insert(session, ownership: ownership)
        if Task.isCancelled {
            await registry.close(handle)
            throw CancellationError()
        }
        guard await registry.session(for: handle) != nil else { throw CancellationError() }
        return handle
    }

    /// Creates the card's redeemer. The SDK allows one redeemer per card in the process; if one is
    /// still alive (a card opened by a screen that went away before cleaning up), every session
    /// the registry still holds is closed and the creation is retried once.
    private static func makeRedeemer(
        card: GiftCard,
        settings: GiftCardRedeemerSettings,
        registry: GiftCardSessionRegistry,
        ownership: UUID
    ) async throws -> GiftCardRedeemer {
        do {
            do {
                return try settings.makeRedeemer(for: card)
            } catch ZcashError.giftCardRedeemerAlreadyActive {
                await registry.closeAll(ownership: ownership)
                try Task.checkCancellation()
                guard await registry.isCurrent(ownership) else { throw CancellationError() }
                return try settings.makeRedeemer(for: card)
            }
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerAlreadyActive {
            LoggerProxy.error("[GiftCard] the card is still open elsewhere; try again once it is closed")
            throw GiftCardClientError.checkFailed
        } catch {
            LoggerProxy.error("[GiftCard] could not create the card wallet: \(Self.logDescription(of: error))")
            throw GiftCardClientError.checkFailed
        }
    }

    /// Sweeps the card into `toAddress`. Broadcast-sensitive: the sweep must never overlap a server
    /// switch, exactly like the wallet's own sends (see AGENTS.md, "Transaction guard"). The guard
    /// is taken here, once, and never by callers.
    ///
    /// The claim is recorded in the wallet's own synchronizer as a trusted incoming transaction
    /// (ZIP 315): it shows in history at once and is spendable after 3 confirmations. The SDK
    /// writes it straight to the wallet database, so this works while the main synchronizer is
    /// stopped for the card (see `RootGiftCards`). A claim that could not be recorded is only
    /// logged: the wallet then finds it on chain like any other receive.
    private static func redeem(
        _ handle: GiftCardHandle,
        to toAddress: String,
        registry: GiftCardSessionRegistry
    ) async throws -> GiftCardRedemption {
        guard let session = await registry.session(for: handle) else {
            throw GiftCardClientError.unknownHandle
        }
        @Dependency(\.transactionGuard) var transactionGuard
        @Dependency(\.sdkSynchronizer) var sdkSynchronizer
        let mainWallet = sdkSynchronizer.mainWalletSynchronizer().map(GiftCardClaimDestination.init)
        let requested = Date()
        LoggerProxy.event("[GiftCard] redeem: waiting for the transaction guard")
        do {
            return try await transactionGuard.withSubmission(timeout: submissionGuardTimeout) {
                let acquired = Date()
                LoggerProxy.event("[GiftCard] redeem: guard acquired after \(Int(acquired.timeIntervalSince(requested)))s")
                let sweep = try await session.sendAll(to: toAddress, recordIn: mainWallet)
                LoggerProxy.event("[GiftCard] redeem: swept after \(Int(Date().timeIntervalSince(acquired)))s")
                if !sweep.recordedInMainWallet {
                    LoggerProxy.warn("[GiftCard] redeem: the claim was not recorded in the wallet; it will show once synced")
                }
                return GiftCardRedemption(txId: sweep.txId, received: sweep.received)
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
            LoggerProxy.error("[GiftCard] redeem failed: \(Self.logDescription(of: error))")
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
            LoggerProxy.error("[GiftCard] could not reopen the card wallet after a failed submission: \(Self.logDescription(of: error))")
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
        case .legacyV1, .legacyV2, .legacyV3:
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
    /// Sends everything, minus the fee, to `address`, records the accepted claim in `mainWallet`
    /// (the synchronizer of the wallet `address` belongs to) as a trusted incoming transaction, and
    /// returns what happened. Throws `GiftCardSubmissionFailed` when a transaction was created but
    /// no server accepted it: the session is then spent and must be replaced with `reopen()`
    /// before another attempt. Failing to record never throws.
    func sendAll(to address: String, recordIn mainWallet: GiftCardClaimDestination?) async throws -> GiftCardSweep
    /// Closes this session and returns a fresh one for the same card, which checks and sweeps the
    /// card anew. Used after a failed submission; see `sendAll`.
    func reopen() async throws -> any GiftCardSession
    /// Stops the card's synchronizer and deletes its files.
    func close() async
}

/// The wallet's own synchronizer, carried to the card's redeemer so it can record the claim there.
/// `Synchronizer` is not `Sendable`, but the SDK's synchronizers are made to be called from any
/// task (the app's `SDKSynchronizerClient` closures share one the same way), and the redeemer only
/// calls `recordGiftCardClaim` on it, which goes straight to the wallet database.
struct GiftCardClaimDestination: @unchecked Sendable {
    let synchronizer: any Synchronizer
}

/// A sweep a server accepted.
struct GiftCardSweep: Equatable, Sendable {
    /// The id of the first transaction a server accepted.
    let txId: String
    /// Whether the wallet's own synchronizer stored the claim as a trusted receive. When it did not,
    /// the wallet learns about the claim from the chain, as an ordinary receive.
    let recordedInMainWallet: Bool
    /// What the wallet receives, after the fee, as the sweep's proposal computed it; `nil` when
    /// not known.
    var received: Zatoshi?
}

/// How the card's wallet is set up: like the wallet's own synchronizer, so that opening a card
/// changes nothing about how this device reaches the network.
struct GiftCardRedeemerSettings: Sendable {
    /// The card wallet logs nothing, as the SDK defaults to: its log would hold the transaction
    /// that links the card to the user's address.
    static let loggingPolicy = Initializer.LoggingPolicy.noLogging

    let network: ZcashNetwork
    /// The lightwalletd server the wallet is configured with right now.
    let endpoint: LightWalletEndpoint
    /// The wallet's Tor choice (protected access): the stored flag the main synchronizer is built
    /// with, and which the Tor setting updates together with the running synchronizer.
    let isTorEnabled: Bool

    /// The settings of the wallet's own synchronizer, as they are now.
    static func current() -> Self {
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        @Dependency(\.walletStorage) var walletStorage
        return Self(
            network: zcashSDKEnvironment.network(),
            endpoint: zcashSDKEnvironment.endpoint(),
            isTorEnabled: walletStorage.exportTorSetupFlag() ?? false
        )
    }

    func makeRedeemer(for card: GiftCard) throws -> GiftCardRedeemer {
        try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: endpoint,
            isTorEnabled: isTorEnabled,
            loggingPolicy: Self.loggingPolicy
        )
    }
}

/// A sweep whose transaction was created but not accepted by any server. The card wallet holds
/// its notes as spent until the transaction expires, so the same redeemer cannot sweep again.
struct GiftCardSubmissionFailed: Error { }

/// `GiftCardSession` over the wallet SDK's `GiftCardRedeemer`.
struct GiftCardRedeemerSession: GiftCardSession {
    let redeemer: GiftCardRedeemer
    /// Kept so that `reopen()` can create a redeemer for the same card, set up the same way.
    let card: GiftCard
    let settings: GiftCardRedeemerSettings

    var networkType: NetworkType { settings.network.networkType }

    /// The memo the sweep carries to the user's own wallet: a fixed label, then the sender's
    /// message when the card has one. Trimmed on a character boundary to fit a memo. `message` is
    /// the card's `GiftCard.message`, which the SDK has already sanitized (no control or
    /// direction-changing characters).
    static func redeemMemo(for card: GiftCard) -> Memo? {
        redeemMemo(message: card.message)
    }

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
        return Self.appStatus(status)
    }

    /// The SDK's view of a card, as the redeem screen shows it. A ready card's `redeemable` is what
    /// the SDK's own proposal of the redemption sends, after the fee its notes require.
    static func appStatus(_ status: ZcashLightClientKit.GiftCardStatus) -> GiftCardStatus {
        switch status.state {
        case .ready:
            return .ready(spendable: status.spendable, redeemable: status.redeemable)
        case .pending:
            // The SDK does not say how many confirmations are still missing; funds from another
            // wallet need 10, and the pending screen re-checks on its own.
            return .pending(amount: status.pending, confirmationsNeeded: nil)
        case .dust:
            // The fee would take everything the card holds.
            return .dust
        case .empty:
            return .empty
        }
    }

    func sendAll(to address: String, recordIn mainWallet: GiftCardClaimDestination?) async throws -> GiftCardSweep {
        guard let recipient = try? UnifiedAddress(encoding: address, network: networkType) else {
            LoggerProxy.error("[GiftCard] the redeem address is not a unified address of this network")
            throw GiftCardClientError.redeemFailed
        }

        // The sweep carries a memo so the incoming transaction explains itself in the user's
        // history: a fixed label plus the sender's message from the card, trimmed to the memo
        // size on a character boundary. The memo is encrypted to the user's own address.
        let memo = Self.redeemMemo(for: card)

        let outcome: GiftCardRedeemer.SubmissionOutcome
        do {
            outcome = try await redeemer.redeemReportingOutcome(to: recipient, memo: memo, recordIn: mainWallet)
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerCleanedUp {
            throw GiftCardClientError.unknownHandle
        } catch ZcashError.giftCardNothingToRedeem {
            // Checked as ready, but nothing worth sending is spendable any more: the card was
            // redeemed elsewhere meanwhile, or the fee would take it all. Nothing was created or
            // broadcast, so the session stays usable, but retrying cannot help.
            LoggerProxy.event("[GiftCard] nothing to redeem")
            throw GiftCardClientError.nothingToRedeem
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
            LoggerProxy.error("[GiftCard] redeem failed: \(GiftCardClient.logDescription(of: error))")
            throw GiftCardSubmissionFailed()
        }

        for failure in outcome.failures {
            LoggerProxy.error("[GiftCard] \(failure)")
        }
        guard let txId = outcome.txId else {
            throw GiftCardSubmissionFailed()
        }
        return GiftCardSweep(txId: txId, recordedInMainWallet: outcome.recordedInDestination, received: outcome.received)
    }

    func reopen() async throws -> any GiftCardSession {
        await close()
        let replacement: GiftCardRedeemer
        do {
            replacement = try settings.makeRedeemer(for: card)
        } catch ZcashError.giftCardNetworkMismatch {
            throw GiftCardClientError.networkMismatch
        } catch ZcashError.giftCardRedeemerAlreadyActive {
            throw GiftCardClientError.checkFailed
        }
        return GiftCardRedeemerSession(redeemer: replacement, card: card, settings: settings)
    }

    func close() async {
        do {
            try await redeemer.cleanup()
        } catch {
            LoggerProxy.error("[GiftCard] cleanup of the card wallet failed: \(GiftCardClient.logDescription(of: error))")
        }
    }
}

extension GiftCardRedeemer {
    /// What a sweep came to, reduced to values that can leave the redeemer's isolation.
    struct SubmissionOutcome: Sendable {
        /// The id of the first transaction a server accepted, if any.
        let txId: String?
        /// One line per transaction that was not accepted; never contains the link, nor any text
        /// the server sent back.
        let failures: [String]
        /// Whether the destination synchronizer stored the accepted claim as a trusted receive.
        let recordedInDestination: Bool
        /// What the recipient receives, after the fee, as the redemption's proposal computed it;
        /// `nil` when it is not positive.
        let received: Zatoshi?
    }

    /// `redeem(to:memo:recordIn:)`, with its results reduced on the actor: the SDK's submit
    /// results are not `Sendable`, so they must not cross back to the caller.
    func redeemReportingOutcome(
        to recipient: UnifiedAddress,
        memo: Memo?,
        recordIn destination: GiftCardClaimDestination?
    ) async throws -> SubmissionOutcome {
        let redemption = try await redeem(to: recipient, memo: memo, recordIn: destination?.synchronizer)
        let results = redemption.results
        var txId: String?
        var failures: [String] = []
        for result in results {
            if case .success(let id) = result {
                txId = txId ?? id.toHexStringTxId()
            } else if let failure = Self.failureDescription(of: result) {
                failures.append(failure)
            }
        }
        return SubmissionOutcome(
            txId: txId,
            failures: failures,
            recordedInDestination: redemption.recordedInDestination,
            received: redemption.amount > .zero ? redemption.amount : nil
        )
    }

    /// A log line for a submission no server accepted, `nil` for an accepted one. A server's
    /// rejection text is left out: it is not ours to vouch for, and can quote the transaction.
    static func failureDescription(of result: TransactionSubmitResult) -> String? {
        switch result {
        case .success:
            return nil
        case .grpcFailure:
            return "submission failed: transport error"
        case .submitFailure(_, let code, _):
            return "submission rejected (\(code))"
        case .notAttempted:
            return "submission not attempted"
        }
    }
}

/// Keeps the open cards. At most one card is open at a time: inserting a new session closes the
/// others, so a card whose screen went away without cleaning up cannot linger.
actor GiftCardSessionRegistry {
    static let shared = GiftCardSessionRegistry()

    private var sessions: [GiftCardHandle: any GiftCardSession] = [:]
    private var ownership = UUID()

    /// Reserve before creating a session: completion order must never choose the owner.
    func reserve() async -> UUID {
        let token = UUID()
        guard !Task.isCancelled else { return token }
        ownership = token
        await closeRegisteredSessions()
        return token
    }

    func isCurrent(_ token: UUID) -> Bool {
        ownership == token
    }

    func insert(_ session: any GiftCardSession) async -> GiftCardHandle {
        let token = await reserve()
        return await insert(session, ownership: token)
    }

    func insert(_ session: any GiftCardSession, ownership token: UUID) async -> GiftCardHandle {
        let handle = GiftCardHandle()
        guard isCurrent(token), !Task.isCancelled else {
            await session.close()
            return handle
        }
        sessions[handle] = session
        return handle
    }

    func session(for handle: GiftCardHandle) -> (any GiftCardSession)? {
        sessions[handle]
    }

    /// The caller has already closed the previous session when reopening it.
    func replace(_ handle: GiftCardHandle, with session: any GiftCardSession) async -> Bool {
        guard sessions[handle] != nil, !Task.isCancelled else {
            await session.close()
            return false
        }
        sessions[handle] = session
        return true
    }

    func close(_ handle: GiftCardHandle) async {
        guard let session = sessions.removeValue(forKey: handle) else { return }
        await session.close()
    }

    func closeAll(ownership token: UUID) async {
        guard isCurrent(token), !Task.isCancelled else { return }
        await closeRegisteredSessions()
    }

    func closeAll() async {
        ownership = UUID()
        await closeRegisteredSessions()
    }

    private func closeRegisteredSessions() async {
        let previous = sessions
        sessions.removeAll()
        for (_, old) in previous {
            await old.close()
        }
    }
}
