//
//  SignWithKeystoneCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-26.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct SignWithKeystoneCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @PlatformBindable var store: StoreOf<SignWithKeystoneCoordFlow>
    let tokenName: String

    init(store: StoreOf<SignWithKeystoneCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                SignWithKeystoneView(
                    store:
                        store.scope(
                            state: \.sendConfirmationState,
                            action: \.sendConfirmation
                        ),
                    tokenName: tokenName
                )
                .zashiNavigationBarHidden(true)
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
            .zashiNavigationBarHidden(!store.path.isEmpty)
        }
        // `capped: false` at the flow level (Rule #9, scan exemption — same as SendCoordFlow,
        // which hosts the IDENTICAL destination set): a capped flow background framed the whole
        // NavigationStack to the content column, shrinking the pushed full-window ScanView (the
        // "maxWidth-capped scanner" in the Keystone SHIELDING sign flow). The root
        // SignWithKeystoneView applies its OWN capped background, so content screens keep their
        // column; the scan's full-window background wins.
        .applyScreenBackground(capped: false)
        // macOS: this flow is a full-window takeover (MacSplitView), so there is nothing to go "back"
        // to at its root — and a `.zashiBack()` there renders a toolbar button whose `dismiss()` acts on
        // the window itself (looked like Zodl minimizing). `zashiSectionRootBack` renders nothing on
        // macOS; Reject is the escape. iOS is unchanged (still `.zashiBack()`).
        .zashiSectionRootBack()
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
