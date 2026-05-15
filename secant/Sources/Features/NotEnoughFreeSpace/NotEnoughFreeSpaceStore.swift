//
//  NotEnoughFreeSpaceStore.swift
//
//
//  Created by Lukáš Korba on 02.04.2024.
//

import ComposableArchitecture

@Reducer
struct NotEnoughFreeSpace {
    @ObservableState
    struct State {
        var freeSpaceRequiredForSync = ""
        var freeSpace = ""
        var isSettingsOpen = false
        var settingsState: Settings.State
        var spaceToFreeUp = ""

        init(
            isSettingsOpen: Bool = false,
            settingsState: Settings.State
        ) {
            self.isSettingsOpen = isSettingsOpen
            self.settingsState = settingsState
        }
    }
    
    enum Action: BindableAction {
        case binding(BindingAction<NotEnoughFreeSpace.State>)
        case onAppear
        case settings(Settings.Action)
    }
    
    @Dependency(\.diskSpaceChecker) var diskSpaceChecker

    init() {}
    
    var body: some Reducer<State, Action> {
        BindingReducer()

        Scope(state: \.settingsState, action: \.settings) {
            Settings()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                let fsrts = Double(diskSpaceChecker.freeSpaceRequiredForSync())
                let fSpace = Double(diskSpaceChecker.freeSpace())
                // We show the value in GB so any required value is divided by 1_073_741_824 bytes
                state.freeSpaceRequiredForSync = String(format: "%0.0f", fsrts / Double(1_073_741_824))
                // We show the value in MB so any required value is divided by 1_048_576 bytes
                state.freeSpace = String(format: "%0.0f", fSpace / Double(1_048_576))
                state.spaceToFreeUp = String(format: "%0.0f", (fsrts / Double(1_073_741_824)) - (fSpace / Double(1_048_576)))
                state.settingsState.isEnoughFreeSpaceMode = false
                return .none
                
            case .binding:
                return .none
                
            case .settings:
                return .none
            }
        }
    }
}
