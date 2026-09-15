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
    static func run(
        servers: [String],
        preferredServerURL: String?,
        lookup: (String) async -> TxConfirmationLookup
    ) async -> TxConfirmation? {
        if let preferredServerURL {
            switch await lookup(preferredServerURL) {
            case .confirmed(let confirmation):
                return confirmation
            case .notIndexed:
                return nil
            case .unavailable:
                break
            }
        }
        for server in servers where server != preferredServerURL {
            if case .confirmed(let confirmation) = await lookup(server) {
                return confirmation
            }
        }
        return nil
    }
}

/// Which server a confirmation poll attempt asks first. The accepting server answers alone for the
/// first `authoritativeAttempts` (nine seconds at the 750 ms cadence); after that every
/// `sweepEvery`-th attempt walks every server, so a server whose transaction indexer lags or is
/// switched off cannot strand a mined transaction for the whole budget. A broadcast nobody accepted
/// has no preference and walks every server on every attempt.
enum TxConfirmationPollPlan {
    static let authoritativeAttempts = 12
    static let sweepEvery = 4

    static func preferredServer(acceptedBy server: String?, attempt: Int) -> String? {
        guard let server else {
            return nil
        }
        if attempt <= authoritativeAttempts {
            return server
        }
        return attempt % sweepEvery == 0 ? nil : server
    }
}
#endif
