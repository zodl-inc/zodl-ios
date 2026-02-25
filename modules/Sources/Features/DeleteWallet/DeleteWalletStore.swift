//
//  DeleteWalletStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-27-2024
//

import ComposableArchitecture

import Generated
import SDKSynchronizer
import Utils
import ZcashLightClientKit

@Reducer
public struct DeleteWallet {
    @ObservableState
    public struct State: Equatable {
        public var areMetadataPreserved = true
        public var isProcessing = false
        public var isSheetUp = false

        public init(
            areMetadataPreserved: Bool = true,
            isProcessing: Bool = false
        ) {
            self.areMetadataPreserved = areMetadataPreserved
            self.isProcessing = isProcessing
        }
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<DeleteWallet.State>)
        case deleteRequested
        case deleteTapped(Bool)
        case deleteTappedDelayed(Bool)
        case deleteCanceled
        case dismissSheet
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .deleteCanceled:
                state.isProcessing = false
                return .none

            case .deleteRequested:
                state.isSheetUp = true
                return .none
                
            case .dismissSheet:
                state.isSheetUp = false
                return .none

            case .deleteTappedDelayed(let areMetadataPreserved):
                state.isProcessing = true
                state.isSheetUp = false
                return .run { send in
                    try? await Task.sleep(for: .seconds(0.3))
                    await send(.deleteTapped(areMetadataPreserved))
                }

            case .deleteTapped:
                return .none
            }
        }
    }
}
