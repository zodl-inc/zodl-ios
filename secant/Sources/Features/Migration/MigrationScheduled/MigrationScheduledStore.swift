//
//  MigrationScheduledStore.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Terminal success screen shown
//  once a scheduled migration plan has been confirmed: a summary card of what's being transferred
//  and over how long. The coordinator's one production call site (`MigrationCoordFlowCoordinator
//  .transferPlanPostConfirmChain`'s `.scheduled`/`.recreated` case) hydrates `totalAmount`/
//  `sentCount`/`totalCount`/`durationHours`/`dustAmount` from the just-committed schedule plus
//  `migrationManager.migrationSummary(accountUUID)` (MOB-1458 W-E — closes the MOB-1466 gap this
//  screen used to carry; see that method's doc for the exact source of each field). The coordinator
//  does consume the `doneTapped` delegate (MigrationCoordFlowCoordinator, MOB-1466).
//
//  MOB-1458 (W-E, Figma 3480:7631): adds the "Dust balance remaining" card below the summary rows
//  (`ZashiInfoCallout(.filled, boldBodyPrefix:)`, mirroring `MigrationComplete`'s own dust card —
//  deliberately different, milder copy; the two are NOT unified) whenever `dustAmount > .zero`.
//  MOB-1497 (T8) had investigated this and skipped it specifically because the summary fields were
//  still hardcoded placeholders at the time — wiring only `dust` while the rest stayed fake zeros
//  would have been a more misleading partial fix than the "not wired yet" placeholder it shipped
//  with instead. That blocker is what this hydration closes.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationScheduled {
    @ObservableState
    struct State: Equatable {
        var totalAmount = Zatoshi.zero
        var sentCount = 0
        var totalCount = 0
        var durationHours = 0
        /// MOB-1458 (W-E): the note-split remainder too small to ride any transfer — stays in
        /// Orchard, migrates in a future batch. `.zero` hides the dust card; see `hasDust`.
        var dustAmount = Zatoshi.zero

        /// Whether the "Dust balance remaining" card should show — mirrors `MigrationComplete
        /// .State.hasDust`'s exact convention.
        var hasDust: Bool {
            dustAmount.amount > 0
        }

        init(
            totalAmount: Zatoshi = Zatoshi.zero,
            sentCount: Int = 0,
            totalCount: Int = 0,
            durationHours: Int = 0,
            dustAmount: Zatoshi = Zatoshi.zero
        ) {
            self.totalAmount = totalAmount
            self.sentCount = sentCount
            self.totalCount = totalCount
            self.durationHours = durationHours
            self.dustAmount = dustAmount
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
