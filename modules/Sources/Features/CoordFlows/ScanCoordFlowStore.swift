//
//  ScanCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-19.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import ZcashPaymentURI

import AudioServices
import Models
import NumberFormatter
import ZcashSDKEnvironment
import SDKSynchronizer

// Path
import AddressBook
import Scan
import SendConfirmation
import SendForm
import TransactionDetails

@Reducer
public struct ScanCoordFlow {
    @Reducer
    public enum Path {
        case addressBook(AddressBook)
        case addressBookContact(AddressBook)
        case confirmWithKeystone(SendConfirmation)
        case preSendingFailure(SendConfirmation)
        case requestZecConfirmation(SendConfirmation)
        case scan(Scan)
        case sendConfirmation(SendConfirmation)
        case sendForm(SendForm)
        case sending(SendConfirmation)
        case sendResultFailure(SendConfirmation)
        case sendResultPending(SendConfirmation)
        case sendResultSuccess(SendConfirmation)
        case transactionDetails(TransactionDetails)
    }
    
    @ObservableState
    public struct State {
        @Shared(.inMemory(.exchangeRate)) public var currencyConversion: CurrencyConversion? = nil
        public var path = StackState<Path.State>()
        public var scanState = Scan.State.initial
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.transactions)) public var transactions: IdentifiedArrayOf<TransactionState> = []

        // Request ZEC
        public var amount = Zatoshi(0)
        public var memo: Memo?
        public var proposal: Proposal?
        public var recipient: Recipient?
        
        public init() { }
    }

    public enum Action {
        case getProposal(PaymentRequest)
        case onAppear
        case path(StackActionOf<Path>)
        case proposalResolved(Proposal)
        case proposalResolvedExistingSendForm(Proposal)
        case proposalResolvedNoSendForm(Proposal)
        case requestZecFailed
        case requestZecFailedExistingSendForm
        case requestZecFailedNoSendForm
        case resolveSendResult(SendConfirmation.State.Result?, SendConfirmation.State)
        case scan(Scan.Action)
        case viewTransactionRequested(SendConfirmation.State)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    
    public init() { }

    public var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.scanState, action: \.scan) {
            Scan()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.scanState.checkers = [.zcashAddressScanChecker, .requestZecScanChecker]
                return .none

            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
