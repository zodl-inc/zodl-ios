//
//  ConnectHWWalletCoordFlowView.swift
//  Zashi
//
//  MOB-2020 UI round 2. Merges AddKeystoneHWWalletCoordFlowView and
//  AddLedgerHWWalletCoordFlowView: the chooser (`ChooseHWWalletView`) is now the stack's root,
//  and both vendors' instructions screens are push destinations reached from it, so the default
//  Back on either one pops to the chooser instead of leaving no way to pick the other vendor.
//

import SwiftUI
import ComposableArchitecture

struct ConnectHWWalletCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<ConnectHWWalletCoordFlow>
    let tokenName: String

    init(store: StoreOf<ConnectHWWalletCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    /// Whether a Ledger element is anywhere on the path -- used only to pick the vendor-correct
    /// failure description below (the title and everything else in the sheet is shared verbatim).
    private var isLedgerFailure: Bool {
        for element in store.path {
            switch element {
            case .addLedgerHWWallet, .ledgerDevicePicker, .ledgerApproveOnDevice, .ledgerAccount, .ledgerDeviceReady, .ledgerConnected:
                return true
            default:
                continue
            }
        }
        return false
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                ChooseHWWalletView(
                    store:
                        store.scope(
                            state: \.chooseHWWalletState,
                            action: \.chooseHWWallet
                        )
                )
                .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                    helpSheetContent()
                }
                .zashiSheet(isPresented: $store.isFailureSheetPresented) {
                    failureSheetContent()
                }
                .zashiSheet(isPresented: $store.isAccountAlreadyAddedSheetPresented) {
                    LedgerIssueSheetContent(
                        issue: .accountAlreadyAdded,
                        context: .connect,
                        onPrimary: { store.send(.goToExistingAccountTapped) },
                        secondary: .init(
                            title: String(localizable: .generalCancel),
                            type: .secondary,
                            action: { store.send(.accountAlreadyAddedCancelTapped) }
                        )
                    )
                }
                .overlay {
                    if let supportData = store.supportData {
                        UIMailDialogView(
                            supportData: supportData,
                            completion: {
                                store.send(.sendSupportMailFinished)
                            }
                        )
                        // UIMailDialogView only wraps MFMailComposeViewController presentation
                        // so frame is set to 0 to not break SwiftUI's layout
                        .frame(width: 0, height: 0)
                    }

                    if let message = store.messageToBeShared {
                        UIShareDialogView(activityItems: [message]) {
                            store.send(.shareFinished)
                        }
                        // UIShareDialogView only wraps UIActivityViewController presentation
                        // so frame is set to 0 to not break SwiftUI's layout
                        .frame(width: 0, height: 0)
                    }
                }
            } destination: { store in
                switch store.case {
                case let .addKeystoneHWWallet(store):
                    AddKeystoneHWWalletView(store: store)
                case let .scan(store):
                    ScanView(store: store)
                case let .accountHWWalletSelection(store):
                    AccountsSelectionView(store: store)
                case let .keystoneDeviceReady(store):
                    KeystoneDeviceReadyView(store: store)
                case let .keystoneConnected(store):
                    KeystoneConnectedView(store: store)
                case let .addLedgerHWWallet(store):
                    AddLedgerHWWalletView(store: store)
                case let .ledgerDevicePicker(store):
                    LedgerDevicePickerView(store: store)
                case let .ledgerApproveOnDevice(store):
                    LedgerApproveOnDeviceView(store: store)
                case let .ledgerAccount(store):
                    LedgerAccountView(store: store)
                case let .ledgerDeviceReady(store):
                    LedgerDeviceReadyView(store: store)
                case let .ledgerConnected(store):
                    LedgerConnectedView(store: store)
                case let .estimateBirthdaysDate(store):
                    WalletBirthdayEstimateDateView(store: store)
                case let .estimatedBirthday(store):
                    WalletBirthdayEstimatedHeightView(store: store)
                case let .restoreInfo(store):
                    RestoreInfoView(store: store)
                case let .walletBirthday(store):
                    WalletBirthdayView(store: store)
                }
            }
        }
        .applyScreenBackground()
        .zashiBack()
    }

    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .restoreWalletHelpTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 8) {
                Asset.Assets.infoCircle.image
                    .zImage(size: 20, style: Design.Text.primary)

                if let attrText = try? AttributedString(
                    markdown: String(localizable: .walletBirthdayHelpDesc),
                    including: \.zashiApp
                ) {
                    ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 32)

            ZashiButton(String(localizable: .restoreInfoGotIt)) {
                store.send(.closeHelpSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder private func failureSheetContent() -> some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(localizable: .keystoneAddHWWalletFailureTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(localizable: isLedgerFailure ? .ledgerAddHWWalletFailureDesc : .keystoneAddHWWalletFailureDesc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .keystoneAddHWWalletContactSupport),
                type: .secondary
            ) {
                store.send(.contactSupportTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(
                String(localizable: .generalCancel),
                type: .primary
            ) {
                store.send(.cancelFailureTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

#Preview {
    NavigationView {
        ConnectHWWalletCoordFlowView(store: ConnectHWWalletCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension ConnectHWWalletCoordFlow.State {
    static var initial: ConnectHWWalletCoordFlow.State { ConnectHWWalletCoordFlow.State() }
}

extension ConnectHWWalletCoordFlow {
    @MainActor static let placeholder = StoreOf<ConnectHWWalletCoordFlow>(
        initialState: .initial
    ) {
        ConnectHWWalletCoordFlow()
    }
}
