//
//  SendFormOrchardDisclaimerTests.swift
//  zodlTests
//
//  Covers SendForm's Orchard-spend disclaimer (MOB-1487 R3): Features/SendForm/SendFormStore.swift.
//  Detection hooks `.zecAmountUpdated` — whenever the entered ZEC amount changes, if Ironwood is
//  active (`migrationManager.isIronwoodActivated()`) and the text parses to a positive amount, a
//  `sdkSynchronizer.sendRequiresOrchardFunds` dry-run runs and its result drives
//  `isOrchardSpendDisclaimerVisible`; otherwise the flag drops to false and any in-flight dry-run
//  is cancelled, without ever calling the stub.
//
//  NOTE: the detection parses `zecAmountText` via the `numberFormatter` dependency directly rather
//  than `state.amount`/`state.isValidAmount` — those computed properties are hardcoded under
//  `_XCTIsTesting` (see SendFormAddressValidationTests.swift's note) and would make this
//  untestable, always reporting `.zero`/`true` regardless of what's typed.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct SendFormOrchardDisclaimerTests {
    @MainActor @Test func defaultStateHasDisclaimerHidden() async {
        let state = SendForm.State.initial

        #expect(state.isOrchardSpendDisclaimerVisible == false)
    }

    @MainActor @Test func activatedWithPositiveAmountAndStubTrueShowsDisclaimer() async {
        let store = makeStore(isActivated: true, requiresOrchardFunds: { _ in true })

        await store.send(.zecAmountUpdated("1".redacted))
        await store.receive(\.orchardSpendCheckResult) {
            $0.isOrchardSpendDisclaimerVisible = true
        }
    }

    @MainActor @Test func activatedWithPositiveAmountAndStubFalseHidesDisclaimer() async {
        var initialState = SendForm.State.initial
        initialState.isOrchardSpendDisclaimerVisible = true
        let store = makeStore(initialState: initialState, isActivated: true, requiresOrchardFunds: { _ in false })

        await store.send(.zecAmountUpdated("1".redacted))
        await store.receive(\.orchardSpendCheckResult) {
            $0.isOrchardSpendDisclaimerVisible = false
        }
    }

    @MainActor @Test func notActivatedNeverCallsTheStubAndStaysHidden() async {
        let callCount = LockIsolated<Int>(0)
        let store = makeStore(isActivated: false, requiresOrchardFunds: { _ in
            callCount.withValue { $0 += 1 }
            return true
        })

        await store.send(.zecAmountUpdated("1".redacted))

        #expect(store.state.isOrchardSpendDisclaimerVisible == false)
        #expect(callCount.value == 0)
    }

    @MainActor @Test func clearingTheAmountHidesDisclaimerWithoutCallingTheStub() async {
        let callCount = LockIsolated<Int>(0)
        var initialState = SendForm.State.initial
        initialState.isOrchardSpendDisclaimerVisible = true
        let store = makeStore(initialState: initialState, isActivated: true, requiresOrchardFunds: { _ in
            callCount.withValue { $0 += 1 }
            return true
        })

        await store.send(.zecAmountUpdated(.empty)) {
            $0.isOrchardSpendDisclaimerVisible = false
        }

        #expect(callCount.value == 0)
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        initialState: SendForm.State = .initial,
        isActivated: Bool,
        requiresOrchardFunds: @escaping @Sendable (Zatoshi) async -> Bool = { _ in false }
    ) -> TestStoreOf<SendForm> {
        let store = TestStore(initialState: initialState) {
            SendForm()
        } withDependencies: {
            $0.migrationManager.isIronwoodActivated = { isActivated }
            $0.sdkSynchronizer.sendRequiresOrchardFunds = requiresOrchardFunds
            $0.numberFormatter.number = { text in
                Double(text).map { value in NSNumber(value: value) }
            }
        }
        store.exhaustivity = .off
        return store
    }
}
