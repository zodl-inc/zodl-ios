//
//  SendCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-18.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import AudioServices
import Models
import NumberFormatter

// Path
import AddressBook
import Scan
import SendConfirmation
import SendForm
import TransactionDetails

@Reducer
public struct SendCoordFlow {
    @Reducer
    public enum Path {
        case addressBook(AddressBook)
        case addressBookContact(AddressBook)
        case confirmWithKeystone(SendConfirmation)
        case preSendingFailure(SendConfirmation)
        case requestZecConfirmation(SendConfirmation)
        case scan(Scan)
        case sendConfirmation(SendConfirmation)
        case sending(SendConfirmation)
        case sendResultFailure(SendConfirmation)
        case sendResultPending(SendConfirmation)
        case sendResultSuccess(SendConfirmation)
        case transactionDetails(TransactionDetails)
    }
    
    @ObservableState
    public struct State {
        public var path = StackState<Path.State>()
        public var sendFormState = SendForm.State.initial
        @Shared(.inMemory(.transactions)) public var transactions: IdentifiedArrayOf<TransactionState> = []

        public init() { }
    }

    public enum Action {
        case backToHomeTapped
        case path(StackActionOf<Path>)
        case resolveSendResult(SendConfirmation.State.Result?, SendConfirmation.State)
        case sendForm(SendForm.Action)
        case viewTransactionRequested(SendConfirmation.State)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.numberFormatter) var numberFormatter

    public init() { }

    public var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.sendFormState, action: \.sendForm) {
            SendForm()
        }

        Reduce { state, action in
            switch action {
            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
