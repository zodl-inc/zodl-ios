//
//  LedgerApproveOnDeviceView.swift
//  Zashi
//
//  MOB-2020: step 4 of the Ledger connect flow, "Approve on Your Ledger" (Figma 1599:11788, part
//  of node 1599:12387's frame, built from LedgerStepComponents.swift). Pushed by
//  ConnectHWWalletCoordFlowCoordinator's `.ledgerDevicePicker(.deviceBonded)` and
//  `.ledgerOpenApp(.zcashAppOpened)` arms, both of which also send `connectDeviceTapped` at once,
//  so pairing (AddLedgerHWWalletStore's `ledgerClient.pairDevice`) starts as soon as this screen
//  appears. While it runs, the shared placeholder rows (LedgerDeviceSkeletons) show under a fade
//  and a waiting indicator, with the primary Connect button disabled; after a failure the rows and
//  indicator hide and the shared LedgerIssueSheetContent sheet shows on top, with Connect now
//  enabled to retry -- it runs the sheet's own primary action. Cancel and the back arrow both
//  cancel the pairing, disconnect and pop back to the picker (AddLedgerHWWalletStore's
//  `.cancelTapped`, and ConnectHWWalletCoordFlowStore's own arm for it, since the coordinator runs
//  before this element's own reducer and cannot safely pop it there -- see the coordinator's doc
//  comment).
//

import SwiftUI
import ComposableArchitecture

struct LedgerApproveOnDeviceView: View {
    @Environment(\.openURL) private var openURL
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LedgerStepHeader(
                            title: String(localizable: .ledgerApproveTitle),
                            subtitle: String(localizable: .ledgerApproveMessage),
                            subtitleColor: Design.Text.primary
                        )

                        if store.isPairing {
                            LedgerDeviceSkeletons(isShimmering: false) {
                                // Figma: a fade that turns fully opaque halfway down the rows --
                                // spans the rows' whole height (matching Android's own
                                // `LedgerDeviceSkeletons`), unlike the picker's fixed bottom fade.
                                ZStack(alignment: .bottom) {
                                    LinearGradient(
                                        stops: [
                                            .init(color: Asset.Colors.background.color.opacity(0), location: 0),
                                            .init(color: Asset.Colors.background.color, location: 0.5),
                                            .init(color: Asset.Colors.background.color, location: 1)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .allowsHitTesting(false)

                                    LedgerWaitingIndicator(
                                        title: String(localizable: .ledgerApproveWaitingTitle),
                                        subtitle: String(localizable: .ledgerApproveWaitingSubtitle)
                                    )
                                    .padding(.bottom, 16)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .padding(.top, 24)
                        }
                    }
                }
                .padding(.vertical, 1)

                Spacer()

                LedgerStepCallout(
                    title: String(localizable: .ledgerApproveCalloutTitle),
                    message: String(localizable: .ledgerApproveCalloutMessage)
                )

                ZashiButton(String(localizable: .keystoneAddHWWalletConnect), minHeight: 48) {
                    // Mirrors LedgerIssueSheetContent's own primary button: Open Settings is this
                    // view's job before `.issuePrimaryTapped` dismisses the sheet -- the reducer
                    // only retries the pairing for `.tryAgain`. Connect is disabled until a
                    // failure sets an issue, so `.tryAgain` is the only case reachable here.
                    if store.issue?.primaryAction(in: .connect) == .openSettings,
                       let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    store.send(.issuePrimaryTapped)
                }
                .disabled(store.isPairing)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
            .screenHorizontalPadding()
            .ledgerStepNavTitle(step: 4)
            .zashiBack(customDismiss: { store.send(.cancelTapped) })
            .zashiSheet(isPresented: $store.isIssueSheetPresented) {
                issueSheetContent()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }

    // `zashiSheet`'s `content` closure isn't `@ViewBuilder`-attributed, so the `if let` needs its
    // own `@ViewBuilder` function rather than sitting directly in that trailing closure -- same as
    // LedgerDevicePickerView's and LedgerOpenAppView's own `issueSheetContent()`.
    @ViewBuilder private func issueSheetContent() -> some View {
        if let issue = store.issue {
            LedgerIssueSheetContent(issue: issue, context: .connect) {
                store.send(.issuePrimaryTapped)
            }
        }
    }
}
