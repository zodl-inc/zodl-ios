//
//  IronwoodActivationHeightTests.swift
//  zodlTests
//
//  Covers `ZcashSDKEnvironment.live(network:).ironwoodActivationHeight()` (MOB-1483): the
//  app-side NU6.3 ("Ironwood") activation heights mirrored from librustzcash zcash_protocol
//  0.10.0, keyed off `network.networkType` (Dependencies/ZcashSDKEnvironment/).
//

import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct IronwoodActivationHeightTests {
    @Test func mainnetReturnsTheZcashProtocolActivationHeight() {
        let environment = ZcashSDKEnvironment.live(network: ZcashNetworkBuilder.network(for: .mainnet))
        #expect(environment.ironwoodActivationHeight() == 3_428_143)
    }

    @Test func testnetReturnsTheZcashProtocolActivationHeight() {
        let environment = ZcashSDKEnvironment.live(network: ZcashNetworkBuilder.network(for: .testnet))
        #expect(environment.ironwoodActivationHeight() == 4_134_000)
    }

    @Test func customNetworkWithConfiguredNU6_3HeightReturnsThatHeight() {
        let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(nu6_3: 12_345))
        let environment = ZcashSDKEnvironment.live(network: network)
        #expect(environment.ironwoodActivationHeight() == 12_345)
    }

    @Test func customNetworkWithoutConfiguredNU6_3HeightNeverActivates() {
        let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights())
        let environment = ZcashSDKEnvironment.live(network: network)
        #expect(environment.ironwoodActivationHeight() == BlockHeight.max)
    }
}
