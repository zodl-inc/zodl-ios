//
//  DeeplinkURLParsingTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import Testing
import Foundation
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct DeeplinkURLParsingTests {
    @Test func resolveDeeplinkSimplifiedFormatValidAddress() throws {
        let address = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po"
        guard let url = URL(string: "zcash:\(address)") else {
            Issue.record("DeeplinkURLParsing tests: `testResolveDeeplinkSimplifiedFormatValidAddress` URL is expected to be valid")
            return
        }

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { addr, _ in addr == address }
        )

        #expect(
            result == .send(amount: 0, address: address, memo: ""),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSimplifiedFormatValidAddress` result is expected to be .send with address \(address) but it is \(result)"
        )
    }

    @Test func resolveDeeplinkSimplifiedFormatInvalidAddressFallsThrough() {
        let url = URL(string: "zcash:invalidaddress123")!

        #expect(
            throws: (any Error).self,
            "DeeplinkURLParsing tests: `testResolveDeeplinkSimplifiedFormatInvalidAddressFallsThrough` is expected to throw for invalid address"
        ) {
            try Deeplink.resolveDeeplinkURL(
                url,
                networkType: .testnet,
                isValidZcashAddress: { _, _ in false }
            )
        }
    }

    @Test func resolveDeeplinkHomeURL() throws {
        let url = URL(string: "zcash:///home")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        #expect(
            result == .home,
            "DeeplinkURLParsing tests: `testResolveDeeplinkHomeURL` result is expected to be .home but it is \(result)"
        )
    }

    @Test func resolveDeeplinkSendURLWithAllParams() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&memo=hello&amount=500000")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        #expect(
            result == .send(amount: 500_000, address: "t1addr", memo: "hello"),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLWithAllParams` result is expected to be .send with amount 500000, address t1addr, memo hello but it is \(result)"
        )
    }

    @Test func resolveDeeplinkSendURLMissingAmountDefaultsToZero() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&memo=test")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        #expect(
            result == .send(amount: 0, address: "t1addr", memo: "test"),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLMissingAmountDefaultsToZero` amount is expected to default to 0 but result is \(result)"
        )
    }

    @Test func resolveDeeplinkSendURLMissingMemoDefaultsToEmpty() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&amount=100")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        #expect(
            result == .send(amount: 100, address: "t1addr", memo: ""),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLMissingMemoDefaultsToEmpty` memo is expected to default to empty but result is \(result)"
        )
    }

    @Test func resolveDeeplinkSendURLUrlEncodedMemo() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&memo=Hello%20World%21&amount=0")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        #expect(
            result == .send(amount: 0, address: "t1addr", memo: "Hello World!"),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLUrlEncodedMemo` memo is expected to be decoded as 'Hello World!' but result is \(result)"
        )
    }

    @Test func resolveDeeplinkUnknownPathThrows() {
        let url = URL(string: "zcash:///unknown/path")!

        #expect(
            throws: (any Error).self,
            "DeeplinkURLParsing tests: `testResolveDeeplinkUnknownPathThrows` is expected to throw for unknown path"
        ) {
            try Deeplink.resolveDeeplinkURL(
                url,
                networkType: .testnet,
                isValidZcashAddress: { _, _ in false }
            )
        }
    }

    @Test func resolveDeeplinkPassesNetworkTypeToValidator() throws {
        let url = URL(string: "zcash:someaddress")!
        var receivedNetworkType: NetworkType?

        _ = try? Deeplink.resolveDeeplinkURL(
            url,
            networkType: .mainnet,
            isValidZcashAddress: { _, network in
                receivedNetworkType = network
                return true
            }
        )

        #expect(
            receivedNetworkType == .mainnet,
            "DeeplinkURLParsing tests: `testResolveDeeplinkPassesNetworkTypeToValidator` network type is expected to be .mainnet but it is \(String(describing: receivedNetworkType))"
        )
    }
}
