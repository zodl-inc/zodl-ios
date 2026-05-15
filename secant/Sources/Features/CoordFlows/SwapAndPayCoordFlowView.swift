//
//  SwapAndPayCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-14.
//

import SwiftUI
import ComposableArchitecture

struct SwapAndPayCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    
    @Perception.Bindable var store: StoreOf<SwapAndPayCoordFlow>
    let tokenName: String

    init(store: StoreOf<SwapAndPayCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            WithPerceptionTracking {
                NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                    SwapAndPayForm(
                        store:
                            store.scope(
                                state: \.swapAndPayState,
                                action: \.swapAndPay
                            ),
                        tokenName: tokenName
                    )
                    .zashiBack {
                        store.send(.backButtonTapped)
                    }
                    .zashiTitle {
                        Text(
                            store.isSwapHelpContent
                            ? String(localizable: .swapAndPaySwap).uppercased()
                            : String(localizable: .crosspayTitle).uppercased()
                        )
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    }
                    .navigationBarItems(
                        trailing:
                            HStack(spacing: 4) {
                                if store.isSensitiveButtonVisible {
                                    Button {
                                        $isSensitiveContentHidden.withLock { $0.toggle() }
                                    } label: {
                                        let image = isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image
                                        image
                                            .zImage(size: 24, color: Asset.Colors.primary.color)
                                            .padding(store.isSensitiveButtonVisible ? 8 : Design.Spacing.navBarButtonPadding)
                                    }
                                }
                                
                                Button {
                                    store.send(.helpSheetRequested)
                                } label: {
                                    Asset.Assets.infoCircle.image
                                        .zImage(size: 24, style: Design.Text.primary)
                                        .padding(store.isSensitiveButtonVisible ? 8 : Design.Spacing.navBarButtonPadding)
                                }
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
                    case let .crossPayConfirmation(store):
                        CrossPayConfirmationView(store: store, tokenName: tokenName)
                    case let .preSendingFailure(store):
                        PreSendingFailureView(store: store, tokenName: tokenName)
                    case let .scan(store):
                        ScanView(store: store)
                    case let .sending(store):
                        SendingView(store: store, tokenName: tokenName)
                    case let .sendResultFailure(store):
                        FailureView(store: store, tokenName: tokenName)
                    case let .sendResultPending(store):
                        PendingView(store: store, tokenName: tokenName)
                    case let .sendResultSuccess(store):
                        SuccessView(store: store, tokenName: tokenName)
                    case let .swapAndPayForm(store):
                        SwapAndPayForm(store: store, tokenName: tokenName)
                    case let .swapAndPayOptInForced(store):
                        SwapAndPayOptInForcedView(store: store)
                    case let .swapToZecSummary(store):
                        SwapToZecSummaryView(store: store, tokenName: tokenName)
                    case let .transactionDetails(store):
                        TransactionDetailsView(store: store, tokenName: tokenName)
                    }
                }
                .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                    helpSheetContent()
                }
                .onAppear { store.send(.onAppear) }
            }
            .applyScreenBackground()
        }
    }

    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(
                    store.isSwapHelpContent
                    ? String(localizable: .swapAndPayHelpSwapWith)
                    : String(localizable: .crosspayHelpPayWith)
                )
                .zFont(.semiBold, size: 20, style: Design.Text.primary)

                Asset.Assets.Partners.nearLogo.image
                    .zImage(width: 98, height: 24, style: Design.Text.primary)
            }
            .padding(.vertical, 12)
            .padding(.top, 24)

            if store.isSwapHelpContent {
                infoContent(
                    index: 0,
                    text: String(localizable: .swapAndPayHelpSwapDesc),
                    desc1: String(localizable: .swapAndPayHelpSwapDesc1),
                    desc2: String(localizable: .swapAndPayHelpSwapDesc2)
                )
                .padding(.bottom, 32)
            } else {
                infoContent(
                    index: 1,
                    text: String(localizable: .crosspayHelpDesc1),
                    desc1: String(localizable: .crosspayHelpDesc2)
                )
                .padding(.bottom, 32)
            }
            
            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func infoContent(
        index: Int,
        text: String,
        desc1: String? = nil,
        desc2: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .zFont(size: 16, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            
            if let desc1 {
                Text(desc1)
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(.top, 16)
            }

            if let desc2 {
                Text(desc2)
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(.top, 16)
            }
        }
    }
}

#Preview {
    NavigationView {
        SwapAndPayCoordFlowView(store: SwapAndPayCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension SwapAndPayCoordFlow.State {
    static let initial = SwapAndPayCoordFlow.State()
}

extension SwapAndPayCoordFlow {
    static let placeholder = StoreOf<SwapAndPayCoordFlow>(
        initialState: .initial
    ) {
        SwapAndPayCoordFlow()
    }
}
