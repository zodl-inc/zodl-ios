//
//  NotEnoughFreeSpaceStore.swift
//
//
//  Created by Lukáš Korba on 02.04.2024.
//

import ComposableArchitecture

import DiskSpaceChecker
import Settings

@Reducer
public struct NotEnoughFreeSpace {
    @ObservableState
    public struct State {
        public var freeSpaceRequiredForSync = ""
        public var freeSpace = ""
        public var isSettingsOpen = false
        public var settingsState: Settings.State
        public var spaceToFreeUp = ""

        public init(
            isSettingsOpen: Bool = false,
            settingsState: Settings.State
        ) {
            self.isSettingsOpen = isSettingsOpen
            self.settingsState = settingsState
        }
    }
    
    public enum Action: BindableAction {
        case binding(BindingAction<NotEnoughFreeSpace.State>)
        case onAppear
        case settings(Settings.Action)
    }
    
    @Dependency(\.diskSpaceChecker) var diskSpaceChecker

    public init() {}
    
    public var body: some Reducer<State, Action> {
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
