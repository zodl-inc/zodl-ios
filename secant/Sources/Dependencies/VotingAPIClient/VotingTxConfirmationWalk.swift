#if VOTING_ENABLED
//
//  VotingTxConfirmationWalk.swift
//  Zashi
//

import Foundation

/// What one vote server could tell us about a transaction.
enum TxConfirmationLookup: Equatable, Sendable {
    /// The server answered with the transaction: a 200, or a 422 carrying the rejection code.
    case confirmed(TxConfirmation)
    /// The server answered 404: it has no record of the transaction yet.
    case notIndexed
    /// The server could not answer: transport failure, timeout, unexpected status, unparsable body.
    case unavailable
}

/// The confirmation walk over the configured vote servers, separated from the transport so it can
/// be tested. The server that accepted a broadcast indexes the transaction before any other, so
/// when the caller names it, its answer is authoritative: a confirmation returns at once, and a
/// 404 means "not mined yet" and ends the attempt without asking anyone else. Only a server that
/// cannot answer at all falls through to the rest, in configured order. Without a preferred server
/// (recovery probes, which have only a hash from a previous run) the walk asks every server in
/// order and takes the first confirmation.
enum VotingTxConfirmationWalk {
    static func run<C: Clock>(
        servers: [String],
        preferredServerURL: String?,
        remainingBudget: Duration?,
        clock: C,
        lookup: (String, Duration) async throws -> TxConfirmationLookup
    ) async throws -> TxConfirmation? where C.Duration == Duration {
        let deadline = remainingBudget.map { clock.now.advanced(by: $0) }

        func lookupBudget() -> Duration? {
            guard let deadline else {
                return .seconds(10)
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                return nil
            }
            return min(.seconds(10), remaining)
        }

        if let preferredServerURL {
            try Task.checkCancellation()
            guard let budget = lookupBudget() else {
                return nil
            }
            switch try await lookup(preferredServerURL, budget) {
            case .confirmed(let confirmation):
                return confirmation
            case .notIndexed:
                return nil
            case .unavailable:
                break
            }
        }
        for server in servers where server != preferredServerURL {
            try Task.checkCancellation()
            guard let budget = lookupBudget() else {
                return nil
            }
            if case .confirmed(let confirmation) = try await lookup(server, budget) {
                return confirmation
            }
        }
        return nil
    }
}

/// Which server a confirmation poll attempt asks first. The accepting server answers alone until
/// the first full sweep becomes due at nine elapsed seconds. Later sweeps become due three seconds
/// after the previous sweep finishes, so time spent walking slow servers does not accidentally
/// schedule another sweep immediately. A broadcast nobody accepted has no preference and walks
/// every server on every attempt.
struct TxConfirmationPollPlan {
    private var nextSweepDue: Duration = .seconds(9)

    func preferredServer(acceptedBy server: String?, elapsed: Duration) -> String? {
        guard let server else {
            return nil
        }
        return elapsed >= nextSweepDue ? nil : server
    }

    mutating func fullSweepCompleted(at elapsed: Duration) {
        nextSweepDue = elapsed + .seconds(3)
    }
}
#endif
