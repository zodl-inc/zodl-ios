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
                // TODO: [gift-cards] Wire to the wallet SDK's gift card link parser once it ships
                // (origin, network, birthday height, stated amount, message; the secret stays
                // inside the SDK). Map its errors onto `GiftCardClientError`:
                // NotAGiftLink → .notAGiftCardLink, UnsupportedVersion → .unsupportedVersion,
                // Missing/Duplicate/InvalidField, TooLong, KeyDerivation → .invalidLink,
                // UnsupportedNetwork/NetworkMismatch → .networkMismatch.
                guard GiftCardLink.isCandidate(link) else {
                    throw GiftCardClientError.notAGiftCardLink
                }
                throw GiftCardClientError.unavailable
            },
            open: { link in
                // TODO: [gift-cards] Wire to the wallet SDK's gift card redeemer: create it for
                // `link` (isolated temporary synchronizer, same network and lightwalletd endpoint as
                // the wallet), wrap it in a `GiftCardSession` and `await registry.insert(session)`.
                // If the calling task was cancelled meanwhile, close the session instead of
                // registering it so a card left behind by a dismissed screen is never kept open.
                guard GiftCardLink.isCandidate(link) else {
                    throw GiftCardClientError.notAGiftCardLink
                }
                LoggerProxy.event("[GiftCard] open requested but gift card support is not available in this build")
                throw GiftCardClientError.unavailable
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

/// Keeps the open cards. At most one card is open at a time: inserting a new session closes the
/// others, so a card whose screen went away without cleaning up cannot linger.
actor GiftCardSessionRegistry {
    static let shared = GiftCardSessionRegistry()

    private var sessions: [GiftCardHandle: any GiftCardSession] = [:]

    func insert(_ session: any GiftCardSession) async -> GiftCardHandle {
        let previous = sessions
        sessions.removeAll()
        for (_, old) in previous {
            await old.close()
        }
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
}
