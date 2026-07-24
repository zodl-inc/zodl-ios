//
//  MigrationStatusTests.swift
//  zodlTests
//
//  Covers the MigrationStatus reducer (Features/Migration/MigrationStatus/MigrationStatusStore.swift)
//  for MOB-1464/1466: the default `.progress` presentation, the `gotItTapped`/`sendNowTapped`/
//  `rescheduleTapped` delegate contracts, the `remainingCount` derivation over a mixed row set, and
//  (MOB-1466) `onAppear` loading rows/summary via `migrationTransfers()`/`migrationSummary()` and
//  subscribing `migrationStateStream()` to refresh rows on change, and the `isFlowRoot`-gated
//  close-instead-of-pop back action. No shared/global state -> no `.serialized`.
//
//  MOB-1478 (W7) additions: `sentMinutesAgo`/`isBroadcasting` row fields riding unchanged through
//  `onAppear`/`statusLoaded`, and the `rescheduleCompleted` action's transition to
//  `.rescheduleConfirmed(first:last:)` — deriving the stalled-range numbers from the pre-transition
//  `stalledNumber`/`rows.count`, refreshing rows/duration, and clearing `isRescheduling`.
//
//  R8-T6 (V8 fix) additions: `isSendNowDisabled` is now COMPUTED off `rows` (an `.overdue` row ->
//  enabled) instead of stored from a `manager.sendGate()` read — `statusLoaded` no longer carries a
//  gate reading at all. `onAppearWithDueTransferAndWaitUntilGateEnablesSendNow` is the red-against-
//  HEAD proof: HEAD disables the CTA on `.waitUntil` even with an overdue row present (the V8
//  chicken-and-egg bug); this fix enables it regardless of what the gate says.
//

import Testing
import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationStatusTests {
    @MainActor @Test func defaultStateIsProgressPresentationWithNoRows() async {
        let state = MigrationStatus.State()

        #expect(state.presentation == MigrationStatus.State.Presentation.progress)
        #expect(state.rows.isEmpty)
        // MOB-1513: `nil` (unknown), never a placeholder `0`, until a real load hydrates it.
        #expect(state.totalDurationHours == nil)
        #expect(state.stalledNumber == 0)
        #expect(state.stalledHoursAgo == 0)
        #expect(state.isRescheduling == false)
        #expect(state.isFlowRoot == false)
        // R8-T6: computed off `rows` now — no rows loaded yet means no due (`.overdue`) transfer,
        // so the CTA reads disabled by construction (rather than the old stored default's `false`,
        // which was really just "nothing has set it yet").
        #expect(state.isSendNowDisabled == true)
    }

    @MainActor @Test func gotItTappedEmitsDelegateDone() async {
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }

    @MainActor @Test func sendNowTappedEmitsDelegateSendNow() async {
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        }

        await store.send(.sendNowTapped)
        await store.receive(.delegate(.sendNow))
    }

    @MainActor @Test func rescheduleTappedSetsIsReschedulingAndEmitsDelegateReschedule() async {
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        }

        await store.send(.rescheduleTapped) {
            $0.isRescheduling = true
        }
        await store.receive(.delegate(.reschedule))
    }

    @MainActor @Test func remainingCountCountsAllRowsNotYetSent() async {
        var state = MigrationStatus.State()
        state.rows = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(2_000), status: .sent, hoursFromNow: 11),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(3_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(4_000), status: .pending, hoursFromNow: 1),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(5_000), status: .pending, hoursFromNow: 7)
        ]

        #expect(state.remainingCount == 3)
    }

    @MainActor @Test func remainingCountIsZeroWhenAllRowsSent() async {
        var state = MigrationStatus.State()
        state.rows = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(2_000), status: .sent, hoursFromNow: 11)
        ]

        #expect(state.remainingCount == 0)
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        }

        await store.send(.delegate(.done))
    }

    // MARK: - onAppear: load rows/summary, subscribe to state stream

    @MainActor @Test func onAppearLoadsRowsAndSummary() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .active, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi(351_220_000),
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 2,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.rows = IdentifiedArrayOf(uniqueElements: rows)
            $0.totalDurationHours = 24
        }
        // R8-T6: no `.overdue` row in this fixture -> no due transfer -> CTA disabled, derived
        // straight from the rows `.statusLoaded` just set (no gate consult any more).
        #expect(store.state.isSendNowDisabled == true)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    /// MOB-1496 (W3): `syncPrivacyBufferMinutes` = `Int((migrationPrivacySyncBufferDuration() /
    /// 60).rounded())` — threads the resume footer's formatted minutes off the SDK's real buffer
    /// instead of a hardcoded "10". Uses a non-10-minute value (900s = 15 min) so a stale hardcoded
    /// "10" would visibly fail this assertion.
    @MainActor @Test func onAppearComputesSyncPrivacyBufferMinutesFromSDKDuration() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationPrivacySyncBufferDuration = { 900 }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.syncPrivacyBufferMinutes = 15
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    /// R7 final review, Important-1 (spec §G): `isTorHoldActive` threads through `.statusLoaded` the
    /// same way `isSendNowDisabled`/`syncPrivacyBufferMinutes` do — a live re-derived field, not a
    /// coordinator-hydrate-once one, so it self-heals if the account's Tor hold clears while this
    /// screen is on-screen (via `.migrationStateChanged`'s own `loadStatus` re-run).
    @MainActor @Test func onAppearLoadsTheTorHoldIndicator() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.sendGate = { .allowed }
            $0.migrationManager.isMigrationTorHoldActive = { _ in true }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.isTorHoldActive = true
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func onAppearPreservesSentMinutesAgoAndIsBroadcastingRowFields() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(
                id: "0", index: 0, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 0, sentMinutesAgo: 18
            ),
            MigrationTransferRow(
                id: "1", index: 1, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 0, isBroadcasting: true
            )
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi(287_410_000),
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 2,
            estimatedDurationHours: 12
        )
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.rows = IdentifiedArrayOf(uniqueElements: rows)
            $0.totalDurationHours = 12
        }

        #expect(store.state.rows[id: "0"]?.sentMinutesAgo == 18)
        #expect(store.state.rows[id: "1"]?.isBroadcasting == true)
        // R8-T6: row "1" is `.active`, not `.overdue` -> still no due transfer -> CTA disabled.
        #expect(store.state.isSendNowDisabled == true)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    // MARK: - R8-T6 (V8 fix): due-ness, not the gate, governs the Send-now CTA

    /// "No due transfer -> CTA as today": with nothing `.overdue` in `rows` (the default, empty
    /// set here), the CTA stays disabled exactly like it always has — due-ness alone governs it,
    /// so this holds regardless of what the gate would have said.
    @MainActor @Test func onAppearWithNoDueTransferKeepsSendNowDisabled() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in [] }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded)

        #expect(store.state.isSendNowDisabled == true)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    /// THE V8 fix, red against HEAD: a due (`.overdue`) transfer is present, but the app-side
    /// privacy gate reads `.waitUntil` (the exact chicken-and-egg shape from the finding — a sync
    /// just completed, re-arming the 600s gate, so it's never `.allowed` in normal foreground use).
    /// HEAD disables the CTA here (`isSendNowDisabled` was driven straight off `sendGate()`); this
    /// fix enables it — due-ness alone governs it now, and the gate is enforced later, inside
    /// `MigrationSendingStore`'s Send-now lane (silence-window wait), not here. The `sendGate` mock
    /// is deliberately left in place (unused post-fix) specifically to prove the CTA no longer
    /// depends on it.
    @MainActor @Test func onAppearWithDueTransferAndWaitUntilGateEnablesSendNow() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 5)
        ]
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.sendGate = { .waitUntil(Date(timeIntervalSince1970: 1_000_000)) }
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.rows = IdentifiedArrayOf(uniqueElements: rows)
        }

        #expect(store.state.isSendNowDisabled == false)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func migrationStateStreamChangeRefreshesRows() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let initialRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        let currentRows = LockIsolated(initialRows)
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in currentRows.value }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
            $0.migrationManager.sendGate = { .allowed }
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
        }

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.rows = IdentifiedArrayOf(uniqueElements: initialRows)
        }

        currentRows.setValue(refreshedRows)
        let tickProgress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 1,
            remainingOrchard: .zero,
            nextTransferReadyAtHeight: nil
        )
        stateStream.send(.inProgress(tickProgress))
        await store.receive(\.migrationStateChanged)
        await store.receive(\.statusLoaded) {
            $0.rows = IdentifiedArrayOf(uniqueElements: refreshedRows)
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    // MARK: - isFlowRoot: close-instead-of-pop back

    @MainActor @Test func closeTappedWhenFlowRootEmitsDelegateDone() async {
        let store = TestStore(initialState: MigrationStatus.State(isFlowRoot: true)) {
            MigrationStatus()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.done))
    }

    // MARK: - rescheduleCompleted: post-reschedule confirmation (MOB-1478 W7)

    @MainActor @Test func rescheduleCompletedLandsOnRescheduleConfirmedWithStalledRangeAndRefreshedRows() async {
        var state = MigrationStatus.State(presentation: .resume)
        state.stalledNumber = 3
        state.stalledHoursAgo = 5
        state.isRescheduling = true
        state.rows = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 11),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 1),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 7)
        ]

        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 11),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 3),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 9),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 15)
        ]

        let store = TestStore(initialState: state) {
            MigrationStatus()
        }

        await store.send(.rescheduleCompleted(rows: refreshedRows, totalDurationHours: 24)) {
            $0.presentation = .rescheduleConfirmed(first: 3, last: 5)
            $0.rows = IdentifiedArrayOf(uniqueElements: refreshedRows)
            $0.totalDurationHours = 24
            $0.isRescheduling = false
        }
    }

    @MainActor @Test func rescheduleCompletedDerivesLastFromRowCountBeforeTheRefresh() async {
        var state = MigrationStatus.State(presentation: .resume)
        state.stalledNumber = 2
        state.rows = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 10),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 3),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(1_000), status: .pending, hoursFromNow: 6)
        ]

        // Deliberately a different count than `state.rows` above, to pin down that `last` is derived
        // from the row count as it stood BEFORE this refresh (3), not from the refreshed array (1).
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 10)
        ]

        let store = TestStore(initialState: state) {
            MigrationStatus()
        }

        await store.send(.rescheduleCompleted(rows: refreshedRows, totalDurationHours: 6)) {
            $0.presentation = .rescheduleConfirmed(first: 2, last: 3)
            $0.rows = IdentifiedArrayOf(uniqueElements: refreshedRows)
            $0.totalDurationHours = 6
        }
    }
}
