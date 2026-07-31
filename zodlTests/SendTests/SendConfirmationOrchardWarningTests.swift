//
//  SendConfirmationOrchardWarningTests.swift
//  zodlTests
//
//  Covers the Orchard-spend warning bottom sheet shown on the send confirmation screen when the
//  payment proposal spends legacy Orchard funds (Figma node 5139-23856): the `.onAppear`
//  presentation gate, the one-shot `orchardWarningShown` flag that keeps it from re-presenting
//  (SignWithKeystoneView shares this reducer and re-fires `.onAppear`), and the two-step cancel
//  flow. Cancel must only turn into `.cancelTapped` once the sheet has actually finished
//  dismissing (`.orchardWarningDismissed`, sent from the sheet's `onDismiss`) — otherwise SwiftUI
//  would pop a screen that still presents a sheet.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `SendConfirmation.State` carries `@Shared(.inMemory(...))` process-global storage (address book
// contacts, feature flags, wallet accounts). `.serialized` only orders this suite's own tests — it
// does NOT prevent other suites from running in parallel with it — so each test also binds a fresh
// in-memory store via `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }`, which is
// what actually isolates this suite from cross-suite races on that storage. Same idiom as
// `KeystoneFirmwareTests.swift`'s `KeystoneFirmwareGateTests`.
@Suite(.serialized) @MainActor struct SendConfirmationOrchardWarningTests {
    private func makeState(proposal: Proposal?) -> SendConfirmation.State {
        SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: proposal
        )
    }

    private func makeStore(_ state: SendConfirmation.State) -> TestStore<SendConfirmation.State, SendConfirmation.Action> {
        TestStore(initialState: state) {
            SendConfirmation()
        } withDependencies: {
            $0.derivationTool = .liveValue
            $0.zcashSDKEnvironment = .testnet
        }
    }

    // MARK: - .onAppear presentation gate

    @Test func onAppearPresentsWarningWhenProposalSpendsLegacyOrchardFunds() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            let store = makeStore(makeState(proposal: proposal))
            store.exhaustivity = .off

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.isOrchardWarningPresented)
            #expect(store.state.orchardWarningShown)
        }
    }

    @Test func onAppearDoesNotPresentWarningWhenProposalDoesNotSpendLegacyOrchardFunds() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0)
            let store = makeStore(makeState(proposal: proposal))
            store.exhaustivity = .off

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(!store.state.orchardWarningShown)
        }
    }

    @Test func onAppearDoesNotPresentWarningWhenProposalIsNil() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(makeState(proposal: nil))
            store.exhaustivity = .off

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(!store.state.orchardWarningShown)
        }
    }

    @Test func onAppearDoesNotRepresentWarningOnceAlreadyShown() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            var initialState = makeState(proposal: proposal)
            // Simulates returning to this reducer's `.onAppear` a second time (e.g. after pushing
            // into `confirmWithKeystone` and coming back) once the warning already ran its course.
            initialState.orchardWarningShown = true
            initialState.isOrchardWarningPresented = false

            let store = makeStore(initialState)
            store.exhaustivity = .off

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(store.state.orchardWarningShown)
        }
    }

    // MARK: - Continue anyway

    @Test func continueTappedHidesSheetWithNoFollowUpActions() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            var initialState = makeState(proposal: proposal)
            initialState.isOrchardWarningPresented = true
            initialState.orchardWarningShown = true

            let store = makeStore(initialState)

            await store.send(.orchardWarningContinueTapped) {
                $0.isOrchardWarningPresented = false
            }
            // Exhaustive TestStore: reaching `finish()` cleanly with no `.receive` call IS the
            // "no follow-up actions" assertion — an unreceived action would fail here instead.
            await store.finish()
        }
    }

    // MARK: - Cancel

    @Test func cancelTappedThenDismissedSendsCancelTapped() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            var initialState = makeState(proposal: proposal)
            initialState.isOrchardWarningPresented = true
            initialState.orchardWarningShown = true

            let store = makeStore(initialState)

            await store.send(.orchardWarningCancelTapped) {
                $0.isOrchardWarningPresented = false
                $0.pendingCancelFromOrchardWarning = true
            }
            // Only once the sheet has actually finished dismissing does cancel turn into
            // `.cancelTapped` — never directly from `.orchardWarningCancelTapped`.
            await store.send(.orchardWarningDismissed) {
                $0.pendingCancelFromOrchardWarning = false
            }
            await store.receive(.cancelTapped)
            await store.finish()
        }
    }

    @Test func dismissedWithoutPendingCancelSendsNoActions() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            var initialState = makeState(proposal: proposal)
            // Swipe-down dismissal with no pending cancel (e.g. after "Continue anyway" already
            // hid the sheet) behaves like "Continue anyway": the user stays, no navigation.
            initialState.isOrchardWarningPresented = false
            initialState.orchardWarningShown = true
            initialState.pendingCancelFromOrchardWarning = false

            let store = makeStore(initialState)

            await store.send(.orchardWarningDismissed)
            await store.finish()
        }
    }
}
