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
        /// No option is pre-selected (Figma B1) — Next stays disabled until the user picks one.
        var selectedMode: MigrationMode?
        var balanceLoadFailed = false

        var nextEnabled: Bool { selectedMode != nil }

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
                guard let mode = state.selectedMode else { return .none }
                migrationSDK.selectMigrationMode(mode)
                return .send(.delegate(.chose(mode)))

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
