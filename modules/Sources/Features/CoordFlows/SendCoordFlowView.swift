//
//  SendCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-18.
//

import SwiftUI
import ComposableArchitecture

import UIComponents
import Generated

// Path
import AddressBook
import Scan
import SendConfirmation
import SendForm
import TransactionDetails

public struct SendCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<SendCoordFlow>
    let tokenName: String

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false

    public init(store: StoreOf<SendCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                SendFormView(
                    store:
                        store.scope(
                            state: \.sendFormState,
                            action: \.sendForm
                        ),
                    tokenName: tokenName
                )
//                .navigationBarHidden(true)
//                .zashiBack { store.send(.backToHomeTapped) }
                .screenTitle(L10n.General.send)
                .navigationBarItems(
                    trailing:
                        HStack(spacing: 0) {
                            hideBalancesButton()
                        }
                )
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
//            .navigationBarHidden(!store.path.isEmpty)
        }
        .applyScreenBackground()
//        .zashiBack { store.send(.backToHomeTapped) }
//        .screenTitle(L10n.General.send)
//        .navigationBarItems(
//            trailing:
//                HStack(spacing: 0) {
//                    hideBalancesButton()
//                }
//        )
    }
    
    private func hideBalancesButton() -> some View {
        Button {
            $isSensitiveContentHidden.withLock { $0.toggle() }
        } label: {
            let image = isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image
            image
                .zImage(size: 24, color: Asset.Colors.primary.color)
                .padding(Design.Spacing.navBarButtonPadding)
        }
    }
}

#Preview {
    NavigationView {
        SendCoordFlowView(store: SendCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension SendCoordFlow.State {
    public static let initial = SendCoordFlow.State()
}

extension SendCoordFlow {
    public static let placeholder = StoreOf<SendCoordFlow>(
        initialState: .initial
    ) {
        SendCoordFlow()
    }
}
