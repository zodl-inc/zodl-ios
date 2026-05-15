//
//  SendCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-18.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct SendCoordFlow {
    @Reducer
    enum Path {
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
    struct State {
        var path = StackState<Path.State>()
        var sendFormState = SendForm.State.initial
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []

        init() { }
    }

    enum Action {
        case backToHomeTapped
        case path(StackActionOf<Path>)
        case resolveSendResult(SendConfirmation.State.Result?, SendConfirmation.State)
        case sendForm(SendForm.Action)
        case viewTransactionRequested(SendConfirmation.State)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.numberFormatter) var numberFormatter

    init() { }

    var body: some Reducer<State, Action> {
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
