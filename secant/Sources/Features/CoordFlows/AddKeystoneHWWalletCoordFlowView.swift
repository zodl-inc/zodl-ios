//
//  AddKeystoneHWWalletCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-19.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct AddKeystoneHWWalletCoordFlowView: View {
    @PlatformBindable var store: StoreOf<AddKeystoneHWWalletCoordFlow>
    let tokenName: String

    init(store: StoreOf<AddKeystoneHWWalletCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                AddKeystoneHWWalletView(
                    store:
                        store.scope(
                            state: \.addKeystoneHWWalletState,
                            action: \.addKeystoneHWWallet
                        )
                )
                .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                    helpSheetContent()
                }
            } destination: { store in
                switch store.case {
                case let .accountHWWalletSelection(store):
                    AccountsSelectionView(store: store)
                case let .estimateBirthdaysDate(store):
                    WalletBirthdayEstimateDateView(store: store)
                case let .estimatedBirthday(store):
                    WalletBirthdayEstimatedHeightView(store: store)
                case let .keystoneConnected(store):
                    KeystoneConnectedView(store: store)
                case let .keystoneDeviceReady(store):
                    KeystoneDeviceReadyView(store: store)
                case let .restoreInfo(store):
                    RestoreInfoView(store: store)
                case let .scan(store):
                    ScanView(store: store)
                case let .walletBirthday(store):
                    WalletBirthdayView(store: store)
                }
            }
        }
        // `capped: false` at the flow level: every keystone screen already applies its OWN background
        // (capped for content, `capped: false` for the pushed ScanView). A capped flow background framed
        // the whole NavigationStack to the capped content column (`Design.Mac.viewCapWidth`), which also shrank the full-window scan
        // (the "dimmed capped" scan bug). Uncapped here, the scan's own full-window background wins.
        .applyScreenBackground(capped: false)
#if os(iOS)
        // The flow's root content (AddHWWalletView) already owns the canonical back —
        // `.zashiBack { backToHomeTapped }` → returns to the split home. This wrapper-level `.zashiBack()`
        // (default env dismiss) DUPLICATES it; on macOS that drew a SECOND back arrow whose env dismiss,
        // with no presentation to close, hid the whole app. Keep it iOS-only — macOS shows the single
        // content back.
        .zashiBack()
#endif
    }
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .restoreWalletHelpTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            HintBox(String(localizable: .walletBirthdayHelpDesc), style: .markdown)
                .padding(.bottom, 32)
            
            ZashiButton(String(localizable: .restoreInfoGotIt)) {
                store.send(.closeHelpSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

#Preview {
    NavigationView {
        AddKeystoneHWWalletCoordFlowView(store: AddKeystoneHWWalletCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension AddKeystoneHWWalletCoordFlow.State {
    static var initial: AddKeystoneHWWalletCoordFlow.State { AddKeystoneHWWalletCoordFlow.State() }
}

extension AddKeystoneHWWalletCoordFlow {
    @MainActor static let placeholder = StoreOf<AddKeystoneHWWalletCoordFlow>(
        initialState: .initial
    ) {
        AddKeystoneHWWalletCoordFlow()
    }
}
