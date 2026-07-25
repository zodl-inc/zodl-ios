//
//  MigrationCompleteTests.swift
//  zodlTests
//
//  Covers the MigrationComplete reducer
//  (Features/Migration/MigrationComplete/MigrationCompleteStore.swift) for MOB-1464/1466: the
//  `hasDust` derivation at zero/nonzero dust, and the `gotItTapped` delegate contract. This screen
//  has no back control at all (`.navigationBarBackButtonHidden()`, no custom leading toolbar item)
//  — `isFlowRoot` is added to State for coordinator-injection consistency with the other re-entry
//  roots, but there is no back-control behavior to gate here. No SDK calls, no navigation. No
//  shared/global state -> no `.serialized`.
//
//  MOB-1487 (round 2): adds the dust-resolution machinery. `dustResolution` derives from `dust` at
//  init (`.offered` when > `.zero`, else `.none`) unless a caller pins it explicitly — covered below
//  alongside the `lockBalanceTapped` -> `migrationManager.lockMigrationDust()` -> `.locked`/`.offered`
//  (+alert) round trip, the `.offered`-only guard on `lockBalanceTapped`, `migrateAnywayTapped`'s
//  delegate, and the alert dismiss path. `lockMigrationDust` is overridden directly on the
//  dependency (`$0.migrationManager.lockMigrationDust = ...`), matching how the other Migration
//  reducer tests override manager/SDK members. Still no shared/global state -> no `.serialized`.
//
//  MOB-1487 (round 3): adds the lock explainer sheet's presentation pair — `lockExplainerHelpTapped`
//  sets `isLockExplainerPresented` true, `lockExplainerDismissed` sets it false. Neither is gated on
//  `dustResolution` (the view alone decides when to show the trigger), so there's nothing to pin
//  beyond the default state. `isLockExplainerPresented` isn't part of the memberwise `init` (like
//  `alert`, it's presentation-only), so the dismiss test mutates it directly before constructing the
//  `TestStore`, matching `alertDismissClearsAlertState`'s existing idiom below.
//
//  MOB-1458 (code review — F4): `migrateAnywayTapped` now sets `State.isMigratingAnyway` (single-
//  flight for the coordinator's device-authentication gate that follows this delegate) with a guard
//  that makes a second tap a no-op while it's still `true` — covered below alongside the existing
//  delegate-emission pin. The coordinator's own clearing of the flag (on a refusal or a post-gate
//  failure) is covered in `MigrationCoordFlowTests.swift`, not here, since that's coordinator-owned
//  behavior this screen's own reducer has no part in.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationCompleteTests {
    private struct LockDustFailure: Error { }

    @MainActor @Test func defaultStateIsAllZeroWithNoDust() async {
        let state = MigrationComplete.State()

        // MOB-1513: `totalTransferred`/`durationHours` default `nil` (unknown), never a
        // placeholder zero — the same convention `MigrationSummary`'s W1 fallback uses.
        #expect(state.totalTransferred == nil)
        #expect(state.dust == Zatoshi.zero)
        #expect(state.transfersSent == 0)
        #expect(state.transfersTotal == 0)
        #expect(state.durationHours == nil)
        #expect(state.hasDust == false)
        #expect(state.isFlowRoot == false)
        #expect(state.dustResolution == MigrationComplete.State.DustResolution.none)
        #expect(state.alert == nil)
        #expect(state.isLockExplainerPresented == false)
        #expect(state.isMigratingAnyway == false)
    }

    @MainActor @Test func hasDustIsFalseWhenDustIsZero() async {
        let state = MigrationComplete.State(dust: Zatoshi.zero)

        #expect(state.hasDust == false)
    }

    @MainActor @Test func hasDustIsTrueWhenDustIsNonzero() async {
        let state = MigrationComplete.State(dust: Zatoshi(31_000))

        #expect(state.hasDust)
    }

    @MainActor @Test func gotItTappedEmitsDelegateDone() async {
        let store = TestStore(initialState: MigrationComplete.State()) {
            MigrationComplete()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationComplete.State()) {
            MigrationComplete()
        }

        await store.send(.delegate(.done))
    }

    // MARK: - MOB-1487: dustResolution derivation

    @MainActor @Test func dustResolutionDefaultsToNoneWhenDustIsZero() async {
        let state = MigrationComplete.State(dust: Zatoshi.zero)

        #expect(state.dustResolution == MigrationComplete.State.DustResolution.none)
    }

    @MainActor @Test func dustResolutionDefaultsToOfferedWhenDustIsNonzero() async {
        let state = MigrationComplete.State(dust: Zatoshi(31_000))

        #expect(state.dustResolution == MigrationComplete.State.DustResolution.offered)
    }

    @MainActor @Test func explicitDustResolutionOverridesTheDerivedDefault() async {
        // The coordinator's `completeState(isFlowRoot:)` never names this parameter, so the derived
        // default is what drives the shipped app -- this only exercises the escape hatch tests use
        // to pin a specific sub-state (e.g. landing directly on `.locked`) without replaying the
        // reducer transitions that would normally produce it.
        let state = MigrationComplete.State(dust: Zatoshi(31_000), dustResolution: .locked)

        #expect(state.dustResolution == MigrationComplete.State.DustResolution.locked)
    }

    // MARK: - MOB-1487: lockBalanceTapped is a no-op outside `.offered`

    @MainActor @Test func lockBalanceTappedIsNoOpWhenDustResolutionIsNone() async {
        let store = TestStore(initialState: MigrationComplete.State(dust: Zatoshi.zero)) {
            MigrationComplete()
        }

        // dustResolution == .none here (derived) -- lockBalanceTapped only starts from `.offered`,
        // so this produces neither a state change nor an effect.
        await store.send(.lockBalanceTapped)
    }

    @MainActor @Test func lockBalanceTappedIsNoOpWhenDustResolutionIsAlreadyLocked() async {
        let store = TestStore(
            initialState: MigrationComplete.State(dust: Zatoshi(31_000), dustResolution: .locked)
        ) {
            MigrationComplete()
        }

        await store.send(.lockBalanceTapped)
    }

    // MARK: - MOB-1487: lockBalanceTapped happy path

    @MainActor @Test func lockBalanceTappedSucceedsGoesOfferedToLockingToLocked() async {
        let store = TestStore(initialState: MigrationComplete.State(dust: Zatoshi(31_000))) {
            MigrationComplete()
        } withDependencies: {
            $0.migrationManager.lockMigrationDust = { _ in }
        }

        #expect(store.state.dustResolution == MigrationComplete.State.DustResolution.offered)

        await store.send(.lockBalanceTapped) {
            $0.dustResolution = .locking
        }
        await store.receive(.lockDustSucceeded) {
            $0.dustResolution = .locked
        }
    }

    // MARK: - MOB-1487: lockBalanceTapped failure path

    @MainActor @Test func lockBalanceTappedFailureRevertsToOfferedAndPresentsAlert() async {
        let store = TestStore(initialState: MigrationComplete.State(dust: Zatoshi(31_000))) {
            MigrationComplete()
        } withDependencies: {
            $0.migrationManager.lockMigrationDust = { _ in throw LockDustFailure() }
        }
        store.exhaustivity = .off

        await store.send(.lockBalanceTapped)
        await store.receive(\.lockDustFailed)

        #expect(store.state.dustResolution == MigrationComplete.State.DustResolution.offered)
        #expect(store.state.alert != nil)
    }

    @MainActor @Test func alertDismissClearsAlertState() async {
        var state = MigrationComplete.State(dust: Zatoshi(31_000))
        state.alert = AlertState.lockFailed()
        let store = TestStore(initialState: state) {
            MigrationComplete()
        }

        await store.send(.alert(.dismiss)) {
            $0.alert = nil
        }
    }

    // MARK: - MOB-1487: migrateAnywayTapped

    /// MOB-1458 (code review — F4): the tap now also sets the single-flight guard
    /// (`State.isMigratingAnyway`) synchronously, alongside the pre-existing delegate emission.
    @MainActor @Test func migrateAnywayTappedEmitsDelegateMigrateAnyway() async {
        let store = TestStore(initialState: MigrationComplete.State(dust: Zatoshi(31_000))) {
            MigrationComplete()
        }

        await store.send(.migrateAnywayTapped) {
            $0.isMigratingAnyway = true
        }
        await store.receive(.delegate(.migrateAnyway))
    }

    /// MOB-1458 (code review — F4): single-flight — a second tap while `isMigratingAnyway` is
    /// already `true` (the coordinator's device-authentication gate, or the unlock/propose leg
    /// that follows a pass, still in flight) is a complete no-op: no second
    /// `.delegate(.migrateAnyway)`, no state change. The view's `.disabled` mirrors this so the
    /// common double-tap never reaches here at all; this pins the reducer-level backstop directly.
    @MainActor @Test func migrateAnywayTappedIsNoOpWhileAlreadyInFlight() async {
        var state = MigrationComplete.State(dust: Zatoshi(31_000))
        state.isMigratingAnyway = true
        let store = TestStore(initialState: state) {
            MigrationComplete()
        }

        await store.send(.migrateAnywayTapped)
    }

    // MARK: - MOB-1487 (round 3): lock explainer sheet present/dismiss pair

    @MainActor @Test func lockExplainerHelpTappedPresentsLockExplainer() async {
        let store = TestStore(initialState: MigrationComplete.State(dust: Zatoshi(31_000))) {
            MigrationComplete()
        }

        await store.send(.lockExplainerHelpTapped) {
            $0.isLockExplainerPresented = true
        }
    }

    @MainActor @Test func lockExplainerDismissedClearsLockExplainerPresented() async {
        var state = MigrationComplete.State(dust: Zatoshi(31_000))
        state.isLockExplainerPresented = true
        let store = TestStore(initialState: state) {
            MigrationComplete()
        }

        await store.send(.lockExplainerDismissed) {
            $0.isLockExplainerPresented = false
        }
    }

    // MARK: - MOB-1487: gotItTapped from `.locked` behaves exactly like from `.none`

    @MainActor @Test func gotItTappedFromLockedEmitsDelegateDone() async {
        let store = TestStore(
            initialState: MigrationComplete.State(dust: Zatoshi(31_000), dustResolution: .locked)
        ) {
            MigrationComplete()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }
}
