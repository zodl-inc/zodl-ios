//
//  DeeplinkURLParsingTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import XCTest
@preconcurrency import ZcashLightClientKit
@testable import zashi_internal


class DeeplinkURLParsingTests: XCTestCase {

    func testResolveDeeplinkSimplifiedFormatValidAddress() throws {
        let address = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po"
        guard let url = URL(string: "zcash:\(address)") else {
            return XCTFail("DeeplinkURLParsing tests: `testResolveDeeplinkSimplifiedFormatValidAddress` URL is expected to be valid")
        }

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { addr, _ in addr == address }
        )

        XCTAssertEqual(
            result,
            .send(amount: 0, address: address, memo: ""),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSimplifiedFormatValidAddress` result is expected to be .send with address \(address) but it is \(result)"
        )
    }

    func testResolveDeeplinkSimplifiedFormatInvalidAddressFallsThrough() {
        let url = URL(string: "zcash:invalidaddress123")!

        XCTAssertThrowsError(
            try Deeplink.resolveDeeplinkURL(
                url,
                networkType: .testnet,
                isValidZcashAddress: { _, _ in false }
            ),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSimplifiedFormatInvalidAddressFallsThrough` is expected to throw for invalid address"
        )
    }

    func testResolveDeeplinkHomeURL() throws {
        let url = URL(string: "zcash:///home")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        XCTAssertEqual(
            result,
            .home,
            "DeeplinkURLParsing tests: `testResolveDeeplinkHomeURL` result is expected to be .home but it is \(result)"
        )
    }

    func testResolveDeeplinkSendURLWithAllParams() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&memo=hello&amount=500000")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        XCTAssertEqual(
            result,
            .send(amount: 500_000, address: "t1addr", memo: "hello"),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLWithAllParams` result is expected to be .send with amount 500000, address t1addr, memo hello but it is \(result)"
        )
    }

    func testResolveDeeplinkSendURLMissingAmountDefaultsToZero() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&memo=test")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        XCTAssertEqual(
            result,
            .send(amount: 0, address: "t1addr", memo: "test"),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLMissingAmountDefaultsToZero` amount is expected to default to 0 but result is \(result)"
        )
    }

    func testResolveDeeplinkSendURLMissingMemoDefaultsToEmpty() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&amount=100")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        XCTAssertEqual(
            result,
            .send(amount: 100, address: "t1addr", memo: ""),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLMissingMemoDefaultsToEmpty` memo is expected to default to empty but result is \(result)"
        )
    }

    func testResolveDeeplinkSendURLUrlEncodedMemo() throws {
        let url = URL(string: "zcash:///home/send?address=t1addr&memo=Hello%20World%21&amount=0")!

        let result = try Deeplink.resolveDeeplinkURL(
            url,
            networkType: .testnet,
            isValidZcashAddress: { _, _ in false }
        )

        XCTAssertEqual(
            result,
            .send(amount: 0, address: "t1addr", memo: "Hello World!"),
            "DeeplinkURLParsing tests: `testResolveDeeplinkSendURLUrlEncodedMemo` memo is expected to be decoded as 'Hello World!' but result is \(result)"
        )
    }

    func testResolveDeeplinkUnknownPathThrows() {
        let url = URL(string: "zcash:///unknown/path")!

        XCTAssertThrowsError(
            try Deeplink.resolveDeeplinkURL(
                url,
                networkType: .testnet,
                isValidZcashAddress: { _, _ in false }
            ),
            "DeeplinkURLParsing tests: `testResolveDeeplinkUnknownPathThrows` is expected to throw for unknown path"
        )
    }

    func testResolveDeeplinkPassesNetworkTypeToValidator() throws {
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

        XCTAssertEqual(
            receivedNetworkType,
            .mainnet,
            "DeeplinkURLParsing tests: `testResolveDeeplinkPassesNetworkTypeToValidator` network type is expected to be .mainnet but it is \(String(describing: receivedNetworkType))"
        )
    }
}
