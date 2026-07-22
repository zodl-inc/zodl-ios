//
//  ServerProviderTests.swift
//  zodlTests
//
//  Pure logic. Covers `ServerProvider.classify(host:)` (Models/ServerProvider.swift) — MOB-1496 W4.
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct ServerProviderTests {
    // MARK: - Built-in mainnet hosts (all 7 `endpoints(for: .mainnet)` entries, incl. the default)

    @Test func mainnetDefaultHostIsZecRocks() {
        #expect(ServerProvider.classify(host: "zec.rocks") == ServerProvider.zecRocks)
    }

    @Test func naZecRocksIsZecRocks() {
        #expect(ServerProvider.classify(host: "na.zec.rocks") == ServerProvider.zecRocks)
    }

    @Test func saZecRocksIsZecRocks() {
        #expect(ServerProvider.classify(host: "sa.zec.rocks") == ServerProvider.zecRocks)
    }

    @Test func euZecRocksIsZecRocks() {
        #expect(ServerProvider.classify(host: "eu.zec.rocks") == ServerProvider.zecRocks)
    }

    @Test func apZecRocksIsZecRocks() {
        #expect(ServerProvider.classify(host: "ap.zec.rocks") == ServerProvider.zecRocks)
    }

    @Test func usZecStardustRestIsStardust() {
        #expect(ServerProvider.classify(host: "us.zec.stardust.rest") == ServerProvider.stardust)
    }

    @Test func euZecStardustRestIsStardust() {
        #expect(ServerProvider.classify(host: "eu.zec.stardust.rest") == ServerProvider.stardust)
    }

    // MARK: - Testnet default

    @Test func testnetDefaultHostIsZecRocks() {
        #expect(ServerProvider.classify(host: "testnet.zec.rocks") == ServerProvider.zecRocks)
    }

    // MARK: - Custom

    @Test func customHostIsCustomCarryingTheLowercasedHost() {
        #expect(ServerProvider.classify(host: "mynode.example.com") == ServerProvider.custom(host: "mynode.example.com"))
    }

    @Test func bareStardustRestWithNoSubdomainIsCustomNotStardust() {
        // The built-in list only ever emits `us`/`eu.zec.stardust.rest` — a bare
        // "zec.stardust.rest" (no subdomain) does not match the `*.zec.stardust.rest` suffix rule.
        #expect(ServerProvider.classify(host: "zec.stardust.rest") == ServerProvider.custom(host: "zec.stardust.rest"))
    }

    @Test func twoDifferentCustomHostsClassifyUnequal() {
        #expect(ServerProvider.classify(host: "one.example.com") != ServerProvider.classify(host: "two.example.com"))
    }

    // MARK: - Case-insensitivity

    @Test func uppercasedBuiltInHostStillClassifiesZecRocks() {
        #expect(ServerProvider.classify(host: "NA.ZEC.ROCKS") == ServerProvider.zecRocks)
    }

    @Test func mixedCaseStardustHostStillClassifiesStardust() {
        #expect(ServerProvider.classify(host: "Us.Zec.Stardust.Rest") == ServerProvider.stardust)
    }

    @Test func differentlyCasedCustomHostsClassifyEqual() {
        #expect(ServerProvider.classify(host: "MyNode.Example.COM") == ServerProvider.classify(host: "mynode.example.com"))
    }
}
