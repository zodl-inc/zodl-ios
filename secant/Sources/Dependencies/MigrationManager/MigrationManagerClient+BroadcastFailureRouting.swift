//
//  MigrationManagerClient+BroadcastFailureRouting.swift
//  Zashi
//
//  R9-T2 (MOB-1497 review remediation, finding 13): the single classify -> route entry point for a
//  broadcast failure. The pairing `MigrationBroadcastFailureClass.classify(result:/error:)` ->
//  `guard let` -> `routeBroadcastFailure(accountUUID, failureClass)` was hand-repeated at 8 call
//  sites (`RootInitialization`, `MigrationSendingStore`, `MigrationNoteSplitStore`) — these two
//  overloads fold classification into the call itself so a new call site can't drift from the
//  pattern (e.g. forget the nil-class skip, or classify with the wrong overload).
//
//  Deliberately added as an extension on `MigrationManagerClient` rather than a new dependency-client
//  member: the two overloads are pure dispatch over the EXISTING `routeBroadcastFailure` closure
//  member (see `MigrationManagerClient.routeBroadcastFailure`'s own doc for the R14-R17 decision
//  table it runs), so they need no new stored closure, no new `LiveKey` wiring, and every existing
//  test stub for the 2-arg closure member keeps working unchanged.
//

import Foundation
@preconcurrency import ZcashLightClientKit

extension MigrationManagerClient {
    /// Classifies a broadcast call's RETURNED `MigrationTransferResult` and routes it — `nil` in
    /// (a non-classifiable result: `.success`, `.invalidNote`, `.expired`,
    /// `.networkError(retryable: false)`) means `nil` out WITHOUT invoking the `routeBroadcastFailure`
    /// closure member at all. This matters beyond a short-circuit: the live implementation records a
    /// routing episode (rotation/Tor-hold bookkeeping) on every real call, so a non-routable result
    /// must never reach it, and existing test stubs assert the closure never fires for these results.
    func routeBroadcastFailure(_ accountUUID: AccountUUID?, result: MigrationTransferResult) async -> MigrationBroadcastFailureRoute? {
        guard let failureClass = MigrationBroadcastFailureClass.classify(result: result) else { return nil }
        return await routeBroadcastFailure(accountUUID, failureClass)
    }

    /// Classifies a broadcast call's THROWN error and routes it — same nil-in/nil-out-without-
    /// invoking contract as the `result:` overload above. `ZcashError.migrationRecordFailedAfterBroadcast`
    /// (the broadcast landed; only the engine's own recording of it failed) is the one thrown error
    /// this never routes — see `MigrationBroadcastFailureClass.classify(error:)`'s own doc.
    func routeBroadcastFailure(_ accountUUID: AccountUUID?, error: Error) async -> MigrationBroadcastFailureRoute? {
        guard let failureClass = MigrationBroadcastFailureClass.classify(error: error) else { return nil }
        return await routeBroadcastFailure(accountUUID, failureClass)
    }
}
