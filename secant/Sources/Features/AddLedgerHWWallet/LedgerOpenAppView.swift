//
//  LedgerOpenAppView.swift
//  Zashi
//
//  MOB-2020: step 3 of the Ledger connect flow, "Open the Zcash App" (Figma 1599:11301, part of
//  node 1599:12387's frame). Pushed by ConnectHWWalletCoordFlowCoordinator's own
//  `.ledgerDevicePicker(.deviceBonded)` arm; opens the Zcash app on the bonded device
//  automatically on first appearance when `AddLedgerHWWallet.State.autoOpenZcashApp` is set (the
//  device did not already run it), or sits idle for Continue when it is pushed under step 4
//  instead (the device already ran it). Continue also re-runs the request after a failure.
//

import SwiftUI
import ComposableArchitecture

struct LedgerOpenAppView: View {
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
                            title: String(localizable: .ledgerOpenAppTitle),
                            subtitle: String(localizable: .ledgerOpenAppSubtitle)
                        )

                        LedgerStepChecklistCard(items: [
                            String(localizable: .ledgerOpenAppCheck1),
                            String(localizable: .ledgerOpenAppCheck2)
                        ])
                        .padding(.top, 24)
                    }
                }
                .padding(.vertical, 1)

                Spacer()

                LedgerStepCallout(
                    title: String(localizable: .ledgerOpenAppCalloutTitle),
                    message: String(localizable: .ledgerOpenAppCalloutMessage)
                )

                ZashiButton(String(localizable: .generalContinue), minHeight: 48) {
                    store.send(.openZcashAppTapped)
                }
                .disabled(store.isOpeningApp)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
            .screenHorizontalPadding()
            .onAppear {
                // MOB-2020: fires once -- `openZcashAppTapped` consumes `autoOpenZcashApp`, so a
                // later reappearance (Back from step 4) leaves the screen idle for Continue.
                if store.autoOpenZcashApp {
                    store.send(.openZcashAppTapped)
                }
            }
            .ledgerStepNavTitle(step: 3)
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
    // LedgerDevicePickerView's and LedgerApproveOnDeviceView's own `issueSheetContent()`.
    @ViewBuilder private func issueSheetContent() -> some View {
        if let issue = store.issue {
            LedgerIssueSheetContent(issue: issue, context: .connect) {
                // Mirrors LedgerApproveOnDeviceView's own Retry: Open Settings is this view's job
                // before `.issuePrimaryTapped` dismisses the sheet -- the reducer only re-asks the
                // device to open the app for `.tryAgain`.
                if store.issue?.primaryAction(in: .connect) == .openSettings,
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
                store.send(.issuePrimaryTapped)
            }
        }
    }
}

#Preview {
    NavigationView {
        LedgerOpenAppView(store: AddLedgerHWWallet.initial)
    }
}
