////
////  Onboarding.swift
////  OnboardingTCA
////
////  Created by Adam Stener on 10/10/21.
////
//
//import Foundation
//import SwiftUI
//import ComposableArchitecture
//import Generated
//import Models
//import ZcashLightClientKit
//import CoordFlows
//import MnemonicSwift
//import ZcashSDKEnvironment
//import WalletStorage
//
//@Reducer
//public struct OnboardingFlow {
//    @Reducer
//    public enum Path {
//        case restoreWalletCoordFlowState(RestoreWalletCoordFlow)
//    }
//
//    @ObservableState
//    public struct State {
//        public enum Destination: Equatable, CaseIterable {
//            case createNewWallet
//            case importExistingWallet
//        }
//
//        @Presents public var alert: AlertState<Action>?
//        public var destination: Destination?
//        public var path = StackState<Path.State>()
//        public var walletConfig: WalletConfig
//        
//        // Path
//        //public var restoreWalletCoordFlowState = RestoreWalletCoordFlow.State.initial
//
//        public init(
//            destination: Destination? = nil,
//            walletConfig: WalletConfig
//        ) {
//            self.destination = destination
//            self.walletConfig = walletConfig
//        }
//    }
//
//    public enum Action {
//        case alert(PresentationAction<Action>)
//        case createNewWalletRequested
//        case createNewWalletTapped
//        case importExistingWallet
//        case newWalletSuccessfulyCreated
//        case onAppear
//        case path(StackActionOf<Path>)
//        //case restoreWalletCoordFlow(RestoreWalletCoordFlow.Action)
//        case dismissDestination
//    }
//    
//    @Dependency(\.mnemonic) var mnemonic
//    @Dependency(\.walletStorage) var walletStorage
//    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
//
//    public init() { }
//    
//    public var body: some Reducer<State, Action> {
////        Scope(state: \.restoreWalletCoordFlowState, action: \.restoreWalletCoordFlow) {
////            RestoreWalletCoordFlow()
////        }
//
//        Reduce { state, action in
//            switch action {
//            case .onAppear:
//                return .none
//                
//            case .alert(.presented(let action)):
//                return .send(action)
//
//            case .alert(.dismiss):
//                state.alert = nil
//                return .none
//                
//            case .dismissDestination:
//                state.path.removeAll()
//                return .none
//
//            case .createNewWalletTapped:
//                state.destination = .createNewWallet
//                return .none
//
//            case .createNewWalletRequested:
//                do {
//                    // get the random english mnemonic
//                    let newRandomPhrase = try mnemonic.randomMnemonic()
//                    let birthday = zcashSDKEnvironment.latestCheckpoint
//                    
//                    // store the wallet to the keychain
//                    try walletStorage.importWallet(newRandomPhrase, birthday, .english, false)
//
//                    return .send(.newWalletSuccessfulyCreated)
//                } catch {
//                    state.alert = AlertState.cantCreateNewWallet(error.toZcashError())
//                }
//                return .none
//                
//            case .newWalletSuccessfulyCreated:
//                return .none
//                
//            case .importExistingWallet:
//                //state.restoreWalletCoordFlowState = .initial
////                state.path.append(.restoreWalletCoordFlowState(RestoreWalletCoordFlow.State.initial))
//                state.destination = .importExistingWallet
//                return .none
//
////            case .restoreWalletCoordFlow:
////                return .none
//                
//                // MARK: Path
//
//            case .path:
//                return .none
//            }
//        }
//        .forEach(\.path, action: \.path)
//    }
//}
//
//// MARK: Alerts
//
//extension AlertState where Action == OnboardingFlow.Action {
//    public static func cantCreateNewWallet(_ error: ZcashError) -> AlertState {
//        AlertState {
//            TextState(L10n.Root.Initialization.Alert.Failed.title)
//        } message: {
//            TextState(L10n.Root.Initialization.Alert.CantCreateNewWallet.message(error.detailedMessage))
//        }
//    }
//}
