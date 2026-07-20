//
//  MigrationBroadcastFailure.swift
//  Zashi
//
//  Shared classification for a migration broadcast failure (MOB-1497, R7-T3 of the Tor &
//  broadcast-routing requirements round — "failure routing"). Pure, dependency-free: given the
//  error/result a broadcast call produced, says whether it is Tor-class or endpoint-class per the
//  normative doc's R14-R17, or `nil` when it isn't a routing-relevant failure at all (a landed
//  broadcast whose recording merely failed, or a transport outcome the app already handles as a
//  plain retry). `MigrationManagerClient.routeBroadcastFailure` is the only consumer that turns a
//  non-nil class into a stateful decision — this type itself holds no state and makes no calls.
//  Mirrors `ServerProvider.classify(host:)`'s shape: a `static func classify` living directly on the
//  type it classifies into.
//
//  TAXONOMY FACT (accepted, not a gap — see the normative doc's R14-R17): with Tor ON, an endpoint
//  that is simply unreachable ALSO surfaces as `ZcashError.migrationTorUnavailable`. The SDK's
//  `MigrationBroadcaster.broadcastOverTor` throws that error both when the dedicated Tor runtime
//  can't be built AND when the isolated connection to the chosen endpoint can't be opened, since
//  both failures happen *before* the submit RPC — the SDK cannot distinguish "Tor itself is down"
//  from "this one endpoint is down over Tor" at that point. So the Tor-class surface (R14/R15)
//  deliberately takes precedence over the endpoint-class surface (R16/R17) whenever Tor is on: R17
//  (provider-exhausted, offering the sync-server fallback) is reachable under Tor only via a
//  POST-connection transport failure (a `MigrationTransferResult.networkError(retryable: true)`
//  after the submit RPC itself ran), never via a pre-connection throw.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Which class of broadcast failure occurred, per the normative doc's R14-R17 —
/// `MigrationManagerClient.routeBroadcastFailure` is the sole consumer of a non-nil result. Not
/// `CaseIterable`: deliberately closed to the two classes the spec routes differently — a new
/// failure MODE (not a new class) is a `classify` change, not a new case here.
enum MigrationBroadcastFailureClass: Equatable, Sendable {
    /// R14/R15: Tor could not be established (first broadcast of the run) or was lost (mid-run) —
    /// pre-connection, nothing was broadcast.
    case torUnavailable
    /// R16/R17: a connection was attempted (directly, or the Tor circuit itself was fine) but the
    /// broadcast endpoint could not be reached.
    case endpointUnreachable

    /// Classifies a THROWN error from a broadcast call (`executeNextPendingMigrationTransfer`,
    /// `submitNoteSplit`, `broadcastStoredNoteSplit`, `migrateMigrationDust` —
    /// `SDKSynchronizerInterface.swift:137-206`).
    ///
    /// - `ZcashError.migrationTorUnavailable` -> `.torUnavailable`.
    /// - `ZcashError.migrationRecordFailedAfterBroadcast` -> `nil`: the broadcast LANDED and only
    ///   the engine's own recording of it failed — callers already route this to their existing
    ///   success-like handling (see `MigrationSendingStore`/`MigrationNoteSplitStore`/
    ///   `RootInitialization`'s identical dedicated `catch` clauses for this case) and this
    ///   classifier must never swallow that distinction.
    /// - anything else -> `.endpointUnreachable`: every other throw from a broadcast call is, by
    ///   construction, a post-Tor-bootstrap connect/submit failure (see the taxonomy fact above for
    ///   why an unreachable endpoint under Tor surfaces as `.migrationTorUnavailable` instead, and so
    ///   never reaches this branch).
    static func classify(error: Error) -> MigrationBroadcastFailureClass? {
        switch error {
        case ZcashError.migrationTorUnavailable:
            return MigrationBroadcastFailureClass.torUnavailable

        case ZcashError.migrationRecordFailedAfterBroadcast(_):
            return nil

        default:
            return MigrationBroadcastFailureClass.endpointUnreachable
        }
    }

    /// Classifies a RETURNED `MigrationTransferResult` transport outcome.
    ///
    /// - `.networkError(retryable: true)` -> `.endpointUnreachable`.
    /// - everything else (`.success`, `.invalidNote`, `.expired`, `.networkError(retryable: false)`)
    ///   -> `nil`: the app's existing handling for these stands unchanged — a success is not a
    ///   failure to route, and the other three are non-broadcast-reachability failures R14-R17
    ///   don't speak to.
    static func classify(result: MigrationTransferResult) -> MigrationBroadcastFailureClass? {
        switch result {
        case MigrationTransferResult.networkError(let retryable):
            return retryable ? MigrationBroadcastFailureClass.endpointUnreachable : nil

        default:
            return nil
        }
    }
}
