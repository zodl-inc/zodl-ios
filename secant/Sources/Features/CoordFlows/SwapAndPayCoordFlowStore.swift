//
//  SwapAndPayCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-14.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct SwapAndPayCoordFlow {
    @Reducer
    enum Path {
        case addressBook(AddressBook)
        case addressBookContact(AddressBook)
        case confirmWithKeystone(SendConfirmation)
        case crossPayConfirmation(SwapAndPay)
        case keystoneFirmwareUpdate(SendConfirmation)
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
    struct State {
        enum Result: Equatable {
            case failure
            case pending
            case success
        }
        
        var failedCode: Int?
        var failedDescription = ""
        var failedPcztMsg: String?
        var isHelpSheetPresented = false
        var isInAppBrowserOn = false
        var isSwapExperience = true
        var learnMoreRequested = false
        var isSwapToZecExperience = false
        var partialFailureTxIds: [String] = []
        var partialFailureStatuses: [String] = []
        var pendingDescription: String?
        var path = StackState<Path.State>()
        var sendingScreenOnAppearTimestamp: TimeInterval = 0
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var selectedOperationChip = 0
        var swapAndPayState = SwapAndPay.State.initial
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        var txIdToExpand: String?
        
        var isSwapInFlight: Bool {
            swapAndPayState.isQuoteRequestInFlight
        }
        
        var isSwapHelpContent: Bool {
            isSwapExperience || swapAndPayState.isSwapToZecExperienceEnabled
        }

        /// Support article behind the explainer's `Learn more`, picked by which explainer is on
        /// screen. The Refund Address explainer has no `Learn more` (MOB-1889), so only these
        /// two destinations exist.
        var helpArticleURL: URL? {
            isSwapHelpContent
            ? URL(string: "https://support.zodl.com/article/26-swapping-into-zec")
            : URL(string: "https://support.zodl.com/article/24-using-crosspay-to-spend-zec")
        }

        var isSensitiveButtonVisible: Bool {
            !swapAndPayState.isSwapToZecExperienceEnabled
        }

        init() { }
    }

    enum Action: BindableAction {
        case backButtonTapped
        case binding(BindingAction<SwapAndPayCoordFlow.State>)
        case customBackRequired
        case helpSheetDismissed
        case helpSheetRequested
        case learnMoreTapped
        case onAppear
        case path(StackActionOf<Path>)
        case sendDone
        case sendFailed(ZcashError?, Bool)
        case sendPartial([String], [String])
        case stopSending
        case storeLastUsedAsset
        case swapAndPay(SwapAndPay.Action)
        case swapRequested
        case updateFailedData(Int?, String, String?)
        case updatePartialFailureData([String], [String])
        case updatePendingDescription(String?)
        case updateResult(State.Result?)
        case updateTxIdToExpand(String?)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userMetadataProvider) var userMetadataProvider
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.swapAndPay) var swapAndPay

    init() { }

    var body: some Reducer<State, Action> {
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

            case .learnMoreTapped:
                // Close the explainer first and open the browser from its `onDismiss`: asking
                // UIKit to present a second sheet while the first is still dismissing drops the
                // presentation, leaving the tap dead.
                state.learnMoreRequested = true
                state.isHelpSheetPresented = false
                return .none

            case .helpSheetDismissed:
                // Fires for every dismissal -- swipe and `Dismiss` included -- so the browser
                // opens only when `Learn more` actually asked for it.
                guard state.learnMoreRequested else { return .none }
                state.learnMoreRequested = false
                state.isInAppBrowserOn = true
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
