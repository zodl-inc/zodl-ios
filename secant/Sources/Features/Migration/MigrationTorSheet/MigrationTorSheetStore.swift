//
//  MigrationTorSheetStore.swift
//  zodl
//
//  "Enable Tor Protection" bottom sheet (MOB-1478 W2), replacing the full-screen Network Privacy
//  screen (S5, deleted). Hosted by `MigrationCoordFlowCoordinator` as a single coordinator-owned
//  sheet, presented from both Entry (immediate path) and How This Works (scheduled path) right before
//  the coordinator would otherwise route past the Tor step. `gotItTapped`'s `.delegate(.gotIt)` (and
//  sheet swipe-dismissal, treated identically by the coordinator) is consumed by the coordinator,
//  which persists `isTorOn` into a `NetworkPrivacyOptions` exactly as `MigrationNetworkPrivacyStore`
//  did, then resumes whichever destination it stashed before presenting.
//

import ComposableArchitecture

@Reducer
struct MigrationTorSheet {
    @ObservableState
    struct State: Equatable {
        /// No pre-selection bias, per product rule (mirrors the deleted Network Privacy screen).
        var isTorOn = false

        init(isTorOn: Bool = false) {
            self.isTorOn = isTorOn
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
