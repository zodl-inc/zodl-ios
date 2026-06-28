//
//  MigrationEntryStore.swift
//  zodl
//
//  "Move to Ironwood" — shows the Orchard balance at risk and the Migrate Immediately / Migrate with
//  Privacy choice. Root screen of the migration flow.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationEntry {
    @ObservableState
    struct State: Equatable {
        var orchardBalance: Zatoshi = .zero
        var selectedMode: MigrationMode = .privateScheduled
        var balanceLoadFailed = false

        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case chose(MigrationMode)
            case close
        }

        case onAppear
        case balanceLoaded(Zatoshi)
        case modeSelected(MigrationMode)
        case nextTapped
        case retryTapped
        case closeTapped
        case delegate(Delegate)
    }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                migrationSDK.initializePostUpgrade()
                return .send(.balanceLoaded(migrationSDK.simulatedOrchardBalance()))

            case let .balanceLoaded(balance):
                state.orchardBalance = balance
                state.balanceLoadFailed = false
                return .none

            case let .modeSelected(mode):
                state.selectedMode = mode
                return .none

            case .nextTapped:
                migrationSDK.selectMigrationMode(state.selectedMode)
                return .send(.delegate(.chose(state.selectedMode)))

            case .retryTapped:
                return .send(.onAppear)

            case .closeTapped:
                return .send(.delegate(.close))

            case .delegate:
                return .none
            }
        }
    }
}
