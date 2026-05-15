//
//  RootUserMetadata.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-05.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func userMetadataReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .loadUserMetadata:
                guard let account = state.selectedWalletAccount?.account else {
                    return .none
                }
                try? userMetadataProvider.load(account)
                try? readTransactionsStorage.resetZashi()
                return .none

            default: return .none
            }
        }
    }
}
