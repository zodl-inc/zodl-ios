//
//  WalletConfigTests.swift
//  zodlTests
//
//  Batch 2 — config. Covers WalletConfig / FeatureFlag (Models/WalletConfig.swift).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct WalletConfigTests {
    @Test func isEnabledReturnsFlagValueAndDefaultsToFalse() {
        let config = WalletConfig(flags: [.showFiatConversion: true])
        #expect(config.isEnabled(.showFiatConversion))
        #expect(!config.isEnabled(.onboardingFlow)) // absent -> default false
    }

    /// Flags ship OFF unless someone deliberately turned one on, and the ones that are on are
    /// listed here by name.
    ///
    /// This replaces a blanket "every flag is off" assertion, whose premise went stale the day
    /// `useSlipstreamSynchronizer` became the shipping engine. Blanket-false would now have to be
    /// deleted to go green — and deleting it would lose the property worth keeping, which is that a
    /// flag turning on is a VISIBLE, reviewed change rather than something noticed in production.
    /// Listing the exceptions keeps the guard and makes each exception a diff.
    @Test func onlyDeliberatelyShippedFlagsAreOnByDefault() {
        let shippedOn: Set<FeatureFlag> = [.useSlipstreamSynchronizer]

        for flag in FeatureFlag.allCases {
            #expect(flag.enabledByDefault == shippedOn.contains(flag), "\(flag) default changed")
        }
    }

    /// Renamed from `...AndDisablesEverything`, which stopped being true when the engine flag
    /// shipped on. `initial` carries each flag's OWN default, not a blanket false.
    @Test func initialExcludesTestFlagsAndCarriesEachFlagsDefault() {
        let initial = WalletConfig.initial
        #expect(initial.flags[.testFlag1] == nil)
        #expect(initial.flags[.testFlag2] == nil)
        #expect(initial.flags.count == FeatureFlag.allCases.count - 2)
        #expect(!initial.isEnabled(.showFiatConversion))
        #expect(!initial.isEnabled(.onboardingFlow))
        #expect(initial.isEnabled(.useSlipstreamSynchronizer))
    }

    @Test func featureFlagCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(FeatureFlag.showFiatConversion)
        #expect(try JSONDecoder().decode(FeatureFlag.self, from: data) == .showFiatConversion)
    }
}
