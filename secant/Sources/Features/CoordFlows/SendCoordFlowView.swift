//
//  SendCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-18.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct SendCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @PlatformBindable var store: StoreOf<SendCoordFlow>
    let tokenName: String

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false

    init(store: StoreOf<SendCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
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
                .screenTitle(String(localizable: .generalSend))
#if !os(macOS)
                // macOS: the hide-balance eye lives in the split's left rail; don't duplicate it.
                .zashiNavigationBarItems(
                    trailing:
                        HStack(spacing: 0) {
                            hideBalancesButton()
                        }
                )
#endif
            } destination: { store in
                switch store.case {
                case let .addressBook(store):
                    AddressBookView(store: store)
                case let .addressBookContact(store):
                    AddressBookContactView(store: store)
                case let .confirmWithKeystone(store):
                    SignWithKeystoneView(store: store, tokenName: tokenName)
                case let .keystoneFirmwareUpdate(store):
                    KeystoneFirmwareUpdateView(store: store)
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
        }
        // macOS: this flow hosts the select-recipient AddressBook List (already full-width via its own
        // `capped: false` + `macContentRowCap()`). Move the cap OFF the flow so that List's scroll
        // indicator reaches the window edge; every other screen in the flow self-caps (audited). iOS
        // unaffected — `capped: false` collapses to the same background-only path there (Rule #11).
        .applyScreenBackground(capped: false)
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
    static var initial: SendCoordFlow.State { SendCoordFlow.State() }
}

extension SendCoordFlow {
    @MainActor static let placeholder = StoreOf<SendCoordFlow>(
        initialState: .initial
    ) {
        SendCoordFlow()
    }
}
