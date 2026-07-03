//
//  MigrationTransferPlanStore.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). One-time review of the migration schedule before signing: a timeline of
//  transfer rows, each showing its amount, status, and ETA. Visual-only: `rows` is a placeholder —
//  the real proposal (and signing/storing it) lands in MOB-1466. The `confirmTapped` delegate is
//  emitted but consumed by nobody yet.
//

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
        /// Placeholder; real proposal data lands in MOB-1466.
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        var totalDurationHours = 0
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion?

        init(
            variant: Variant = .scheduled,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int = 0
        ) {
            self.variant = variant
            self.rows = rows
            self.totalDurationHours = totalDurationHours
        }
    }

    enum Action: Equatable {
        /// Inert now; MOB-1466 signs and stores the schedule.
        case confirmTapped
        case delegate(Delegate)

        enum Delegate: Equatable {
            case confirmed
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .confirmTapped:
                return .send(.delegate(.confirmed))

            case .delegate:
                return .none
            }
        }
    }
}
