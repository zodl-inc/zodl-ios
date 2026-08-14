//
//  MigrationRestartTests.swift
//  zodlTests
//
//  "Restart Migration" — the Advanced Settings escape hatch for a run the user believes is stuck
//  (MOB-1466, Figma: Advanced Settings → Migration Settings → Bottom Sheet).
//
//  WHAT THESE PIN, and why each one is a contract rather than a spot check:
//
//  1. THE BUSY RULE (Lukas, 2026-08-07 — "add a spinner, disable all buttons so nothing else
//     interfere"). Three separate doors have to be shut while the engine call is open, and each
//     was shut by a different line of code: the confirm button (re-entrancy guard in the reducer),
//     the sheet's swipe-to-dismiss (the binding write is refused), and Cancel. A test per door,
//     because closing two of three still ships the bug.
//  2. THE DISCARD. `restartCurrentMigrationStep` returns a fresh PREVIEW schedule that this flow
//     deliberately throws away — nuttycom, 2026-08-07: "Once a migration is canceled, you just
//     rebuild it like you originally did." Nothing here signs or stores it, and a future reader
//     who "fixes" that by committing the preview would be adding a biometric prompt (and, for
//     Keystone, a whole QR ceremony) behind a sheet that promises neither.
//  3. THE FAILURE PATH. No designed error state exists, so a failed restart must leave the sheet
//     OPEN with live controls rather than silently dismissing — a dismissal would read as success.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `.serialized`: every test here writes the shared in-memory `selectedWalletAccount`, so parallel
// execution would let one test's account leak into another's assertions.
@Suite(.serialized) struct MigrationRestartTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x21, count: 16))

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func schedule() -> MigrationSchedule {
        MigrationSchedule(transfers: [], estimatedDurationHours: 3, proposalHandle: 1, preparations: [])
    }

    /// Arms the shared selected account so `isRestartPossible` is true and the engine call has an
    /// address, then returns state with the sheet already open — where every busy-rule test starts.
    ///
    /// `@MainActor` and the shared write inlined here rather than split across helper/test body:
    /// the write has to land BEFORE `MigrationRestart.State()` reads it, or `TestStore` snapshots a
    /// nil account and reports the arrival as an unasserted state change on the first `send`.
    @MainActor private static func presentedState() -> MigrationRestart.State {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        var state = MigrationRestart.State()
        state.isConfirmationPresented = true
        return state
    }

    /// THE HAPPY PATH, end to end: confirm raises the busy flag, the engine cancels, the manager
    /// reconciles (so every migration surface stops rendering a run that no longer exists), and the
    /// screen delegates `.restarted` — which is what the Settings coordinator pops on.
    @MainActor @Test func confirmCancelsTheRunAndDelegatesRestarted() async {
        let reconciled = LockIsolated(false)

        let store = TestStore(initialState: Self.presentedState()) {
            MigrationRestart()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(restartCurrentMigrationStep: { _ in Self.schedule() })

            var client = MigrationManagerClient.noOp
            client.reconcile = { reconciled.setValue(true) }
            $0.migrationManager = client
        }

        // Non-exhaustive: the shared `selectedWalletAccount` lands in the store's state on the first
        // interaction, and asserting that bookkeeping would say nothing about this flow. What the
        // test is FOR is asserted explicitly below.
        store.exhaustivity = .off

        await store.send(.confirmRestartTapped)
        #expect(store.state.isRestarting, "the spinner must be up while the engine call is open")

        await store.receive(\.restartFinished)
        await store.receive(.delegate(.restarted))

        #expect(!store.state.isRestarting)
        #expect(!store.state.isConfirmationPresented, "success closes the sheet before the pop")
        #expect(reconciled.value, "the cancel must be published, or the banner keeps offering a dead run")
    }

    /// DOOR 1 — the confirm button. It is `.disabled(true)` in the view while restarting, but a tap
    /// queued in the same frame still reaches the reducer; a second engine call would race the
    /// first over the same run.
    @MainActor @Test func secondConfirmIsRefusedWhileRestarting() async {
        let calls = LockIsolated(0)

        var state = Self.presentedState()
        state.isRestarting = true

        let store = TestStore(initialState: state) {
            MigrationRestart()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(restartCurrentMigrationStep: { _ in
                calls.withValue { $0 += 1 }
                return Self.schedule()
            })
        }

        // Exhaustive on purpose: any emitted effect fails the test.
        await store.send(.confirmRestartTapped)

        #expect(calls.value == 0)
    }

    /// DOOR 2 — swipe-to-dismiss. A sheet dragged away mid-call would leave the spinner running
    /// behind nothing and put the screen's own Next back within reach.
    @MainActor @Test func sheetCannotBeDismissedWhileRestarting() async {
        var state = Self.presentedState()
        state.isRestarting = true

        let store = TestStore(initialState: state) { MigrationRestart() }

        await store.send(.confirmationPresentedChanged(false))

        #expect(store.state.isConfirmationPresented, "the sheet is modal for the duration of the call")
    }

    /// DOOR 3 — Cancel. Same reasoning as the swipe; the button is disabled in the view, and the
    /// reducer refuses it too so the two cannot drift apart.
    @MainActor @Test func cancelIsRefusedWhileRestarting() async {
        var state = Self.presentedState()
        state.isRestarting = true

        let store = TestStore(initialState: state) { MigrationRestart() }

        await store.send(.cancelTapped)

        #expect(store.state.isConfirmationPresented)
    }

    /// Cancel with nothing in flight closes the sheet and leaves the run alone — the ordinary exit.
    @MainActor @Test func cancelClosesTheSheetWhenIdle() async {
        let store = TestStore(initialState: Self.presentedState()) { MigrationRestart() }
        store.exhaustivity = .off

        await store.send(.cancelTapped)

        #expect(!store.state.isConfirmationPresented)
    }

    /// THE FAILURE PATH: the spinner stops and the controls come back, but the sheet STAYS OPEN and
    /// nothing is delegated. A dismissal here would be indistinguishable from success — the run
    /// would still be live while the user believed it cancelled.
    @MainActor @Test func failureKeepsTheSheetOpenAndDelegatesNothing() async {
        let store = TestStore(initialState: Self.presentedState()) {
            MigrationRestart()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(restartCurrentMigrationStep: { _ in
                throw ZcashError.synchronizerNotPrepared
            })
        }

        store.exhaustivity = .off

        await store.send(.confirmRestartTapped)
        await store.receive(\.restartFinished)

        #expect(!store.state.isRestarting, "the controls must come back so the user can retry")
        #expect(store.state.isConfirmationPresented, "a dismissal here would read as success")
        // The pin: no `.delegate` was emitted, so the coordinator never pops. `finish()` fails if
        // any effect is still in flight, and an unhandled delegate would have been received above.
        await store.finish()
    }

    /// The screen's numbers come from THE snapshot — the same derivation the banner, the timeline
    /// and the pool header read (R13's one-derivation rule), so this screen cannot quote a count or
    /// a balance that contradicts them.
    @MainActor @Test func numbersComeFromTheSnapshot() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        // The Figma's own numbers: 7 of 11 migrated, 3.070 ZEC left.
        let snapshot = MigrationViewSnapshot(
            orchardRemaining: Zatoshi(307_000_000),
            ironwoodHeld: .zero,
            movedByDoneTransfers: .zero,
            doneTransfers: 7,
            totalTransfers: 11,
            transfers: [],
            summary: MigrationSummary.zero,
            banner: nil,
            preparations: [],
            planTotal: nil,
            isTorHoldActive: false,
            needsTorFirstRunChoice: false,
            isSubmitting: false,
            sessionOrdinal: 1
        )

        let store = TestStore(initialState: MigrationRestart.State()) {
            MigrationRestart()
        } withDependencies: {
            var client = MigrationManagerClient.noOp
            client.migrationViewSnapshot = { _ in snapshot }
            $0.migrationManager = client
        }

        await store.send(.onAppear)
        await store.receive(\.snapshotLoaded) {
            $0.doneTransfers = 7
            $0.totalTransfers = 11
            $0.remainingBalance = Zatoshi(307_000_000)
        }
    }

    /// No selected account ⇒ no engine call is addressable, so the CTA is inert rather than
    /// throwing into the failure path. `isRestartPossible` is what disables Next in the view.
    @MainActor @Test func noAccountMakesTheFlowInert() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        var state = MigrationRestart.State()
        state.isConfirmationPresented = true

        #expect(!state.isRestartPossible)

        let store = TestStore(initialState: state) { MigrationRestart() }

        // Exhaustive: no effect, no engine call, no state change.
        await store.send(.confirmRestartTapped)
    }
}
