//
//  ScanCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-19.
//

import SwiftUI
import ComposableArchitecture

struct ScanCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<ScanCoordFlow>
    let tokenName: String

    init(store: StoreOf<ScanCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                ScanView(
                    store:
                        store.scope(
                            state: \.scanState,
                            action: \.scan
                        )
                )
                .onAppear { store.send(.onAppear) }
            } destination: { store in
                switch store.case {
                case let .addressBook(store):
                    AddressBookView(store: store)
                case let .addressBookContact(store):
                    AddressBookContactView(store: store)
                case let .confirmWithKeystone(store):
                    SignWithKeystoneView(store: store, tokenName: tokenName)
                case let .preSendingFailure(store):
                    PreSendingFailureView(store: store, tokenName: tokenName)
                case let .scan(store):
                    ScanView(store: store)
                case let .sendConfirmation(store):
                    SendConfirmationView(store: store, tokenName: tokenName)
                case let .sendForm(store):
                    SendFormView(store: store, tokenName: tokenName)
                case let .sending(store):
                    SendingView(store: store, tokenName: tokenName)
                case let .requestZecConfirmation(store):
                    RequestPaymentConfirmationView(store: store, tokenName: tokenName)
                case let .sendResultFailure(store):
                    FailureView(store: store, tokenName: tokenName)
                case let .sendResultPending(store):
                    PendingView(store: store, tokenName: tokenName)
                case let .sendResultSuccess(store):
                    SuccessView(store: store, tokenName: tokenName)
                case let .transactionDetails(store):
                    TransactionDetailsView(store: store, tokenName: tokenName)
                }
            }
            .navigationBarHidden(true)
            .navigationBarBackButtonHidden()
        }
    }
}

#Preview {
    NavigationView {
        ScanCoordFlowView(store: ScanCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension ScanCoordFlow.State {
    static let initial = ScanCoordFlow.State()
}

extension ScanCoordFlow {
    static let placeholder = StoreOf<ScanCoordFlow>(
        initialState: .initial
    ) {
        ScanCoordFlow()
    }
}
