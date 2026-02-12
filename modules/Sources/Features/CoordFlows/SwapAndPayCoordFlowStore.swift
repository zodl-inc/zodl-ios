//
//  SwapAndPayCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-14.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import AudioServices
import Models
import MnemonicClient
import SDKSynchronizer
import WalletStorage
import ZcashSDKEnvironment
import AddressBookClient
import AddressBook
import UserMetadataProvider

// Path
import AddressBook
import Scan
import SendConfirmation
import SwapAndPayForm
import TransactionDetails

@Reducer
public struct SwapAndPayCoordFlow {
    @Reducer
    public enum Path {
        case addressBook(AddressBook)
        case addressBookContact(AddressBook)
        case confirmWithKeystone(SendConfirmation)
        case crossPayConfirmation(SwapAndPay)
        case preSendingFailure(SendConfirmation)
        case scan(Scan)
        case sending(SendConfirmation)
        case sendResultFailure(SendConfirmation)
        case sendResultPending(SendConfirmation)
        case sendResultSuccess(SendConfirmation)
        case swapAndPayForm(SwapAndPay)
        case swapAndPayOptInForced(SwapAndPay)
        case swapToZecSummary(SwapAndPay)
        case transactionDetails(TransactionDetails)
    }
    
    @ObservableState
    public struct State {
        public enum Result: Equatable {
            case failure
            case pending
            case success
        }
        
        public var failedCode: Int?
        public var failedDescription = ""
        public var failedPcztMsg: String?
        public var isHelpSheetPresented = false
        public var isSwapExperience = true
        public var isSwapToZecExperience = false
        public var path = StackState<Path.State>()
        public var sendingScreenOnAppearTimestamp: TimeInterval = 0
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var selectedOperationChip = 0
        public var swapAndPayState = SwapAndPay.State.initial
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
        @Shared(.inMemory(.transactions)) public var transactions: IdentifiedArrayOf<TransactionState> = []
        public var txIdToExpand: String?
        
        public var isSwapInFlight: Bool {
            swapAndPayState.isQuoteRequestInFlight
        }
        
        public var isSwapHelpContent: Bool {
            isSwapExperience || swapAndPayState.isSwapToZecExperienceEnabled
        }

        public var isSensitiveButtonVisible: Bool {
            !swapAndPayState.isSwapToZecExperienceEnabled
        }

        public init() { }
    }

    public enum Action: BindableAction {
        case backButtonTapped
        case binding(BindingAction<SwapAndPayCoordFlow.State>)
        case customBackRequired
        case helpSheetRequested
        case onAppear
        case path(StackActionOf<Path>)
        case sendDone
        case sendFailed(ZcashError?, Bool)
        case stopSending
        case storeLastUsedAsset
        case swapAndPay(SwapAndPay.Action)
        case swapRequested
        case updateFailedData(Int?, String, String?)
        case updateResult(State.Result?)
        case updateTxIdToExpand(String?)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userMetadataProvider) var userMetadataProvider
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.swapAndPay) var swapAndPay

    public init() { }

    public var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()
        
        Scope(state: \.swapAndPayState, action: \.swapAndPay) {
            SwapAndPay()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                return .none

            case .helpSheetRequested,
                    .path(.element(id: _, action: .swapToZecSummary(.helpSheetRequested))):
                state.isHelpSheetPresented.toggle()
                return .none

            case .path(.element(id: _, action: .swapAndPayForm(.helpSheetRequested(let index)))):
                state.selectedOperationChip = index
                state.isHelpSheetPresented.toggle()
                return .none

            case .updateTxIdToExpand(let txId):
                state.txIdToExpand = txId
                return .none
                
            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
