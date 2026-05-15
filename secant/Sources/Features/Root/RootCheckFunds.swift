//
//  RootCheckFunds.swift
//  Zashi
//
//  Created by Lukáš Korba on 03.11.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func checkFundsReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .settings(.checkFundsForAddress(let address)):
                guard let accountUUID = state.selectedWalletAccount?.account.id else {
                    return .none
                }
                return .run { send in
                    do {
                        let result = try await sdkSynchronizer.fetchUTXOsByAddress(address, accountUUID)
                        switch result {
                        case .torRequired:
                            await send(.checkFundsTorRequired)
                        case .notFound:
                            await send(.checkFundsNothingFound)
                        case .found:
                            await send(.checkFundsFoundSomething)
                        }
                    } catch {
                        await send(.checkFundsFailed(error.localizedDescription))
                    }
                }
            
            case .checkFundsFailed(let error):
                state.$toast.withLock { $0 = .topDelayed5("Error: \(error)") }
                return .none

            case .checkFundsFoundSomething:
                state.$toast.withLock { $0 = .topDelayed5("Funds were successfully discovered") }
                return .none

            case .checkFundsTorRequired:
                state.$toast.withLock { $0 = .topDelayed5("Tor required") }
                return .none

            case .checkFundsNothingFound:
                state.$toast.withLock { $0 = .topDelayed5("No funds were discovered") }
                return .none

            default: return .none
            }
        }
    }
}
