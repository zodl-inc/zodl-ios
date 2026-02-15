//
//  ZodlAnnouncementStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 02-13-2026.
//

import ComposableArchitecture

import Generated
import WalletStorage

@Reducer
public struct ZodlAnnouncement {
    @ObservableState
    public struct State: Equatable {
        public var isInAppBrowserOn = false
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<ZodlAnnouncement.State>)
        case learnMoreTapped
        case goToZodlTapped
    }

    @Dependency(\.walletStorage) var walletStorage
    
    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .binding:
                return .none
                
            case .learnMoreTapped:
                state.isInAppBrowserOn = true
                return .none
                
            case .goToZodlTapped:
                try? walletStorage.importZodlAnnouncementFlag(true)
                return .none
            }
        }
    }
}
