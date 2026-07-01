//
//  RegtestActivationHeightsTests.swift
//  zodlTests
//
//  Covers the Ironwood regtest dev-hook wiring (MOB-1455): custom NU activation heights, the fixed
//  regtest endpoint, and regtest handling across ZcashSDKEnvironment and the payment-URI parser.
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
import ZcashPaymentURI
@testable import zodl_internal

@Suite struct RegtestActivationHeightsTests {
    // MARK: - IronwoodRegtestConfig

    @Test func regtestNetworkCarriesCustomActivationHeights() {
        let network = IronwoodRegtestConfig.network
        #expect(network.networkType == .regtest)
        #expect(network.customActivationHeights == IronwoodRegtestConfig.activationHeights)
    }

    @Test func regtestActivationHeightsMatchBackend() {
        let heights = IronwoodRegtestConfig.activationHeights
        #expect(heights.nu6_3 == 5000)
        #expect(heights.sapling == 1)
        #expect(heights.nu5 == 1)
        #expect(heights.nu6 == 1)
        // Sapling activation is read from the network instance, not the static fallback.
        #expect(IronwoodRegtestConfig.network.saplingActivationHeight == 1)
    }

    // MARK: - ZcashSDKEnvironment endpoint wiring

    @Test func regtestDefaultEndpointMatchesConfig() {
        let endpoint = ZcashSDKEnvironment.defaultEndpoint(for: .regtest)
        #expect(endpoint == IronwoodRegtestConfig.endpoint)
        #expect(endpoint.host == "lwd.157.245.208.35.sslip.io")
        #expect(endpoint.port == 443)
        #expect(endpoint.secure)
    }

    @Test func regtestHasExactlyOneBenchmarkEndpoint() {
        #expect(ZcashSDKEnvironment.endpoints(for: .regtest) == [IronwoodRegtestConfig.endpoint])
        #expect(ZcashSDKEnvironment.endpoints(for: .regtest, skipDefault: true).isEmpty)
    }

    @Test func regtestOffersOnlyDefaultServer() {
        #expect(ZcashSDKEnvironment.servers(for: .regtest) == [.default])
    }

    // MARK: - Token name

    @Test func regtestTokenNameIsTAZ() {
        let environment = ZcashSDKEnvironment.live(network: IronwoodRegtestConfig.network)
        #expect(environment.tokenName() == "TAZ")
        #expect(environment.tokenName() == IronwoodRegtestConfig.tokenName)
    }

    // MARK: - Payment-URI parser context

    @Test func regtestParserContextIsRegtest() {
        #expect(ParserContext.from(networkType: .regtest) == .regtest)
    }
}
