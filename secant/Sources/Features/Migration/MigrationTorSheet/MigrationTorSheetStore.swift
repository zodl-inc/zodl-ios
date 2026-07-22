//
//  MigrationTorSheetStore.swift
//  zodl
//
//  "Enable Tor Protection" bottom sheet (MOB-1478 W2), replacing the full-screen Network Privacy
//  screen (S5, deleted). Hosted by `MigrationCoordFlowCoordinator` as a single coordinator-owned
//  sheet, presented from both Entry (immediate path) and How This Works (scheduled path) right before
//  the coordinator would otherwise route past the Tor step. `gotItTapped`'s `.delegate(.gotIt)` (and
//  sheet swipe-dismissal, treated identically by the coordinator) is consumed by the coordinator,
//  which persists `isTorOn` into a `MigrationNetworkPrivacyOptions` exactly as
//  `MigrationNetworkPrivacyStore` did, then resumes whichever destination it stashed before presenting.
//
//  MOB-1487 (round 3) briefly made the sheet Entry-immediate-only (scheduled path forced Tor on);
//  MOB-1494 (round 4) restores the scheduled host per the revised canvas — the toggle now defaults
//  ON (drawn ON in every frame, "strongly recommend" copy), and the body copy splits by path:
//  the immediate sheet says "your full balance", the scheduled sheet "your balance"
//  (`usesFullBalanceCopy`).
//

import ComposableArchitecture

@Reducer
struct MigrationTorSheet {
    @ObservableState
    struct State: Equatable {
        /// MOB-1494 (round 4): defaults ON — the canvas draws the toggle ON in every frame and the
        /// copy "strongly recommend"s it, superseding the earlier no-pre-selection rule.
        var isTorOn = true
        /// MOB-1494 (round 4): the immediate path's body reads "your full balance", the scheduled
        /// path's "your balance" — the view picks the string off this flag.
        var usesFullBalanceCopy = false

        init(isTorOn: Bool = true, usesFullBalanceCopy: Bool = false) {
            self.isTorOn = isTorOn
            self.usesFullBalanceCopy = usesFullBalanceCopy
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case gotItTapped

        enum Delegate: Equatable {
            case gotIt
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { _, action in
            switch action {
            case .binding:
                return .none

            case .delegate:
                return .none

            case .gotItTapped:
                return .send(.delegate(.gotIt))
            }
        }
    }
}
