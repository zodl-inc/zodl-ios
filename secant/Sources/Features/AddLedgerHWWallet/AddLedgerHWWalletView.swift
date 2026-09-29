//
//  AddLedgerHWWalletView.swift
//  Zashi
//
//  MOB-2020: the Ledger connect flow's intro, redesigned to Figma's four-step overview (node
//  1599:11237, part of 1599:12387's frame) -- the back arrow with no title, the shared
//  LedgerStepHeader, an overview row per step (LedgerStepOverviewList), the "Keep It Close"
//  callout and a single Get Started CTA. Replaces the old pairing-instructions screen this shared
//  with AddKeystoneHWWalletView's shape (five numbered steps, a How To header and a help sheet);
//  Figma has none of those, so they're dropped here, though their keys/help-sheet machinery stay
//  in place for Keystone's own screen, which still uses them.
//

import SwiftUI
import ComposableArchitecture

struct AddLedgerHWWalletView: View {
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
                            title: String(localizable: .ledgerIntroTitle),
                            subtitle: String(localizable: .ledgerIntroSubtitle)
                        )

                        LedgerStepOverviewList(items: [
                            .init(
                                title: String(localizable: .ledgerIntroStep1Title),
                                message: String(localizable: .ledgerIntroStep1Message)
                            ),
                            .init(
                                title: String(localizable: .ledgerIntroStep2Title),
                                message: String(localizable: .ledgerIntroStep2Message)
                            ),
                            .init(
                                title: String(localizable: .ledgerIntroStep3Title),
                                message: String(localizable: .ledgerIntroStep3Message)
                            ),
                            .init(
                                title: String(localizable: .ledgerIntroStep4Title),
                                message: String(localizable: .ledgerIntroStep4Message)
                            )
                        ])
                        .padding(.top, 24)
                    }
                }
                .padding(.vertical, 1)

                Spacer()

                LedgerStepCallout(
                    title: String(localizable: .ledgerIntroCalloutTitle),
                    message: String(localizable: .ledgerIntroCalloutMessage)
                )

                ZashiButton(String(localizable: .ledgerIntroCta), minHeight: 48) {
                    store.send(.connectTapped)
                }
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
            .zashiBack()
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
}

// MARK: Placeholders

extension AddLedgerHWWallet.State {
    static var initial: AddLedgerHWWallet.State { AddLedgerHWWallet.State() }
}

extension AddLedgerHWWallet {
    @MainActor static let initial = StoreOf<AddLedgerHWWallet>(
        initialState: .initial
    ) {
        AddLedgerHWWallet()
    }
}

#Preview {
    NavigationView {
        AddLedgerHWWalletView(store: AddLedgerHWWallet.initial)
    }
}
