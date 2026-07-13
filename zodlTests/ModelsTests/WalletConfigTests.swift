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

    @Test func allFeatureFlagsDisabledByDefault() {
        for flag in FeatureFlag.allCases {
            // [#1755]/[MOB-1458] Deliberate exception: the Slipstream engine is on by default on
            // this line (see the flag's TODO in WalletConfig.swift). Every other flag stays off.
            if flag == .useSlipstreamSynchronizer {
                #expect(flag.enabledByDefault)
            } else {
                #expect(!flag.enabledByDefault)
            }
        }
    }

    @Test func initialExcludesTestFlagsAndDisablesEverything() {
        let initial = WalletConfig.initial
        #expect(initial.flags[.testFlag1] == nil)
        #expect(initial.flags[.testFlag2] == nil)
        #expect(initial.flags.count == FeatureFlag.allCases.count - 2)
        #expect(!initial.isEnabled(.showFiatConversion))
        #expect(!initial.isEnabled(.onboardingFlow))
    }

    @Test func featureFlagCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(FeatureFlag.showFiatConversion)
        #expect(try JSONDecoder().decode(FeatureFlag.self, from: data) == .showFiatConversion)
    }
}
