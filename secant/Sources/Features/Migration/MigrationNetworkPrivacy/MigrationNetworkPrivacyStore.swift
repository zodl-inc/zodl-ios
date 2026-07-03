//
//  MigrationNetworkPrivacyStore.swift
//  zodl
//
//  "Network Privacy" screen (MOB-1460, Figma S5 · 2867:5801 immediate / 2867:10835 scheduled).
//  Lets the user opt in to routing migration transfer submission via Tor. The delegate is emitted
//  but consumed by nobody yet — chaining into the rest of the migration flow lands in MOB-1466.
//

import ComposableArchitecture

@Reducer
struct MigrationNetworkPrivacy {
    @ObservableState
    struct State: Equatable {
        enum Variant: Equatable {
            case immediate
            case scheduled(transferCount: Int)
        }

        var variant = Variant.scheduled(transferCount: 5)
        /// No pre-selection bias, per product rule.
        var isTorOn = false

        init(
            variant: Variant = .scheduled(transferCount: 5),
            isTorOn: Bool = false
        ) {
            self.variant = variant
            self.isTorOn = isTorOn
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case nextTapped

        enum Delegate: Equatable {
            case confirmed(NetworkPrivacyOptions)
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .delegate:
                return .none

            case .nextTapped:
                return .send(.delegate(.confirmed(NetworkPrivacyOptions(useTor: state.isTorOn, submissionEndpoint: nil))))
            }
        }
    }
}
