//
//  MigrationCompleteStore.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Display-only summary fields are
//  injected by the coordinator (MOB-1466). This screen has no back control at all
//  (`.navigationBarBackButtonHidden()`); `isFlowRoot` is carried in State for coordinator-injection
//  consistency with the other re-entry roots even though there's no back-control behavior to gate
//  here. The `gotItTapped` delegate is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationComplete {
    @ObservableState
    struct State: Equatable {
        var totalTransferred = Zatoshi.zero
        var dust = Zatoshi.zero
        var transfersSent = 0
        var transfersTotal = 0
        var durationHours = 0
        /// Carried for consistency with the other re-entry-root screens; this screen has no back
        /// control to gate (`.navigationBarBackButtonHidden()`, no custom leading toolbar item).
        var isFlowRoot = false

        var hasDust: Bool {
            dust.amount > 0
        }

        init(
            totalTransferred: Zatoshi = .zero,
            dust: Zatoshi = .zero,
            transfersSent: Int = 0,
            transfersTotal: Int = 0,
            durationHours: Int = 0,
            isFlowRoot: Bool = false
        ) {
            self.totalTransferred = totalTransferred
            self.dust = dust
            self.transfersSent = transfersSent
            self.transfersTotal = transfersTotal
            self.durationHours = durationHours
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case gotItTapped

        enum Delegate: Equatable {
            case done
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .gotItTapped:
                return .send(.delegate(.done))

            case .delegate:
                return .none
            }
        }
    }
}
