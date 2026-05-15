//
//  RootTransactions.swift
//  Zashi
//
//  Created by Lukáš Korba on 29.01.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import MessageUI

@preconcurrency import ZcashLightClientKit

extension Root {
    func shieldingProcessorReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .observeShieldingProcessor:
                return .publisher {
                    shieldingProcessor.observe()
                        .map(Action.shieldingProcessorStateChanged)
                }
                .cancellable(id: state.shieldingProcessorCancelId, cancelInFlight: true)
            
            case .shieldingProcessorStateChanged(let shieldingProcessorState):
                switch shieldingProcessorState {
                case .failed(let error):
                    state.messageToBeShared = error.detailedMessage
                    state.alert = AlertState.shieldFundsFailure(error)
                case .grpc:
                    state.alert = AlertState.shieldFundsGrpc()
                case .proposal(let proposal):
                    state.signWithKeystoneCoordFlowState = .initial
                    state.signWithKeystoneCoordFlowState.sendConfirmationState.proposal = proposal
                    state.signWithKeystoneCoordFlowState.sendConfirmationState.isShielding = true
                    //state.homeState.balancesBinding = false
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(0.8))
                        await send(.signWithKeystoneRequested)
                    }
                case .requested:
                    break
                case .succeeded:
                    break
                case .unknown:
                    break
                }
                return .none
                
            case .reportShieldingFailure:
                var supportData = SupportDataGenerator.generate()
                supportData.message =
                """
                code: -3000
                \(state.messageToBeShared)
                
                \(supportData.message)
                """
                if MFMailComposeViewController.canSendMail() {
                    state.supportData = supportData
                } else {
                    state.messageShareBinding = supportData.message
                }
                return .none
                
            case .shareFinished:
                state.messageShareBinding = nil
                state.messageToBeShared = ""
                return .none

            default: return .none
            }
        }
    }
}
