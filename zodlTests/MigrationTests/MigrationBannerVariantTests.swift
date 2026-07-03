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

    @Test func splittingTitleAndInfo() {
        let variant = MigrationBannerVariant.splitting

        #expect(variant.title == String(localizable: .migrationBannerRequiredTitle))
        #expect(variant.info == String(localizable: .migrationBannerSplittingInfo))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == nil)
    }

    @Test func inProgressTitleAndInfoInterpolatesDoneTotalAndPercent() {
        let variant = MigrationBannerVariant.inProgress(done: 2, total: 5)

        #expect(variant.title == String(localizable: .migrationBannerProgressTitle))
        #expect(variant.info == String(localizable: .migrationBannerProgressInfo(2, 5, 40)))
        #expect(variant.buttonLabel == String(localizable: .generalMore))
        #expect(variant.percent == 40)
    }

    @Test func inProgressPercentRoundsToNearestInteger() {
        #expect(MigrationBannerVariant.inProgress(done: 2, total: 5).percent == 40)
        #expect(MigrationBannerVariant.inProgress(done: 1, total: 3).percent == 33)
        #expect(MigrationBannerVariant.inProgress(done: 2, total: 3).percent == 67)
        #expect(MigrationBannerVariant.inProgress(done: 0, total: 0).percent == 0)
    }

    @Test func transferWaitingTitleInterpolatesNumber() {
        let variant = MigrationBannerVariant.transferWaiting(number: 3)

        #expect(variant.title == String(localizable: .migrationBannerWaitingTitle(3)))
        #expect(variant.info == String(localizable: .migrationBannerWaitingInfo))
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

    @Test func onlyTransferReadyUsesTheReviewButtonLabel() {
        let allOtherVariants: [MigrationBannerVariant] = [
            .required,
            .splitting,
            .inProgress(done: 1, total: 2),
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
