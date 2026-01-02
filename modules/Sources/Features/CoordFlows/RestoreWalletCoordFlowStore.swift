//
//  RestoreWalletCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 27-03-2025.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import ZcashSDKEnvironment

import MnemonicSwift
import Pasteboard
import WalletStorage
import SDKSynchronizer
import Generated

// Path
import RestoreInfo
import WalletBirthday

@Reducer
public struct RestoreWalletCoordFlow {
    @Reducer
    public enum Path {
        case estimateBirthdaysDate(WalletBirthday)
        case estimatedBirthday(WalletBirthday)
        case recoverySeedPhraseEntry(RestoreWalletCoordFlow)
        case restoreInfo(RestoreInfo)
        case walletBirthday(WalletBirthday)
    }
    
    @ObservableState
    public struct State {
        @Presents public var alert: AlertState<Action>?
        public var birthday: BlockHeight? = nil
        public var isHelpSheetPresented = false
        public var isKeyboardVisible = false
        public var isValidSeed = false
        public var isTorOn = false
        public var isTorSheetPresented = false
        public var nextIndex: Int?
        public var path = StackState<Path.State>()
        public var prevWords: [String] = Array(repeating: "", count: 24)
        public var selectedIndex: Int?
        public var suggestedWords: [String] = []
        public var words: [String] = Array(repeating: "", count: 24)
        public var wordsValidity: [Bool] = Array(repeating: true, count: 24)

        public init() { }
    }

    public enum Action: BindableAction {
        case alert(PresentationAction<Action>)
        case binding(BindingAction<RestoreWalletCoordFlow.State>)
        case evaluateSeedValidity
        case failedToRecover(ZcashError)
        case helpSheetRequested
        case nextTapped
        case path(StackActionOf<Path>)
        case resolveRestore
        case resolveRestoreRequested
        case resolveRestoreTapped
        case restoreCancelTapped
        case selectedIndex(Int?)
        case successfullyRecovered
        case suggestedWordTapped(String)
        case suggestionsRequested(Int)
        case updateKeyboardFlag(Bool)
        #if DEBUG
        case debugPasteSeed
        #endif
        
        // Onboarding
        case createNewWalletTapped
        case createNewWalletRequested
        case dismissDestination
        case importExistingWallet
        case newWalletSuccessfulyCreated
    }

    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public init() { }

    public var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()

        Reduce { state, action in
            switch action {
            case .alert(.presented(let action)):
                return .send(action)
                
            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .binding(\.words):
                let changedIndices = state.words.indices.filter { state.words[$0] != state.prevWords[$0] }
                state.prevWords = state.words

                if let index = changedIndices.first {
                    let word = state.words[index]
                    if word.hasSuffix(" ") {
                        state.words[index] = word.trimmingCharacters(in: .whitespaces)
                        state.prevWords = state.words
                        return .send(.suggestedWordTapped(state.words[index]))
                    }
                    
                    return .send(.suggestionsRequested(index))
                }
                
                return .none
                
            case .selectedIndex(let index):
                state.selectedIndex = index
                state.nextIndex = state.selectedIndex
                if let index {
                    return .send(.suggestionsRequested(index))
                }
                return .none
                
            case .suggestionsRequested(let index):
                let prefix = state.words[index]
                if prefix.isEmpty {
                    state.suggestedWords = []
                } else {
                    state.suggestedWords = mnemonic.suggestWords(prefix)
                    state.wordsValidity[index] = !state.suggestedWords.isEmpty
                }
                return .send(.evaluateSeedValidity)

            case .suggestedWordTapped(let word):
                if let index = state.selectedIndex {
                    state.words[index] = word
                    if !state.isValidSeed && state.selectedIndex != 23 {
                        state.prevWords = state.words
                        state.nextIndex = index + 1 < 24 ? index + 1 : 0
                    }
                    return .send(.evaluateSeedValidity)
                }
                return .none
                
            case .helpSheetRequested:
                state.isHelpSheetPresented.toggle()
                return .none

            case .evaluateSeedValidity:
                do {
                    try mnemonic.isValid(state.words.joined(separator: " "))
                    state.isValidSeed = true
                    state.isKeyboardVisible = false
                } catch {
                    state.isValidSeed = false
                    if let index = state.selectedIndex {
                        let prefix = state.words[index]
                        if let first = state.suggestedWords.first, first == prefix && !state.isValidSeed && state.suggestedWords.count == 1 {
                            state.prevWords = state.words
                            state.nextIndex = index + 1 < 24 ? index + 1 : 0
                        }
                    }
                }
                return .none
                
            case .updateKeyboardFlag(let value):
                state.isKeyboardVisible = value
                return .none
                
                #if DEBUG
            case .debugPasteSeed:
                do {
                    let seedToPaste = pasteboard.getString()?.data ?? ""
                    try mnemonic.isValid(seedToPaste)
                    state.isValidSeed = true
                    state.isKeyboardVisible = false
                    state.words = seedToPaste.components(separatedBy: " ")
                } catch {
                    state.isValidSeed = false
                }
                return .none
                #endif

            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}

// MARK: Alerts

extension AlertState where Action == RestoreWalletCoordFlow.Action {
    public static func cantCreateNewWallet(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(L10n.Root.Initialization.Alert.Failed.title)
        } message: {
            TextState(L10n.Root.Initialization.Alert.CantCreateNewWallet.message(error.detailedMessage))
        }
    }
}
