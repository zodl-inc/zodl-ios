//
//  MigrationBroadcastFailureTests.swift
//  zodlTests
//
//  Covers `MigrationBroadcastFailureClass.classify` (Models/Migration/MigrationBroadcastFailure.swift)
//  for MOB-1497 (R7-T3 — failure routing): the pure error/result -> class matrix, no dependencies.
//  See `MigrationFailureRoutingTests` for the stateful `routeBroadcastFailure` decision this class
//  feeds into.
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBroadcastFailureTests {
    private struct SomeOtherError: Error { }

    // MARK: - classify(error:)

    @Test func migrationTorUnavailableClassifiesAsTorUnavailable() {
        let result = MigrationBroadcastFailureClass.classify(error: ZcashError.migrationTorUnavailable)

        #expect(result == MigrationBroadcastFailureClass.torUnavailable)
    }

    /// The broadcast LANDED and only the engine's own recording of it failed — classification must
    /// never swallow that distinction into a routable failure; callers keep their existing
    /// success-like handling untouched.
    @Test func migrationRecordFailedAfterBroadcastClassifiesAsNil() {
        let result = MigrationBroadcastFailureClass.classify(error: ZcashError.migrationRecordFailedAfterBroadcast(SomeOtherError()))

        #expect(result == nil)
    }

    @Test func anyOtherThrownErrorClassifiesAsEndpointUnreachable() {
        let result = MigrationBroadcastFailureClass.classify(error: SomeOtherError())

        #expect(result == MigrationBroadcastFailureClass.endpointUnreachable)
    }

    /// A DIFFERENT `ZcashError` case (neither of the two this classifier special-cases) still falls
    /// through to the generic "any other error from a broadcast call" bucket.
    @Test func unrelatedZcashErrorCaseClassifiesAsEndpointUnreachable() {
        let result = MigrationBroadcastFailureClass.classify(error: ZcashError.migrationSyncBlocked)

        #expect(result == MigrationBroadcastFailureClass.endpointUnreachable)
    }

    // MARK: - classify(result:)

    @Test func networkErrorRetryableTrueClassifiesAsEndpointUnreachable() {
        let result = MigrationBroadcastFailureClass.classify(result: MigrationTransferResult.networkError(retryable: true))

        #expect(result == MigrationBroadcastFailureClass.endpointUnreachable)
    }

    @Test func networkErrorRetryableFalseClassifiesAsNil() {
        let result = MigrationBroadcastFailureClass.classify(result: MigrationTransferResult.networkError(retryable: false))

        #expect(result == nil)
    }

    @Test func invalidNoteClassifiesAsNil() {
        let result = MigrationBroadcastFailureClass.classify(result: MigrationTransferResult.invalidNote)

        #expect(result == nil)
    }

    @Test func expiredClassifiesAsNil() {
        let result = MigrationBroadcastFailureClass.classify(result: MigrationTransferResult.expired)

        #expect(result == nil)
    }

    @Test func successClassifiesAsNil() {
        let result = MigrationBroadcastFailureClass.classify(result: MigrationTransferResult.success(txId: "tx-0"))

        #expect(result == nil)
    }
}
