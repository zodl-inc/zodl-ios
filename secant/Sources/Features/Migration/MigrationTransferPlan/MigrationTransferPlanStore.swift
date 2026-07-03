//
//  MigrationTransferPlanStore.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). One-time review of the migration schedule before signing: a timeline of
//  transfer rows, each showing its amount, status, and ETA. A fresh entry proposes its own schedule
//  on `onAppear`; a recovery/reschedule variant instead has its schedule injected by the coordinator
//  (`injectedSchedule`) and must not re-propose. `confirmTapped` signs and stores whichever schedule
//  is active, unless `requiresSigning == false` (the rescheduled variant, whose transfers are
//  already signed), in which case it's a plain acknowledgment (MOB-1466). Chaining the
//  `confirmTapped` delegate into the rest of the flow is `MigrationCoordFlow`'s job.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationTransferPlan {
    @ObservableState
    struct State: Equatable {
        enum Variant: Equatable {
            case scheduled
            case manual
            case recreated
        }

        var variant = Variant.scheduled
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        var totalDurationHours = 0
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion?
        /// Coordinator-injected schedule for recovery/reschedule variants — when set, `onAppear`
        /// populates rows from it directly instead of calling `proposeMigrationTransfers()`.
        var injectedSchedule: MigrationSchedule?
        /// The schedule currently backing `rows` (either `injectedSchedule` or a freshly proposed
        /// one) — what `confirmTapped` signs and stores.
        var schedule: MigrationSchedule?
        /// `false` for the rescheduled variant only (MOB-1466): its transfers are already signed at
        /// the original plan commit, so `confirmTapped` is a plain acknowledgment — `false` skips
        /// `signAndStoreMigrationSchedule` and delegates `.confirmed` directly. The re-created
        /// (recovery) variant signs a fresh schedule, so it keeps the default `true`.
        var requiresSigning = true

        init(
            variant: Variant = .scheduled,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int = 0,
            requiresSigning: Bool = true
        ) {
            self.variant = variant
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.requiresSigning = requiresSigning
        }
    }

    enum Action: Equatable {
        /// Signs and stores the active schedule.
        case confirmTapped
        case delegate(Delegate)
        case onAppear
        /// `signAndStoreMigrationSchedule` completed.
        case scheduleSigned
        /// `proposeMigrationTransfers()` result — populates rows/duration for a fresh entry.
        case transfersProposed(MigrationSchedule)

        enum Delegate: Equatable {
            case confirmed
        }
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .confirmTapped:
                guard state.requiresSigning else {
                    // Rescheduled variant: transfers are already signed — this is acknowledgment.
                    return .send(.delegate(.confirmed))
                }

                let schedule = state.schedule ?? MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                return .run { send in
                    await sdkSynchronizer.signAndStoreMigrationSchedule(schedule)
                    await send(.scheduleSigned)
                }

            case .delegate:
                return .none

            case .onAppear:
                if let injectedSchedule = state.injectedSchedule {
                    apply(injectedSchedule, to: &state)
                    return .none
                }

                // Coordinator-hydrated rows (the rescheduled variant — no schedule object exists
                // for it) must not be overwritten by a fresh proposal.
                if !state.rows.isEmpty {
                    return .none
                }

                return .run { send in
                    let schedule = await sdkSynchronizer.proposeMigrationTransfers()
                    await send(.transfersProposed(schedule))
                }

            case .scheduleSigned:
                return .send(.delegate(.confirmed))

            case .transfersProposed(let schedule):
                apply(schedule, to: &state)
                return .none
            }
        }
    }

    /// Populates `rows`/`totalDurationHours`/`schedule` from a `MigrationSchedule`, whether it was
    /// freshly proposed or injected by the coordinator. The first transfer is `.active` (ready now);
    /// the rest are `.pending`. `hoursFromNow` comes from `estimateTimestamp` where the SDK can
    /// resolve a height to a timestamp; unresolved (incl. the inert stub) defaults to `0`.
    private func apply(_ schedule: MigrationSchedule, to state: inout State) {
        state.rows = IdentifiedArrayOf(
            uniqueElements: schedule.transfers.enumerated().map { index, transfer in
                MigrationTransferRow(
                    id: transfer.id,
                    index: index,
                    amount: transfer.amount,
                    status: index == 0 ? .active : .pending,
                    hoursFromNow: hoursFromNow(forHeightReadyAt: transfer.nextExecutableAfterHeight)
                )
            }
        )
        state.totalDurationHours = schedule.estimatedDurationHours
        state.schedule = schedule
    }

    private func hoursFromNow(forHeightReadyAt height: BlockHeight) -> Int {
        guard let readyTimestamp = sdkSynchronizer.estimateTimestamp(height) else { return 0 }

        let seconds = Date(timeIntervalSince1970: readyTimestamp).timeIntervalSinceNow
        return max(0, Int(seconds / 3_600))
    }
}
