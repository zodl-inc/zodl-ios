//
//  LedgerDevicePickerView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: the Bluetooth device list AddLedgerHWWalletCoordFlow pushes once the
//  instructions screen's CTA is tapped. Per the Figma "Select Your Device" review, this is now
//  the one screen that finds, selects, connects and pairs the Ledger — there is no separate
//  "Approve on your Ledger" screen; the export prompt is explained in place via the status line
//  below the list. Row styling mirrors AccountsSelectionView's account row; the busy Connect
//  button mirrors KeystoneDeviceReadyView's accessoryView pattern.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct LedgerDevicePickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.ledgerTitleLogo.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 32)
                    .padding(.top, 16)

                Text(localizable: .ledgerDevicePickerTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: .ledgerDevicePickerDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                if let scanError = store.scanError {
                    Text(scanError)
                        .zFont(size: 14, style: Design.Utility.ErrorRed._700)
                        .lineSpacing(1.5)
                        .padding(.top, 24)
                } else if store.devices.isEmpty {
                    VStack(spacing: 0) {
                        ProgressView()
                            .padding(.bottom, 12)

                        Text(localizable: .ledgerDevicePickerScanning)
                            .zFont(size: 14, style: Design.Text.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.devices) { device in
                                deviceRow(device)
                            }
                        }
                    }
                    .padding(.top, 24)
                }

                if store.isPairing {
                    Text(localizable: .ledgerDevicePickerConfirmOnDevice)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .lineSpacing(1.5)
                        .padding(.top, 16)
                } else if let pairingError = store.pairingError {
                    Text(pairingError)
                        .zFont(size: 14, style: Design.Utility.ErrorRed._700)
                        .lineSpacing(1.5)
                        .padding(.top, 16)
                }

                Spacer()

                if store.isConnecting || store.isPairing {
                    ZashiButton(
                        String(localizable: .keystoneAddHWWalletConnect),
                        accessoryView: ProgressView()
                    ) {
                        store.send(.connectDeviceTapped)
                    }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(String(localizable: .keystoneAddHWWalletConnect)) {
                        store.send(.connectDeviceTapped)
                    }
                    .disabled(store.selectedDevice == nil)
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.startScanning) }
            .onDisappear { store.send(.stopScanning) }
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
        }
        .applyScreenBackground()
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice) -> some View {
        Button {
            store.send(.deviceTapped(device))
        } label: {
            HStack(spacing: 0) {
                Asset.Assets.Partners.ledgerMark.image
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(8)
                    .background {
                        Circle()
                            .fill(Design.Surfaces.bgAlt.color(colorScheme))
                    }
                    .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 0) {
                    Text(device.model.productName)
                        .zFont(.semiBold, size: 14, style: Design.Text.primary)

                    if let name = device.name {
                        Text(name)
                            .zFont(size: 12, style: Design.Text.tertiary)
                    }
                }

                Spacer()

                ZashiToggle(
                    isOn: Binding(
                        get: { store.selectedDevice == device },
                        set: { _ in store.send(.deviceTapped(device)) }
                    )
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._3xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
        }
    }
}
