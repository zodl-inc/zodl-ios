#if VOTING_ENABLED
//
//  VotingBroadcastDispatch.swift
//  Zashi
//

import Foundation

/// The guarded dispatch every vote-commitment broadcast attempt goes through: take the transaction
/// guard, re-check that the broadcast is still wanted, then POST — once per attempt, so the
/// back-off sleeps between attempts run with the guard free.
///
/// The re-check exists because the guard is a queue. A broadcast can wait behind a helper-share
/// delivery for seconds, and the helper pool can run dry while it waits — the delivery ahead of it
/// may be the one that empties the pool. A caller's check taken before the wait describes a world
/// that is gone by the time the guard is granted, so `admission` runs inside the guard immediately
/// before the POST of every attempt. Throwing from it refuses that broadcast, and a refusal is never
/// retried whatever error it carries: the error is wrapped for the retry policy and unwrapped again
/// before it leaves, so the caller sees the error `admission` threw.
enum VotingBroadcastDispatch {
    private struct Refusal: Error {
        let underlying: any Error
    }

    static func run(
        transactionGuard: TransactionGuardClient,
        admission: @Sendable () async throws -> Void,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        attempt: () async throws -> TxResult
    ) async throws -> TxResult {
        do {
            return try await retryWithBackoff(isRetryable: isBroadcastRetryable, sleep: sleep) {
                try await transactionGuard.withSubmission {
                    do {
                        try await admission()
                    } catch {
                        throw Refusal(underlying: error)
                    }
                    return try await attempt()
                }
            }
        } catch let refusal as Refusal {
            throw refusal.underlying
        }
    }
}
#endif
