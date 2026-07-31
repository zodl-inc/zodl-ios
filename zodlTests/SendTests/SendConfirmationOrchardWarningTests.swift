//
//  SendConfirmationOrchardWarningTests.swift
//  zodlTests
//
//  Covers the Orchard-spend warning bottom sheet shown on the send confirmation screen when the
//  payment proposal spends legacy Orchard funds: the `.confirmationScreenAppeared` presentation
//  gate (deliberately separate from `.onAppear`, so screens that share this reducer but never send
//  `.confirmationScreenAppeared` — e.g. the SwapAndPay flow pushing `confirmWithKeystone` with a
//  fresh state — can never trip or burn the one-shot latch), the `orchardWarningShown` flag that
//  keeps it from re-presenting on a pop-return, and the two-step cancel flow. Cancel must only turn
//  into `.cancelTapped` once the sheet has actually finished dismissing (`.orchardWarningDismissed`,
//  sent from the sheet's `onDismiss`) — otherwise SwiftUI would pop a screen that still presents a
//  sheet.
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
        }
    }

    // MARK: - .confirmationScreenAppeared presentation gate

    @Test func confirmationScreenAppearedPresentsWarningWhenProposalSpendsLegacyOrchardFunds() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            let store = makeStore(makeState(proposal: proposal))
            store.exhaustivity = .off

            await store.send(.confirmationScreenAppeared)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.isOrchardWarningPresented)
            #expect(store.state.orchardWarningShown)
        }
    }

    @Test func confirmationScreenAppearedDoesNotPresentWarningWhenProposalDoesNotSpendLegacyOrchardFunds() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0)
            let store = makeStore(makeState(proposal: proposal))
            store.exhaustivity = .off

            await store.send(.confirmationScreenAppeared)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(!store.state.orchardWarningShown)
        }
    }

    @Test func confirmationScreenAppearedDoesNotPresentWarningWhenProposalIsNil() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(makeState(proposal: nil))
            store.exhaustivity = .off

            await store.send(.confirmationScreenAppeared)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(!store.state.orchardWarningShown)
        }
    }

    @Test func confirmationScreenAppearedDoesNotRepresentWarningOnceAlreadyShown() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            var initialState = makeState(proposal: proposal)
            // Simulates returning to this screen a second time (e.g. after pushing into
            // confirmWithKeystone and coming back), which re-fires `.confirmationScreenAppeared`,
            // once the warning already ran its course.
            initialState.orchardWarningShown = true
            initialState.isOrchardWarningPresented = false

            let store = makeStore(initialState)
            store.exhaustivity = .off

            await store.send(.confirmationScreenAppeared)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(store.state.orchardWarningShown)
        }
    }

    // MARK: - .onAppear no longer gates the warning

    @Test func onAppearAloneNeverPresentsWarningEvenWithOrchardSpendingProposal() async {
        // Regression coverage: before the gate moved to a dedicated action, `.onAppear` alone
        // would present the warning. Screens that only ever send `.onAppear` (none currently do,
        // but nothing stops a future one) must never see it fire.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
            $0.derivationTool = .liveValue
            $0.zcashSDKEnvironment = .testnet
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0, spendsLegacyOrchardFunds: true)
            let store = makeStore(makeState(proposal: proposal))
            store.exhaustivity = .off

            await store.send(.onAppear)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!store.state.isOrchardWarningPresented)
            #expect(!store.state.orchardWarningShown)
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
