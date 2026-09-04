//
//  SendFormSendFailedAlertTests.swift
//  zodlTests
//
//  Covers SendForm's `.sendFailed` handling (Features/SendForm/SendFormStore.swift): a
//  non-insufficient-balance failure must always surface the fallback alert, not only when
//  `confirmationType == .send`. The `.getProposal` catch also sends `.sendFailed` with
//  `.requestPayment` (a failed payment-request scan), and no other reducer presents that
//  failure — so gating the alert on `.send` silently swallowed it.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct SendFormSendFailedAlertTests {
    @MainActor @Test func sendFailedAlwaysSetsAlertRegardlessOfConfirmationType() async {
        let store = TestStore(initialState: SendForm.State.initial) {
            SendForm()
        }

        let error = ZcashError.rustProposalScanRequired

        await store.send(.sendFailed(error, .requestPayment)) {
            $0.alert = AlertState.sendFailure(error)
        }
    }
}
