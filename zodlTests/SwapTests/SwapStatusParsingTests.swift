//
//  SwapStatusParsingTests.swift
//  zodlTests
//
//  MOB-1354 / iOS-Z10 — the swap status parser must fail closed: an unrecognized server status maps
//  to `.unknown`, never silently to `.pending`. Known statuses still map to their expected cases.
//

import Testing
@testable import zodl_internal

@Suite struct SwapStatusParsingTests {
    @Test func unrecognizedStatusMapsToUnknownNotPending() {
        #expect(SwapDetails.Status.from(serverStatus: "WAT", isSwapToZec: false) == .unknown)
        #expect(SwapDetails.Status.from(serverStatus: "WAT", isSwapToZec: true) == .unknown)
        #expect(SwapDetails.Status.from(serverStatus: "", isSwapToZec: false) == .unknown)
        #expect(SwapDetails.Status.from(serverStatus: "", isSwapToZec: true) == .unknown)
    }

    @Test func knownStatusesMapToExpectedCases() {
        // non swap-to-ZEC direction
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.pendingDeposit, isSwapToZec: false) == .pending)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.incompleteDeposit, isSwapToZec: false) == .incompleteDeposit)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.refunded, isSwapToZec: false) == .refunded)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.success, isSwapToZec: false) == .success)

        // swap-to-ZEC direction
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.pendingDeposit, isSwapToZec: true) == .pendingDeposit)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.refunded, isSwapToZec: true) == .refunded)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.success, isSwapToZec: true) == .success)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.failed, isSwapToZec: true) == .failed)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.incompleteDeposit, isSwapToZec: true) == .incompleteDeposit)
        #expect(SwapDetails.Status.from(serverStatus: SwapConstants.processing, isSwapToZec: true) == .processing)
    }

    @Test func unknownIsNotTreatedAsPending() {
        #expect(SwapDetails.Status.unknown.isPending == false)
    }
}
