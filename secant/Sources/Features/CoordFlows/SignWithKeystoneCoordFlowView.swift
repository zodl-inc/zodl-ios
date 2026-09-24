//
//  SignWithKeystoneCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-26.
//

import SwiftUI
import ComposableArchitecture

struct SignWithKeystoneCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<SignWithKeystoneCoordFlow>
    let tokenName: String

    init(store: StoreOf<SignWithKeystoneCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                if store.sendConfirmationState.selectedWalletAccount?.vendor == .ledger {
                    // MOB-2020 UI round 2: `RootCoordinator`'s `.signWithKeystoneRequested` never
                    // presents the popover this stack lives in for a Ledger account until it has
                    // already pushed `.sending` (on a completed signature) or `.preSendingFailure`
                    // (on a pre-signing failure) onto `path` -- the Ledger ceremony itself runs in
                    // `LedgerSignSheetView`, presented as a sheet over the screen where the user
                    // tapped Shield (see `RootView`). This root is therefore never actually seen;
                    // it stays a blank placeholder rather than flashing stale Keystone-flavoured
                    // chrome for an instant.
                    Color.clear
                        .applyScreenBackground()
                        .navigationBarHidden(true)
                } else {
                    SignWithKeystoneView(
                        store:
                            store.scope(
                                state: \.sendConfirmationState,
                                action: \.sendConfirmation
                            ),
                        tokenName: tokenName
                    )
                    .navigationBarHidden(true)
                }
            } destination: { store in
                switch store.case {
                case let .keystoneFirmwareUpdate(store):
                    KeystoneFirmwareUpdateView(store: store)
                case let .preSendingFailure(store):
                    PreSendingFailureView(store: store, tokenName: tokenName)
                case let .scan(store):
                    ScanView(store: store, popoverRatio: 1.075)
                case let .sending(store):
                    SendingView(store: store, tokenName: tokenName)
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
            .navigationBarHidden(!store.path.isEmpty)
        }
        .applyScreenBackground()
        .zashiBack()
    }
}

#Preview {
    NavigationView {
        SignWithKeystoneCoordFlowView(store: SignWithKeystoneCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension SignWithKeystoneCoordFlow.State {
    static var initial: SignWithKeystoneCoordFlow.State { SignWithKeystoneCoordFlow.State() }
}

extension SignWithKeystoneCoordFlow {
    @MainActor static let placeholder = StoreOf<SignWithKeystoneCoordFlow>(
        initialState: .initial
    ) {
        SignWithKeystoneCoordFlow()
    }
}
