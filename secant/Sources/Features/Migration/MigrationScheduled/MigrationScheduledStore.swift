//
//  MigrationScheduledStore.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Terminal success screen shown
//  once a scheduled migration plan has been confirmed: a summary card of what's being transferred
//  and over how long. Hydrated by `MigrationCoordFlowCoordinator.scheduledStateNow(schedule:
//  snapshot:)` — `totalAmount`/`sentCount`/`totalCount`/`durationHours` come from the
//  just-committed (or recovery-rebuilt) schedule's own numbers plus a SYNCHRONOUS read of the
//  published `MigrationViewSnapshot` for cumulative moved value and sent count; the engine is
//  never consulted on this path. Two production call sites build `.scheduled` state this way —
//  `transferPlanPostConfirmChain`'s `.scheduled`/`.recreated` case, and the recovery
//  refresh-stale push (MOB-1466 — closes the async-hydration stall this screen used to carry; see
//  `scheduledStateNow`'s own doc for the exact source of each field). The coordinator does
//  consume the `doneTapped` delegate (MigrationCoordFlowCoordinator, MOB-1466).
//
//  The "Dust balance remaining" card MOB-1458 (W-E, Figma 3480:7631) put below the summary rows is
//  GONE — the component is no longer valid for this screen. `MigrationComplete`'s own dust card
//  (which owns the lock/migrate-anyway *decision*, Phase 6) was always a separate thing and is
//  unaffected; the two were deliberately never unified, so removing this one leaves it alone.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationScheduled {
    @ObservableState
    struct State: Equatable {
        /// THE TWO PHASES OF ONE SCREEN (Lukas, 2026-08-07 — Figma B9 and its loading twin):
        /// "we know the operation there takes seconds… so instead of just the button, hold a user
        /// on a full modal scheduling screen."
        ///
        /// The commit's own sign+store is fast; what takes ~30 s is the run's awaited FIRST DRIVE
        /// (`MigrationTransferPlan`'s `.scheduleCommitted` → `.scheduleSigned` leg — prepare,
        /// presign and broadcast the first step before navigating, so the homepage republishes
        /// against a free write actor). That wait used to happen on the plan screen under a button
        /// spinner, which reads as "nothing is happening" for half a minute. It now happens HERE.
        ///
        /// An ENUM rather than an `isLoading` flag beside the four value fields: while scheduling
        /// there are no numbers yet, and a bool would leave four zeros sitting in state for a view
        /// to render by accident. `.scheduling` carries no summary, so the skeleton is the only
        /// thing it CAN draw.
        enum Phase: Equatable {
            /// Committed, first drive in flight. Skeleton rows, spinner CTA, no back affordance.
            case scheduling
            /// The drive returned — the real numbers, the Done button.
            case ready(Summary)
        }

        /// What the summary card states once the run exists. Sourced entirely from the committed
        /// schedule plus a synchronous snapshot read — see `scheduledStateNow`.
        struct Summary: Equatable {
            var totalAmount = Zatoshi.zero
            var sentCount = 0
            var totalCount = 0
            var durationHours = 0

            init(
                totalAmount: Zatoshi = Zatoshi.zero,
                sentCount: Int = 0,
                totalCount: Int = 0,
                durationHours: Int = 0
            ) {
                self.totalAmount = totalAmount
                self.sentCount = sentCount
                self.totalCount = totalCount
                self.durationHours = durationHours
            }
        }

        var phase: Phase

        var isScheduling: Bool {
            phase == .scheduling
        }

        /// The summary, or `nil` while scheduling. The view has no other way to reach the numbers.
        var summary: Summary? {
            guard case .ready(let summary) = phase else { return nil }
            return summary
        }

        init(phase: Phase) {
            self.phase = phase
        }

        /// The hydrated shape, kept so every existing call site (`scheduledStateNow`, the recovery
        /// refresh-stale push, previews, pins) reads exactly as it did before the phase existed.
        init(
            totalAmount: Zatoshi = Zatoshi.zero,
            sentCount: Int = 0,
            totalCount: Int = 0,
            durationHours: Int = 0
        ) {
            self.phase = .ready(
                Summary(
                    totalAmount: totalAmount,
                    sentCount: sentCount,
                    totalCount: totalCount,
                    durationHours: durationHours
                )
            )
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case doneTapped

        enum Delegate: Equatable {
            case done
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .doneTapped:
                return .send(.delegate(.done))
            }
        }
    }
}
