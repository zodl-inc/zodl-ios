//
//  WalletBackupCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-04-18.
//

import ComposableArchitecture

extension WalletBackupCoordFlow {
    func coordinatorReduce() -> Reduce<WalletBackupCoordFlow.State, WalletBackupCoordFlow.Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Self

            case .recoveryPhraseDisplay(.securityWarningNextTapped):
                var recoveryPhraseDisplayState = RecoveryPhraseDisplay.State.initial
                recoveryPhraseDisplayState.isWalletBackup = true
                state.path.append(.phrase(recoveryPhraseDisplayState))
                return .none
                
            default: return .none
            }
        }
    }
}
