//
//  MigrationSummaryDustTests.swift
//  zodlTests
//
//  `MigrationDerivations.summary`'s `dust`, which had NO test at all — and that is how a branch
//  that could never fire survived long enough to be reported as a missing feature.
//
//  THE BUG (field-caught 2026-08-02, after the first end-to-end completion). The `.complete`
//  fallback read `progress?.remainingOrchard ?? .zero`. But the SDK's contract for
//  `migrationProgress` is explicit — "a terminal — complete or cancelled — run reports `nil`" — and
//  that branch is reached ONLY when `state == .complete`. So `progress` was nil by construction, the
//  expression collapsed to `.zero`, and `dust` was always zero on the one screen built to resolve it.
//
//  What that cost: `MigrationComplete.State.hasDust` is `dust > 0`. With zero dust the residual
//  card, "Migrate anyway" and "Lock balance" all disappear and the Complete screen renders a bare
//  summary. The first tester reported exactly that — "only migration done, summary" — and it read as
//  an unbuilt feature rather than a bug, because the feature was complete behind a predicate that
//  could not become true.
//
//  So these tests pin the PRECEDENCE, and the `.complete` case is written the way the field found
//  it: progress nil, because that is the only way it ever arrives.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSummaryDustTests {
    /// An empty committed schedule: `dust` never reads the schedule, so an empty one keeps every
    /// case below about the one value under test.
    private static func committedSchedule() -> MigrationCommittedSchedule {
        MigrationCommittedSchedule(
            schedule: MigrationSchedule(
                transfers: [],
                estimatedDurationHours: 0,
                proposalHandle: 0,
                preparations: []
            ),
            sentRecords: [],
            committedAt: Date(timeIntervalSince1970: 1_754_100_000)
        )
    }

    private static func dust(
        state: MigrationState,
        residual: Zatoshi? = nil,
        progress: MigrationProgress? = nil,
        orchardBalance: Zatoshi = .zero
    ) -> Zatoshi {
        MigrationDerivations.summary(
            committedSchedule: committedSchedule(),
            state: state,
            residual: residual,
            progress: progress,
            orchardBalance: orchardBalance
        ).dust
    }

    // MARK: - The regression

    /// THE test. A terminal run reports `nil` progress — always, by contract — so the live Orchard
    /// balance is what `dust` must fall back to. Written with `progress: nil` deliberately: that is
    /// not an edge case here, it is the only reachable shape.
    @Test func aCompleteRunFallsBackToTheLiveOrchardBalance() {
        let residualOnChain = Zatoshi(500_000)

        let dust = Self.dust(state: .complete, progress: nil, orchardBalance: residualOnChain)

        #expect(dust == residualOnChain)
    }

    /// …and the consequence that actually reached the user: with real dust on chain, the Complete
    /// screen must offer the choice. `hasDust` is the predicate the whole done-flow hangs off.
    @Test func realDustOnChainMakesTheCompleteScreenOfferTheChoice() {
        let dust = Self.dust(state: .complete, progress: nil, orchardBalance: Zatoshi(500_000))
        let completeState = MigrationComplete.State(dust: dust)

        #expect(completeState.hasDust, "no dust means no residual card, no Migrate anyway, no Lock balance")
    }

    // MARK: - Precedence, unchanged

    /// The engine's own residual still wins outright when it is readable. The fallback exists for
    /// the case where that read is unavailable, not to replace it.
    @Test func theEnginesResidualOutranksTheBalanceFallback() {
        let dust = Self.dust(
            state: .complete,
            residual: Zatoshi(111),
            progress: nil,
            orchardBalance: Zatoshi(999_999)
        )

        #expect(dust == Zatoshi(111))
    }

    /// A run still in flight reports NO dust, whatever the Orchard balance says — mid-run that
    /// balance is the funds still queued to migrate, not a residue. Reading it as dust would offer
    /// to lock money the run is about to move.
    @Test func aRunInFlightNeverReportsDust() {
        let dust = Self.dust(
            state: .splitPendingConfirmation,
            progress: nil,
            orchardBalance: Zatoshi(9_999_999_999)
        )

        #expect(dust == .zero)
    }

    /// A complete run that genuinely swept everything reports zero, and the screen correctly shows
    /// the bare summary. The fix must not manufacture dust where there is none.
    @Test func aCleanCompleteRunStillReportsNoDust() {
        let dust = Self.dust(state: .complete, progress: nil, orchardBalance: .zero)

        #expect(dust == .zero)
        #expect(!MigrationComplete.State(dust: dust).hasDust)
    }
}
