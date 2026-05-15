//
//  RootAddressBook.swift
//  Zashi
//
//  Created by Lukáš Korba on 31.01.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func addressBookReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .loadContacts:
                if let account = state.zashiWalletAccount {
                    do {
                        let result = try addressBook.allLocalContacts(account.account)
                        let abContacts = result.contacts
                        if result.remoteStoreResult == .failure {
                            // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                        }
                        return .send(.contactsLoaded(abContacts))
                    } catch {
                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                        return .none
                    }
                }
                return .none

            case .contactsLoaded(let abContacts):
                state.$addressBookContacts.withLock { $0 = abContacts }
                return .none

            default: return .none
            }
        }
    }
}
