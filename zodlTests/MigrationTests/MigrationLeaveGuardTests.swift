//
//  MigrationLeaveGuardTests.swift
//  zodlTests
//
//  MOB-1466 (field finding O5): the PRE-COMMIT Transfer Plan screen's toolbar back button no
//  longer leaves silently while nothing has been confirmed yet — the product owner backed out
//  without confirming 8/8 times, and an unconfirmed user was indistinguishable from one who chose
//  not to migrate. `.backTapped` (wired from `.zashiBack(customDismiss:)`) intercepts the tap and
//  decides: present the guard sheet, or pass straight through.
//
//  Two pass-through carve-outs, both pinned here: an already-confirmed visit (`State.hasConfirmed`),
//  and the acknowledge-only variants (`requiresSigning == false` — the rescheduled/expired-recovery
//  review's Confirm is pure navigation over an ALREADY-committed schedule; see `State.confirmIntent`
//  `.acknowledge`'s own doc — tapping Confirm there would sign/store nothing, so backing out loses
//  nothing either). Both leave via the SAME `.delegate(.leftWithoutConfirming)` an explicit "Leave
//  anyway" sends — `MigrationCoordFlowCoordinator` just pops either way, same as an ordinary back.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationLeaveGuardTests {
    private static func store(requiresSigning: Bool = true, hasConfirmed: Bool = false) -> TestStoreOf<MigrationTransferPlan> {
        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: requiresSigning)
        state.hasConfirmed = hasConfirmed
        return TestStore(initialState: state) {
            MigrationTransferPlan()
        }
    }

    // MARK: - The guard

    @Test func backTappedWhileUnconfirmedPresentsTheGuard() async {
        let store = Self.store()

        await store.send(.backTapped) {
            $0.isLeaveGuardPresented = true
        }
        // Nothing popped: no delegate was sent, and nothing further arrives.
        await store.finish()
    }

    @Test func stayClosesTheGuardAndStaysOnScreen() async {
        let store = Self.store()

        await store.send(.backTapped) {
            $0.isLeaveGuardPresented = true
        }
        await store.send(.leaveGuardStayTapped) {
            $0.isLeaveGuardPresented = false
        }
        // Still on screen: no delegate was sent either before or after.
        await store.finish()
    }

    @Test func leaveAnywaySendsTheDelegate() async {
        let store = Self.store()

        await store.send(.backTapped) {
            $0.isLeaveGuardPresented = true
        }
        await store.send(.leaveGuardLeaveTapped) {
            $0.isLeaveGuardPresented = false
        }
        await store.receive(.delegate(.leftWithoutConfirming))
    }

    // MARK: - The pass-through carve-outs

    /// Simulates state after the confirmed path (`.scheduleSigned`/`.acknowledge` both set
    /// `hasConfirmed`) — backing out no longer needs a second confirmation.
    @Test func backTappedAfterACompletedConfirmPassesThrough() async {
        let store = Self.store(hasConfirmed: true)

        await store.send(.backTapped)
        await store.receive(.delegate(.leftWithoutConfirming))
    }

    /// The rescheduled/expired-recovery review variant: `requiresSigning == false` means
    /// `confirmIntent` is `.acknowledge` — tapping Confirm here would sign/store nothing (the
    /// schedule was already committed one screen earlier), so the guard never applies at all, even
    /// on a screen the user has not "confirmed" this visit.
    @Test func backTappedOnAnAcknowledgeOnlyVariantPassesThroughEvenUnconfirmed() async {
        let store = Self.store(requiresSigning: false)

        await store.send(.backTapped)
        await store.receive(.delegate(.leftWithoutConfirming))
    }
}
