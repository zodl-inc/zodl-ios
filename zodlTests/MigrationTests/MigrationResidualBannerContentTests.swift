//
//  MigrationResidualBannerContentTests.swift
//  zodlTests
//
//  MOB-1749: the Remaining Orchard Funds banner variant — Figma 6855:24738. Pins the rendering
//  contract the smart banner reads (title names the amount, info asks for a decision, the ordinary
//  More button, a payload-blind dwell key) without pinning the locale-dependent number format.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationResidualBannerContentTests {
    private static let amount = Zatoshi(800_000)
    private static let residual = MigrationBannerVariant.residual(amount: amount)

    @Test func theTitleNamesTheAmountLeftInOrchard() {
        let title = Self.residual.title

        #expect(title.hasPrefix(Self.amount.decimalString()))
        #expect(title.contains("ZEC"))
        #expect(title.hasSuffix("left in Orchard"))
    }

    @Test func theInfoLineAsksForADecision() {
        #expect(Self.residual.info == "Tap to decide what happens to it")
    }

    @Test func itKeepsTheOrdinaryMoreButton() {
        #expect(Self.residual.showsButton)
        #expect(Self.residual.buttonLabel == MigrationBannerVariant.complete.buttonLabel)
    }

    @Test func theDwellKeyIsPayloadBlind() {
        #expect(Self.residual.dwellKey == "residual")
        #expect(MigrationBannerVariant.residual(amount: Zatoshi(20_000)).dwellKey == Self.residual.dwellKey)
    }
}
