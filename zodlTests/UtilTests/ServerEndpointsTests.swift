import Testing
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct ServerEndpointsTests {
    @Test func testnetReturnsOnlyDefault() {
        let endpoints = ZcashSDKEnvironment.endpoints(for: .testnet)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.host == ZcashSDKEnvironment.defaultEndpoint(for: .testnet).host)
    }

    @Test func testnetSkipDefaultIsEmpty() {
        #expect(ZcashSDKEnvironment.endpoints(for: .testnet, skipDefault: true).isEmpty)
    }

    @Test func mainnetContainsKnownServersWithSecureAndTimeout() {
        let endpoints = ZcashSDKEnvironment.endpoints(for: .mainnet)
        #expect(endpoints.contains { $0.host == "zec.rocks" && $0.port == 443 })
        #expect(endpoints.contains { $0.host == "eu.zec.stardust.rest" })
        #expect(endpoints.allSatisfy { $0.secure })
        #expect(endpoints.allSatisfy {
            $0.streamingCallTimeoutInMillis == ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        })
    }

    @Test func mainnetSkipDefaultExcludesDefaultHost() {
        let endpoints = ZcashSDKEnvironment.endpoints(for: .mainnet, skipDefault: true)
        #expect(!(endpoints.contains { $0.host == "zec.rocks" }))
    }
}
