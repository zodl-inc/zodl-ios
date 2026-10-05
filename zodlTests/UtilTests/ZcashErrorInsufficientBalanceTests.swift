//
//  ZcashErrorInsufficientBalanceTests.swift
//  zodlTests
//
//  Covers ZcashError.isInsufficientBalance (Utils/ZcashError+DetailedMessage.swift). The typed
//  `.rustProposalInsufficientFunds` case must be detected directly — the redacted Rust errors no
//  longer produce the legacy detailedMessage text this flag used to match on. The old text match
//  is kept as a fallback for any error that still carries it (e.g. from an older SDK build), and
//  an unrelated typed error must not be flagged.
//

import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct ZcashErrorInsufficientBalanceTests {
    @Test func typedInsufficientFundsCaseIsDetected() {
        let error = ZcashError.rustProposalInsufficientFunds(Zatoshi(1), Zatoshi(2))
        #expect(error.isInsufficientBalance)
    }

    @Test func legacyDetailedMessageTextIsStillDetectedAsFallback() {
        let error = ZcashError.rustCreateToAddress(
            RedactedRustError(kind: .unclassified, message: "Insufficient balance for this transaction")
        )
        #expect(error.isInsufficientBalance)
    }

    @Test func unrelatedTypedErrorIsNotInsufficientBalance() {
        let error = ZcashError.rustProposalScanRequired
        #expect(!error.isInsufficientBalance)
    }
}
