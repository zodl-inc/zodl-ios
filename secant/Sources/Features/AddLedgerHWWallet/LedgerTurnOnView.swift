//
//  LedgerTurnOnView.swift
//  Zashi
//
//  MOB-2020: step 1 of the Ledger connect flow, "Turn On and Unlock" (Figma 1599:11369, part of
//  node 1599:12387's frame; the Bluetooth permission prompt over it is 1599:11430). Pushed from
//  the intro's Get Started; its own Continue pushes the device picker, requesting Bluetooth
//  access first when it hasn't been asked yet -- both driven by
//  ConnectHWWalletCoordFlowCoordinator, which owns the permission check, so this view only ever
//  sends the same `connectTapped` action the intro's CTA does (routed by the Path case it's
//  wrapped in, not the action itself).
//

import SwiftUI
import ComposableArchitecture

struct LedgerTurnOnView: View {
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
                            title: String(localizable: .ledgerTurnOnTitle),
                            subtitle: String(localizable: .ledgerTurnOnSubtitle)
                        )

                        LedgerStepChecklistCard(items: [
                            String(localizable: .ledgerTurnOnCheck1),
                            String(localizable: .ledgerTurnOnCheck2),
                            String(localizable: .ledgerTurnOnCheck3)
                        ])
                        .padding(.top, 24)
                    }
                }
                .padding(.vertical, 1)

                Spacer()

                LedgerStepCallout(
                    title: String(localizable: .ledgerTurnOnCalloutTitle),
                    message: String(localizable: .ledgerTurnOnCalloutMessage)
                )

                ZashiButton(String(localizable: .generalContinue), minHeight: 48) {
                    store.send(.connectTapped)
                }
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
            .screenHorizontalPadding()
            .ledgerStepNavTitle(step: 1)
            .zashiBack()
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
}

#Preview {
    NavigationView {
        LedgerTurnOnView(store: AddLedgerHWWallet.initial)
    }
}
