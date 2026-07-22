//
//  MigrationScheduledStore.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Terminal success screen shown
//  once a scheduled migration plan has been confirmed: a summary card of what's being transferred
//  and over how long. The coordinator's one production call site (`MigrationCoordFlowCoordinator
//  .transferPlanPostConfirmChain`'s `.scheduled`/`.recreated` case) still constructs a bare
//  `MigrationScheduled.State()` — `totalAmount`/`sentCount`/`totalCount`/`durationHours` are ALL
//  still hardcoded placeholders, so the summary fields are never actually hydrated today (a
//  pre-existing MOB-1466 gap, not introduced by this task — see `MigrationScheduledTests.swift`'s
//  suite doc, "chaining lands in MOB-1466"). The coordinator does consume the `doneTapped` delegate
//  (MigrationCoordFlowCoordinator, MOB-1466).
//
//  MOB-1497 (T8, Q3'26 canvas): investigated adding a dust-remainder card here (Figma 3480:7550,
//  `ZashiInfoCallout(.filled, boldBodyPrefix:)`, mirroring `MigrationComplete`'s dust callout) —
//  SKIPPED. `migrationManager.migrationSummary(accountUUID).dust` is the same value
//  `MigrationCompleteStore`'s `completeState` already reads for its own dust card, and that MANAGER
//  call needs no new plumbing — but wiring only `dust` in here, while every other summary field
//  stays hardcoded zero (per above), would be a worse, more misleading partial fix than the current
//  honest "not wired yet" placeholder. Hydrating this screen for real is MOB-1466's gap to close,
//  not a one-off field bolted on ahead of it.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationScheduled {
    @ObservableState
    struct State: Equatable {
        /// Placeholder; real summary data lands in MOB-1466.
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
