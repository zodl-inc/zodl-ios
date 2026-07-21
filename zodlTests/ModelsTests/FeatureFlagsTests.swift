//
//  FeatureFlagsTests.swift
//  zodlTests
//
//  Extended — pure logic. Covers FeatureFlags default values (Models/FeatureFlags.swift).
//

import Testing
@testable import zodl_internal

@Suite struct FeatureFlagsTests {
    @Test func defaultValues() {
        let flags = FeatureFlags()
        #expect(!flags.addUAtoMemo)
        #expect(flags.appLaunchBiometric)
        #expect(!flags.coinholderPolling)
        #expect(flags.flexa)
        #expect(flags.selectText)
    }

    @Test func initialUsesDefaults() {
        #expect(FeatureFlags.initial == FeatureFlags())
    }
}
