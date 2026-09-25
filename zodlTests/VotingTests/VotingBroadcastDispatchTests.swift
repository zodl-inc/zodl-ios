#if VOTING_ENABLED
//
//  VotingBroadcastDispatchTests.swift
//  zodlTests
//
//  A vote-commitment broadcast takes the transaction guard per attempt, and the guard is a queue:
//  while a helper-share delivery holds it, the broadcast waits. The helper pool can run dry during
//  that wait — the delivery ahead of the broadcast may be the one that empties it — so the
//  exhaustion check has to be re-taken after the guard is granted and before the POST, on every
//  attempt. These tests drive the production dispatch with a real `TransactionGuard` (the actor
//  the live key wraps) and a real `VotingShareServerPool`; only the POST is a recording fake.
//

import Foundation
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(3)))
struct VotingBroadcastDispatchTests {
    private static let servers = ["https://helper-a.example", "https://helper-b.example"]

    @Test func aBroadcastQueuedBehindAFailingDeliveryIsRefusedOnceThePoolIsEmpty() async throws {
        let guardActor = TransactionGuard()
        let events = SignalledRecords<String>()
        let transactionGuard = makeGuardClient(guardActor, recording: events)
        let pool = VotingShareServerPool(urls: Self.servers)
        let helperHoldsGuard = ResumableGate()
        let releaseHelper = ResumableGate()
        let admissionParked = ResumableGate()
        let releaseAdmission = ResumableGate()

        // The helper delivery's last attempt owns the guard and is about to fail.
        let helper = Task<Void, Error> {
            try await transactionGuard.withSubmission {
                helperHoldsGuard.open()
                await releaseHelper.wait()
                events.record("helper-failed")
                throw ShareDelegationError.noReachableVoteServers
            }
        }
        await helperHoldsGuard.wait()
        #expect(await guardActor.tryAcquire() == false)

        // The broadcast arrives while the helper holds the guard, so it queues behind it.
        let broadcast = Task<TxResult, Error> {
            try await VotingBroadcastDispatch.run(
                transactionGuard: transactionGuard,
                admission: {
                    events.record("admitted")
                    admissionParked.open()
                    await releaseAdmission.wait()
                    if await pool.isExhausted {
                        throw ShareDelegationError.noReachableVoteServers
                    }
                },
                attempt: {
                    events.record("post")
                    return TxResult(txHash: "tx", code: 0)
                }
            )
        }

        // The broadcast asked for the guard while the helper still holds it, so it is queued. With
        // the check outside the guard it would run its admission first and never reach this point.
        await events.recorded { $0.filter { $0 == "acquire" }.count == 2 }

        // The helper fails and releases the guard; the pool is emptied outside the guard, as
        // `deliverShares` does, while the admitted broadcast is parked before its check.
        releaseHelper.open()
        _ = await helper.result
        await admissionParked.wait()
        await pool.prune(to: [])
        releaseAdmission.open()

        let outcome = await broadcast.result
        #expect(events.values == ["acquire", "acquire", "helper-failed", "admitted"])
        guard case .failure(let error) = outcome else {
            Issue.record("the broadcast must be refused")
            return
        }
        #expect(error as? ShareDelegationError == .noReachableVoteServers)
        // A refusal releases the guard like any other exit.
        #expect(await guardActor.tryAcquire() == true)
    }

    @Test func aRetryReTakesTheAdmissionCheck() async throws {
        let transactionGuard = makeGuardClient(TransactionGuard())
        let pool = VotingShareServerPool(urls: Self.servers)
        let posts = SignalledRecords<Void>()

        let outcome = await Task<TxResult, Error> {
            try await VotingBroadcastDispatch.run(
                transactionGuard: transactionGuard,
                admission: {
                    if await pool.isExhausted {
                        throw ShareDelegationError.noReachableVoteServers
                    }
                },
                sleep: { _ in },
                attempt: {
                    posts.recordCall()
                    // The first POST dies like a dropped connection, and the pool empties before
                    // the retry gets its turn.
                    await pool.prune(to: [])
                    throw URLError(.networkConnectionLost)
                }
            )
        }.result

        #expect(posts.count == 1)
        guard case .failure(let error) = outcome else {
            Issue.record("the retry must be refused")
            return
        }
        #expect(error as? ShareDelegationError == .noReachableVoteServers)
    }

    @Test func aRefusalIsNeverRetriedWhateverItsErrorType() async throws {
        let transactionGuard = makeGuardClient(TransactionGuard())
        let admissions = SignalledRecords<Void>()
        let posts = SignalledRecords<Void>()

        let outcome = await Task<TxResult, Error> {
            try await VotingBroadcastDispatch.run(
                transactionGuard: transactionGuard,
                admission: {
                    admissions.recordCall()
                    throw URLError(.notConnectedToInternet)
                },
                sleep: { _ in },
                attempt: {
                    posts.recordCall()
                    return TxResult(txHash: "tx", code: 0)
                }
            )
        }.result

        #expect(admissions.count == 1)
        #expect(posts.count == 0)
        guard case .failure(let error) = outcome else {
            Issue.record("the broadcast must be refused")
            return
        }
        #expect((error as? URLError)?.code == .notConnectedToInternet)
    }

    @Test func aBroadcastWithServersLeftIsPostedOnce() async throws {
        let transactionGuard = makeGuardClient(TransactionGuard())
        let pool = VotingShareServerPool(urls: Self.servers)
        let posts = SignalledRecords<Void>()

        let result = try await VotingBroadcastDispatch.run(
            transactionGuard: transactionGuard,
            admission: {
                if await pool.isExhausted {
                    throw ShareDelegationError.noReachableVoteServers
                }
            },
            attempt: {
                posts.recordCall()
                return TxResult(txHash: "tx-1", code: 0)
            }
        )

        #expect(result.txHash == "tx-1")
        #expect(posts.count == 1)
    }

    /// Wraps a fresh guard actor exactly as `TransactionGuardClient.liveValue` wraps the shared one.
    /// With `events`, every `acquire` is recorded before the actor is asked, so a test can tell that
    /// a caller reached the guard.
    private func makeGuardClient(
        _ guardActor: TransactionGuard,
        recording events: SignalledRecords<String>? = nil
    ) -> TransactionGuardClient {
        TransactionGuardClient(
            acquire: {
                events?.record("acquire")
                try await guardActor.acquire()
            },
            acquireWithTimeout: { try await guardActor.acquire(timeout: $0) },
            tryAcquire: { await guardActor.tryAcquire() },
            release: { await guardActor.release() }
        )
    }
}
#endif
