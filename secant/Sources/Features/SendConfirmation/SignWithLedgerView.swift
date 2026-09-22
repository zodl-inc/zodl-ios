//
//  SignWithLedgerView.swift
//  Zashi
//
//  MOB-2020 Phase 3.2: the Ledger counterpart to SignWithKeystoneView -- pushed in place of that
//  screen when the selected account is a Ledger. Drives `LedgerSigning`'s phase machine (scan,
//  connect, sign) instead of showing a QR code; the PCZT never has to leave the app. The screen's
//  copy and its auto-connect behaviour are provisional -- no Figma exists yet for signing.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct SignWithLedgerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<SendConfirmation>

    let tokenName: String

    init(store: StoreOf<SendConfirmation>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Asset.Assets.Partners.ledgerLogo.image
                                .resizable()
                                .frame(width: 24, height: 24)
                                .padding(8)
                                .background {
                                    Circle()
                                        .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                }
                                .padding(.trailing, 12)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(localizable: .accountsLedger)
                                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                                Text(store.selectedWalletAccount?.unifiedAddress?.zip316 ?? "")
                                    .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
                            }

                            Spacer()

                            Text(localizable: .keystoneSignWithHardware)
                                .zFont(.medium, size: 12, style: Design.Utility.HyperBlue._700)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 8)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                        .fill(Design.Utility.HyperBlue._50.color(colorScheme))
                                        .background {
                                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                                .stroke(Design.Utility.HyperBlue._200.color(colorScheme))
                                        }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                        }
                        .padding(.top, 40)

                        statusCard(colorScheme)
                            .padding(.top, 32)

                        Text(localizable: .ledgerSignWithTitle)
                            .zFont(.medium, size: 16, style: Design.Text.primary)
                            .padding(.top, 32)

                        Text(localizable: .ledgerSignWithDesc)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .screenHorizontalPadding()
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }

                #if DEBUG
                ZashiButton(
                    "Share PCZT",
                    type: .ghost
                ) {
                    store.send(.sharePCZT)
                }
                .padding(.top, 16)
                #endif

                Spacer()

                ZashiButton(
                    String(localizable: .keystoneSignWithReject),
                    type: .destructive1
                ) {
                    store.send(.rejectRequested)
                }
                .padding(.bottom, 24)

                shareView()
            }
            .zashiSheet(isPresented: $store.rejectSendRequest) {
                // Reuses Keystone's reject sheet verbatim -- its copy is already vendor-neutral
                // ("Are you sure?" / "Rejecting the signature will cancel the transaction…").
                SignWithKeystoneView(store: store, tokenName: tokenName)
                    .rejectSendContent(colorScheme: colorScheme)
            }
            .onAppear {
                store.send(.ledgerSigning(.onAppear))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .screenTitle(String(localizable: .ledgerSignWithTitle))
    }
}

extension SignWithLedgerView {
    @ViewBuilder private func statusCard(_ colorScheme: ColorScheme) -> some View {
        VStack(spacing: 16) {
            statusContent(colorScheme)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 216)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Asset.Colors.ZDesign.Base.bone.color)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
        }
    }

    @ViewBuilder private func statusContent(_ colorScheme: ColorScheme) -> some View {
        switch store.ledgerSigning.phase {
        case .scanning:
            spinnerStatus(String(localizable: .ledgerSignWithScanning))

        case .selectingDevice:
            VStack(spacing: 12) {
                Text(localizable: .ledgerSignWithSelectDevice)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)

                ForEach(store.ledgerSigning.devices) { device in
                    deviceRow(device, colorScheme)
                }
            }

        case .connecting:
            spinnerStatus(String(localizable: .ledgerSignWithConnecting))

        case .connected:
            spinnerStatus(String(localizable: .ledgerSignWithPreparing))

        case .signing(.identifyingDevice), .signing(.streaming):
            spinnerStatus(String(localizable: .ledgerSignWithSending))

        case .signing(.awaitingReviewOnDevice):
            Text(localizable: .ledgerSignWithReview)
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

        case .signing(.signing), .signing(.complete), .signed:
            spinnerStatus(String(localizable: .ledgerSignWithSigning))

        case .failed:
            VStack(spacing: 16) {
                Text(store.ledgerSigning.errorMessage ?? "")
                    .zFont(size: 14, style: Design.Text.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if store.ledgerSigning.isRestartable {
                    ZashiButton(String(localizable: .ledgerSignWithTryAgain)) {
                        store.send(.ledgerSigning(.tryAgainTapped))
                    }
                }
            }
        }
    }

    @ViewBuilder private func spinnerStatus(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()

            Text(text)
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice, _ colorScheme: ColorScheme) -> some View {
        Button {
            store.send(.ledgerSigning(.deviceTapped(device)))
        } label: {
            HStack(spacing: 0) {
                Asset.Assets.Partners.ledgerLogo.image
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(8)
                    .background {
                        Circle()
                            .fill(Design.Surfaces.bgAlt.color(colorScheme))
                    }
                    .padding(.trailing, 8)

                Text(device.model.productName)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._3xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
        }
    }

    @ViewBuilder func shareView() -> some View {
        if let pczt = store.pcztToShare {
            UIShareDialogView(activityItems: [pczt]) {
                store.send(.shareFinished)
            }
            .frame(width: 0, height: 0)
        }
    }
}
