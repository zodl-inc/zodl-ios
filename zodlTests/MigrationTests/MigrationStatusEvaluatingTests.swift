//
//  MigrationStatusEvaluatingTests.swift
//  zodlTests
//
//  Handover O2 — the QA force-quit. Tapping the migration banner while a prove sweep held the DB
//  actor showed a bare spinner on an empty background for 15–45 s, because the coordinator's
//  hydration awaited the snapshot BUILDER (`migrationViewSnapshot`) before pushing the screen —
//  the fourth life of the actor-starvation class `reentryRoute`'s own doc chronicles. The fix
//  hydrates from the PUBLISHED WINDOW (`currentMigrationSnapshot`, synchronous, never
//  actor-bound) and pushes unconditionally; a `nil` window presents the screen in its explicit
//  `isEvaluating` state — chrome + "Evaluating state…" — until the first published value lands.
//
//  These tests pin the state machine's exits from evaluating: the live `snapshotUpdated`
//  emission clears it, and `onAppear`'s synchronous prime clears it when a value was published
//  between hydration and presentation. If either exit is lost, an evaluating screen can hold its
//  spinner past the data's arrival — the exact lie the state exists to remove.
//

import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@MainActor struct MigrationStatusEvaluatingTests {
    private static func snapshot(rows: [MigrationTransferRow]) -> MigrationViewSnapshot {
        MigrationViewSnapshot(
            orchardRemaining: Zatoshi(5),
            ironwoodHeld: .zero,
            movedByDoneTransfers: .zero,
            doneTransfers: 0,
            totalTransfers: rows.count,
            transfers: rows,
            summary: MigrationSummary.zero,
            banner: nil,
            preparations: [],
            planTotal: nil,
            isTorHoldActive: false,
            needsTorFirstRunChoice: false,
            isSubmitting: false,
            sessionOrdinal: 1
        )
    }

    private static func row(id: String, index: Int) -> MigrationTransferRow {
        MigrationTransferRow(
            id: id,
            index: index,
            amount: nil,
            status: MigrationTransferRow.Status.pending,
            hoursFromNow: 1,
            minutesFromNow: 60
        )
    }

    /// The first live emission is the evaluating state's primary exit: data arrived, the spinner's
    /// claim ("the state is being evaluated") stopped being true, so the flag drops in the same
    /// mutation that renders the rows.
    @Test func snapshotUpdatedClearsEvaluating() async {
        var initial = MigrationStatus.State(presentation: .progress)
        initial.isEvaluating = true
        let store = TestStore(initialState: initial) {
            MigrationStatus()
        }

        let arrived = Self.snapshot(rows: [Self.row(id: "1", index: 0)])

        await store.send(.snapshotUpdated(arrived)) {
            $0.isEvaluating = false
            $0.poolFlow = arrived
            $0.rows = IdentifiedArrayOf(uniqueElements: arrived.transfers)
            $0.totalDurationHours = arrived.summary.estimatedDurationHours
            $0.isTorHoldActive = arrived.isTorHoldActive
            $0.isTorChoicePresented = arrived.needsTorFirstRunChoice
        }
    }

    /// The race exit: a value was published between the coordinator's nil-window hydration and the
    /// screen's `onAppear`. The prime paints it synchronously and MUST drop the evaluating flag in
    /// the same pass — an evaluating spinner over real rows would be the old blank screen inverted.
    @Test func onAppearPrimeClearsEvaluating() async {
        var initial = MigrationStatus.State(presentation: .progress)
        initial.isEvaluating = true

        let published = Self.snapshot(rows: [Self.row(id: "1", index: 0)])

        let store = TestStore(initialState: initial) {
            MigrationStatus()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.continuousClock = TestClock()

            var client = MigrationManagerClient.noOp
            client.currentMigrationSnapshot = { _ in published }
            client.refreshMigrationSnapshot = { _ in }
            client.migrationSnapshotEvents = { _ in Empty().eraseToAnyPublisher() }
            $0.migrationManager = client

            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        #expect(store.state.isEvaluating == false)
        #expect(store.state.rows.count == 1)

        await store.send(.onDisappear)
    }
}
