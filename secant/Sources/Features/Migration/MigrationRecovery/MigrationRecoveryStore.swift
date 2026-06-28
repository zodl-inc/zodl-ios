//
//  MigrationRecoveryStore.swift
//  zodl
//
//  Simplified recovery prompt (per product guidance — no per-cause UI):
//  - overdue: background delivery was delayed → Send now / Reschedule.
//  - invalid: a transfer is no longer valid → re-create for the remaining balance.
//

import ComposableArchitecture
import SwiftUI

@Reducer
struct MigrationRecovery {
    @ObservableState
    struct State: Equatable {
        enum Kind: Equatable {
            case overdue
            case invalid
        }

        var kind: Kind = .invalid

        init(kind: Kind = .invalid) {
            self.kind = kind
        }
    }

    enum Action {
        enum Delegate: Equatable {
            case recreate
            case sendNow
            case reschedule
            /// Leading back control — close the whole flow back to Home.
            case close
        }

        case sendNowTapped
        case rescheduleTapped
        case recreateTapped
        case closeTapped
        case delegate(Delegate)
    }

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case .sendNowTapped:
                return .send(.delegate(.sendNow))

            case .rescheduleTapped:
                return .send(.delegate(.reschedule))

            case .recreateTapped:
                return .send(.delegate(.recreate))

            case .closeTapped:
                return .send(.delegate(.close))

            case .delegate:
                return .none
            }
        }
    }
}
