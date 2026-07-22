//
//  MigrationBannerVariantTests.swift
//  zodlTests
//
//  Covers the pure `MigrationBannerVariant` mappings
//  (Features/SmartBanner/SmartBannerMigrationContent.swift) for MOB-1464: title/info/buttonLabel
//  text per variant (including argument interpolation) and the `percent` rounding for `inProgress`.
//  No reducer, no shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct MigrationBannerVariantTests {
    @Test func requiredTitleAndInfo() {
        let variant = MigrationBannerVariant.required

        #expect(variant.title == String(localizable: .migrationBannerRequiredTitle))
        #expect(variant.info == String(localizable: .migrationBannerRequiredInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    @Test func inProgressTitleAndInfoInterpolatesDoneTotalAndPercent() {
        let variant = MigrationBannerVariant.inProgress(done: 2, total: 5, round: nil, totalRounds: nil)

        #expect(variant.title == String(localizable: .migrationBannerProgressTitle))
        #expect(variant.info == String(localizable: .migrationBannerProgressInfo(2, 5, 40)))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == 40)
    }

    @Test func inProgressPercentRoundsToNearestInteger() {
        #expect(MigrationBannerVariant.inProgress(done: 2, total: 5, round: nil, totalRounds: nil).percent == 40)
        #expect(MigrationBannerVariant.inProgress(done: 1, total: 3, round: nil, totalRounds: nil).percent == 33)
        #expect(MigrationBannerVariant.inProgress(done: 2, total: 3, round: nil, totalRounds: nil).percent == 67)
        #expect(MigrationBannerVariant.inProgress(done: 0, total: 0, round: nil, totalRounds: nil).percent == 0)
    }

    @Test func transferWaitingTitleInterpolatesNumber() {
        let variant = MigrationBannerVariant.transferWaiting(number: 3)

        #expect(variant.title == String(localizable: .migrationBannerWaitingTitle(3)))
        #expect(variant.info == String(localizable: .migrationBannerWaitingInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    /// R7 final review, Important-1 (spec §G): `torHold` defaults `false` — the test above already
    /// pins that default reading the generic waiting copy; this pins the explicit `false` reads
    /// identically (proving the parameter, not just its absence, drives the same result).
    @Test func transferWaitingWithTorHoldFalseReadsIdenticallyToTheDefault() {
        let variant = MigrationBannerVariant.transferWaiting(number: 3, torHold: false)

        #expect(variant.title == String(localizable: .migrationBannerWaitingTitle(3)))
        #expect(variant.info == String(localizable: .migrationBannerWaitingInfo))
    }

    /// R7 final review, Important-1 (spec §G): `torHold: true` carries the Tor-specific `.info` line
    /// instead of the generic waiting copy — the title (which just interpolates the transfer number)
    /// is unaffected, since the number, not the cause, is what it communicates.
    @Test func transferWaitingWithTorHoldTrueCarriesTheTorSpecificInfoLine() {
        let variant = MigrationBannerVariant.transferWaiting(number: 3, torHold: true)

        #expect(variant.title == String(localizable: .migrationBannerWaitingTitle(3)))
        #expect(variant.info == String(localizable: .migrationFailureTorHoldBannerInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    @Test func updatePlanTitleAndInfo() {
        let variant = MigrationBannerVariant.updatePlan

        #expect(variant.title == String(localizable: .migrationBannerUpdatePlanTitle))
        #expect(variant.info == String(localizable: .migrationBannerUpdatePlanInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    @Test func transfersExpiredTitleInterpolatesFirstAndLast() {
        let variant = MigrationBannerVariant.transfersExpired(first: 3, last: 5)

        #expect(variant.title == String(localizable: .migrationBannerExpiredTitle(3, 5)))
        #expect(variant.info == String(localizable: .migrationBannerExpiredInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    @Test func transferReadyTitleInterpolatesNumberAndUsesReviewButtonLabel() {
        let variant = MigrationBannerVariant.transferReady(number: 4)

        #expect(variant.title == String(localizable: .migrationBannerReadyTitle(4)))
        #expect(variant.info == String(localizable: .migrationBannerReadyInfo))
        #expect(variant.buttonLabel == String(localizable: .sendReview))
        #expect(variant.percent == nil)
    }

    @Test func completeTitleAndInfo() {
        let variant = MigrationBannerVariant.complete

        #expect(variant.title == String(localizable: .migrationBannerCompleteTitle))
        #expect(variant.info == String(localizable: .migrationBannerCompleteInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    // MARK: - MOB-1511 (W2): multi-round

    @Test func inProgressWithRoundAndTotalPrefixesInfoAndKeepsTitle() {
        let variant = MigrationBannerVariant.inProgress(done: 2, total: 6, round: 1, totalRounds: 4)

        #expect(variant.title == String(localizable: .migrationBannerProgressTitle))
        #expect(variant.info == String(localizable: .migrationBannerProgressInfoRoundTotal(1, 4, 2, 6, 33)))
    }

    @Test func inProgressWithRoundButNoTotalUsesTheTotalFreeKey() {
        let variant = MigrationBannerVariant.inProgress(done: 2, total: 6, round: 2, totalRounds: nil)

        #expect(variant.info == String(localizable: .migrationBannerProgressInfoRound(2, 2, 6, 33)))
    }

    @Test func nextRoundRequiredUsesRequiredTitleWithRoundInfo() {
        let bare = MigrationBannerVariant.nextRoundRequired(round: 2, totalRounds: nil)

        #expect(bare.title == String(localizable: .migrationBannerRequiredTitle))
        #expect(bare.info == String(localizable: .migrationBannerNextRoundInfo(2)))
        #expect(bare.buttonLabel == String(localizable: .generalMore))
        #expect(bare.percent == nil)

        let withTotal = MigrationBannerVariant.nextRoundRequired(round: 2, totalRounds: 4)
        #expect(withTotal.info == String(localizable: .migrationBannerNextRoundInfoTotal(2, 4)))
    }

    @Test func onlyTransferReadyUsesTheReviewButtonLabel() {
        let allOtherVariants: [MigrationBannerVariant] = [
            .required,
            .inProgress(done: 1, total: 2, round: nil, totalRounds: nil),
            .nextRoundRequired(round: 2, totalRounds: nil),
            .transferWaiting(number: 1),
            .updatePlan,
            .transfersExpired(first: 1, last: 2),
            .complete
        ]

        for variant in allOtherVariants {
            #expect(variant.buttonLabel == String(localizable: .generalMore))
        }

        #expect(MigrationBannerVariant.transferReady(number: 1).buttonLabel == String(localizable: .sendReview))
    }
}
