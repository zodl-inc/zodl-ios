//
//  DerivationToolTests.swift
//  zodlTests
//
//  Batch 4 — dependency logic. Covers DerivationToolClient address classification
//  (Dependencies/DerivationTool/DerivationToolLiveKey.swift).
//

import Testing
import Foundation
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct DerivationToolTests {
    private let testnetUnifiedAddress =
        "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3"

    @Test func classifiesUnifiedAddress() {
        let tool = DerivationToolClient.liveValue
        #expect(tool.isUnifiedAddress(testnetUnifiedAddress, .testnet))
        #expect(tool.isZcashAddress(testnetUnifiedAddress, .testnet))
        #expect(tool.doesAddressSupportMemo(testnetUnifiedAddress, .testnet))
        #expect(!tool.isSaplingAddress(testnetUnifiedAddress, .testnet))
        #expect(!tool.isTransparentAddress(testnetUnifiedAddress, .testnet))
        #expect(!tool.isTexAddress(testnetUnifiedAddress, .testnet))
    }

    @Test func rejectsInvalidAddress() {
        let tool = DerivationToolClient.liveValue
        #expect(!tool.isZcashAddress("definitely-not-an-address", .testnet))
        #expect(!tool.isUnifiedAddress("definitely-not-an-address", .testnet))
        #expect(!tool.doesAddressSupportMemo("definitely-not-an-address", .testnet))
    }

    @Test func mainnetContextRejectsTestnetAddress() {
        // A testnet unified address must not validate under mainnet.
        #expect(!DerivationToolClient.liveValue.isZcashAddress(testnetUnifiedAddress, .mainnet))
    }
}
